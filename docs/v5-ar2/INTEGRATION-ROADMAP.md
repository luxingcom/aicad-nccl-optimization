# 捕获期集成路线设计与可行性分析（OPEN-ISSUES #10）

> 2026-09-04 | NCCL ringonly V5 模块已晋升生产（镜像 `...TP4-Ring-V5`，hook 分发激活）。
> 本文档回答：ar2 的 ≤8KB 微基准收益（-9~-43%）如何进入生产 decode 步（通信在 CUDA graph
> 重放内，NCCL hook 不可达人群）——路线设计、实测证据、GO/NO-GO 判定。

## 1. 实测证据（本轮窗口取得，均为生产形态真数据）

### 1.1 捕获期 AR 尺寸直方图（V5-HISTO，arm 时刻定格，rank0）
```
  256-511B:      7   ┐
  512-1023B:    14   │ ≤8192B (ar2 价值区): 164 op —— 在图内, hook 不可达
 1024-2047B:    28   │
 2048-4095B:    28   │
 4096-8191B:    87   ┘
 8192-16383B:   87   ┐
16384-32767B:   94   │ ar2 无优势区 (12KB 持平, 16KB 落后 11%)
32768-65535B:  181   │
65536-131071B: 362   ┘
131072-262143B: 811  ┐ 单 QP 串行带宽塌陷区
262144-524287B: 891  ┘
```
总被捕获 AR ≈ 2607，分布在 39 张图（目标模型 PIECEWISE 16 + FULL 12 + dspark 投机 11）。

### 1.2 服务期行为（E2E A/B + 本轮诊断版实测）
- decode 步：CUDA graph 重放，**不经过 ncclAllReduce 入口**（2.5h 满载零 hook 分发；
  诊断版 4 次真实请求后 pre-arm 计数 <8192）。
- prefill 步：eager，AR 尺寸 = tokens×7168×2（30-token prompt → 430KB）——全部 ≫ crossover，
  恒走原生。**服务期 hook 可达人群 ≈ 0**（E2E 持平的结构性根因）。

### 1.3 启动相位错位三次事故链（路线设计的约束输入）
| # | 触发 | 后果 | 教训 |
|---|---|---|---|
| E2E#1 | dspark warmup(eager) vs capture(录制) 跨 rank 错位 | ar2 超时 → ncclInternalError 击穿启动 | 捕获期相位错位不可本地判别 |
| E2E#2 | 降级重做 × 非对称 abort | GPU IMA | 事后降级不可根治 |
| 镜像v1 | fence 被 PIECEWISE 片间大 AR（262-512KB×87）提前武装 | dspark 错位 → 降级 → 对端 op 已录进 graph 延迟执行 → 原生 op 永等 → 30min watchdog | **对端 op 被 graph 录制时, 任何"本端重做"都无法收敛** |

终版防护 = 捕获静默窗（距最近捕获事件 ≥10s 才允许触发栅栏）+ fence-arm + 优雅降级。
生产实测四端 armed、零事故。

## 2. fork 捕获路径代码地图（`task3-analysis/fork-src/`）

```
gpu_worker.py: compile_or_warm_up_model → capture_model()
  └─ model_runner.py → cudagraph_utils.py: 每 size 一次 warmup(eager) + torch.cuda.graph 捕获
       ├─ 目标模型: PIECEWISE×16 (breakable_cudagraph.py:288, VLLM_USE_BREAKABLE_CUDAGRAPH=1
       │            禁 torch.compile, 片间大 AR eager —— 即 fence 误触发的 op 源)
       ├─ 目标模型: FULL×12 (整步入图)
       └─ dflash/speculator.py:126 → dflash/cudagraph.py (dspark 投机 FULL×11,
                draft/query 小图, host 每步驱动 replay —— 见 Route D)
模型侧: dsv4_model.py 各层 RowParallelLinear(reduce_results) → TP allreduce
```

## 3. 候选路线分析

| 路线 | 机理 | 判定 |
|---|---|---|
| **A. 图内 host-node**（graph surgery 把 AR 节点换 cudaGraphHostNode，replay 时回调 CPU 补发 WR） | host node **不能经 stream capture 录入**，需捕获后手工改图；replay 语义/稳定性深水区 | **NO-GO**（风险/收益严重失衡） |
| **B. device 主动 RDMA**（kernel 内发起 verbs） | GB10 无 device-side verbs 通路 | **NO-GO**（硬件不具备） |
| **C. 图断点 + eager 小 AR**（让 ≤8KB AR 成为 breakable 断点，eager 段由**现成 V5 hook** 分发） | fork 已有 breakable 机器；patch = 断点策略按尺寸门控。代价 = 每步每 op host launch ~10µs + 图碎片化 | **条件 GO**：仅当小 AR 集中在目标图；通用但收益见 §4 |
| **D. dspark 捕获点固化**（speculator 捕获处调 `ar2_capture_layer` 固化 kernel，replay 由 host 每步 `ar2_allreduce_layer` 补发 2 WR/op —— M2 即为此设计） | speculator replay 时 host 本就在环（query 图每步 launch），与 M2 契约天然吻合；不需要动目标模型图 | **首选试点**：改动面小（dflash/cudagraph.py + speculator.py），风险隔离（仅投机路径） |

## 4. 收益量化与 GO/NO-GO

- ≤8KB 人群 164 op / 39 图 ≈ **4-5 op/步（若均匀分布）**；微基准收益 8-19µs/op
  → ~0.04-0.1ms/步 ≈ **decode 步 0.04-0.1%**。
- 即便 164 op 全部集中在单类图（如 dspark，~15 op/投机步）：~0.15-0.3ms/步 ≈ 0.2-0.3%。
- **判定：当前人群单独上马 <0.3%，低于噪声带（±2%），不满足 GO 门槛。**
- 真正的杠杆在 128-512KB 人群（1702 op，~65% 总量）——那需要 ar2 大尺寸带宽工程
  （多 QP 并行/线序，S2 时代判定的价值区外工程，独立立项）。

**结论：#10 捕获期集成（仅 ≤8KB）暂缓实施（NO-GO for now），转为两步前置取证 + 一条独立带宽线：**
1. **R1 按图归属细分**（半天）：V5-HISTO 按"当前捕获的是哪类图"分桶（hook 无法直接知道 ——
   用捕获序号区间对齐日志时间轴即可推断），确认 164 小 op 归属（dspark vs 目标图）。
2. **R2 Route D 原型**（一个窗口，仅当 R1 显示 dspark 持有大部分小 AR）：dspark-only 试点，
   验收 = WR 补发时序证明 + DE 收益 ≥ 噪声带。
3. **R3 ar2 多 QP 带宽工程**（独立线，多个窗口）：目标 128-512KB 区追赶/超越 NCCL ring；
   成功后 Route C（图断点）+ 大尺寸人群才是数量级正确的收益场景。

## 4.1 R1/R2/R3 执行结果（2026-09-04 定谳）

- **R1 完成**：cap-snap 时间轴归属 —— 164 个 ≤8KB 捕获 op = **77 个 dspark 辅助 op（≤4KB）**
  + **87 个目标图辅助 op（4-8KB）**；解码重型探针（arm 后 400 token）零 eager hook 调用
  → 解码层 AR 确认全部在 FULL graph replay 内（hook 不可达）。层 AR 尺寸：目标图解码
  14KB~2.7MB；dspark 114KB+（3 层完整解码器, hidden 7168, query=8 tok/req）。
- **R2 门禁失败 → 跳过**（按 §4 自身条件"仅当 R1 显示 dspark 持有大部分小 AR"）：
  dspark 仅 77/164, 且其层 AR 是 114KB+ 大消息（非小 AR 人群）。
- **R3 完成并以负结果定谳**（详见 R3-REPORT-20260904.md）：多 QP 条带（AR2_QPS=1/2/4）
  在 14KB~512KB 全档无带宽收益（1~8µs 反向劣化, 0 错数据）；单 RC QP 已饱和本链路报文流水。
  ar2 大消息劣势是 2 轮阻塞协议串行化（~1.35µs/KB vs NCCL ring ~0.06µs/KB）,
  非传输层并行度 → **crossover 维持 8192, R3 库不晋升生产（生产继续 51e36db5/343bea89）**。
- **大层 AR 收益路径收束**：唯一数量级正确的方向是图内集成（把层 AR 固化进 CUDA graph,
  消 host 阻塞往返 + 捕获期归属即解决）——即原 Route C/ar2_capture_layer(M2) 线的深化,
  属 vLLM patch 级工程, 需另立窗口设计。传输层调参路线（多 QP/线序）已用数据关闭。

## 5. 风险与开放问题
- Route D 的 replay 时序：dspark query 图每步 replay 时 host 补发 WR —— 需确认 speculator
  replay 路径无异步化改造计划（若 fork 未来把 replay 移入 C++/图内则失效）。
- Route C 图碎片化对批间切换的影响（未测）。
- 静默窗 10s 是经验值（实测相间隔 ≤5s、末段捕获→首服务请求 ≥30s），若未来加入新的
  启动期捕获阶段（EPLB 重捕获等）需复核。

## 4.2 M2GI 图内集成立项与可行性定谳（2026-09-04 停机窗口, 用户批准立项）

报告全文: ~/sparkring-kit/m2gi-window/M2GI-FEASIBILITY-20260904.md。要点:
- **图税发现（收益模型修正）**: 生产真实基线"图内 NCCL AR"首次实测——比 eager 慢 1.3~2.2×
  （14KB: 89.2 vs 39.9µs）。对图内基线, ar2 layer 图胜带扩到 ≤64KB 稳赢（4KB 3.5~4×, 14KB 2.5×,
  32KB 1.5×）/~72-96KB 平价/≥114KB 落后（与 R3 wire 定谳自洽）。
- **人群/步级**: 胜带 526/2590 op（20%）; 投影 0.8~1.6ms/解码步 → 小批 decode（22ms 档）3.6~7%,
  大批 0.8~1.6%。定位=延迟优化特性。
- **线路**: GI-A 主线（ar2 层图固化进 FULL 图 + run_fullgraph 挂 host-WR 驱动, 1.5~2 周）;
  GI-C 先行对照（图断点+eager NCCL 回收图税, 纯 vLLM patch, 2-3 天, 对照门 DE 小批 ≥1%）;
  GI-B 否决（复杂度/收益两头不占）。dspark（114KB+）与 ≥128K 不纳入。
- **patch 面关键事实**: fork AR 全链 out-of-place（parallel_state._all_reduce_out_place → pynccl
  ncclAllReduce(in,out)）——V5 hook 就地条件③相斥, GI-A 须显式 ar2 会话 + 图内 copy kernel 保语义。
