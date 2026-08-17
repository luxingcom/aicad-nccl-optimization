# NCCL 2-hop Allreduce · S2 性能验证方案（四机环网）

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**性质:** 验证方案设计（只读，不执行四机测试、不碰生产）
**上游:** `nccl-2hop-kernel-design-architect-2026-08-16.md`（P1 可立项设计）/ `nccl-2hop-s1-prep-report-sre-2026-08-16.md`（S1 状态）/ 生产终态 2be94172 / v2 基准进行中（BENCHV2_20260816_130438）
**状态:** Proposed（等 team-lead 批准 + Rex 脚本修复 + v2 完成后开窗口执行）

---

## 0. TL;DR（结论先行）

1. **S2 验证 5 项 → 4 个验证项映射**：V1 各尺寸延迟对比（1KB-1MB × ring_real/ring_manual/2hop/pair × auto/LL/Simple）、V2 双边并发有效性（专用微基准 V2b + 既有 per-step 分解 V2a）、V3 CUDA graph 兼容（Test A 控制 / Test B 双边并发 = **硬关卡** / Test C 64 档 = **硬关卡** / Test D 2-hop 模拟 capture = 信息项）、V4 阈值定标（256/368/512KB × ring vs 2hop × LL/Simple）。
2. **S2 本质是"步结构收益 + 双边硬件可行性"的实测锚定**：用 torch isend/irecv 模拟 4 步 vs 6 步，测的是**步数收益能否在真实四机 RDMA 上兑现、双边并发是否受 GB10 单口带宽限制、capture 模式是否成立**——不是真实 kernel 的协议开销（真实 kernel 是 S3 的事）。因此 S2 数值是**保守下界**（真实 kernel 可用 LL 协议 + 更少拷贝，只可能更好）。
3. **关键前置**：Rex 必须先修复 twohop_bench.py 卡死（本方案 §4 给出修复验收 + 脚本规范），单机 4 进程 dry-run 无死锁后，才能开四机窗口。
4. **决策线（一句话版）**：
   - **GO 全量（进 S3，含 ≤512KB 路由）**：小消息（1-16KB）2hop/ring_real ≤ 0.80 且 368KB ≤ 0.95 且 δ_fwd ≤ 1.15 且 CUDA graph 硬关卡全绿且正确性全绿。
   - **GO 降级（进 S3，仅小消息 ≤64KB）**：小消息 0.80-0.88 且其余同上；368/512KB 无收益 → tuner 阈值收紧 ≤64KB。
   - **NO-GO（否决 S3）**：小消息 > 0.88（收益 <12%）或 CUDA graph 硬关卡失败或路由区间内正确性失败。
5. **窗口需求**：60 分钟（理想路径 ~40min），**必须在 v2 基准（~2.5h）完全结束后**串行执行（RDMA 共享物理链路 + GPU 争用，不可并行）。执行前置：清 S1 残留 bench 进程（v2 precheck 已标记 rank0 被 hung bench 污染）+ 四机测试容器健康 + LD_PRELOAD 库确认。
6. **S3 决策输入**（基于 S2 数据给出）：实现切入点 = NCCL 层新算法条目（复用 LD_PRELOAD 换库机制）；与 v1 天然兼容（2-hop 只走环邻）、v4 需验证双边 per-peer 双 dev 仲裁、PerSizeTuner 加 2-hop 条目按阈值路由；回滚 = tuner 关条目 或 换回 .bak 库，均瞬时。**另有一个 S3 修正项**：S1 模拟实现收发总量 1.75S（>设计理想 1.5S），S3 真实 kernel 应按 1.5S 理想分块——若 S2 的 1.75S 保守模拟已过 GO 线，真实 1.5S kernel 只会更好。

---

## 1. 背景与 S2 定位

### 1.1 机制回顾（设计定案）
- 2-hop = RS(2 步) + AG(2 步) = **4 网络步** vs ring 6 步；步 1/3 为双边并发（0↔1‖2↔3 两对边同时收发），步 2/4 为单边转发。
- 理论收益：小消息（1-16KB）延迟主导 -26~40%（4/6 步，前提 L'≈L）；368KB -7~25%（延迟项 -33% + 带宽项双边并行，区间宽）；1MB+ 带宽饱和无收益 → **只路由 ≤512KB**。
- 硬件约束：GB10 单口 55% 线速（裸 RDMA 1KB 2.40-2.42µs、4MB 313µs ≈ 13.4GB/s/口）；四机环 4 边，每 rank 双 NIC 口各连一个邻居（v4 per-peer dev 映射）。

### 1.2 S1 状态（2026-08-16 实测）
- ✅ 单机 mock（算法正确性）：2hop/ring/pair 在 16/64/256/4096/65536 元素下输出 = sum(ranks)，全部通过。
- ❌ 四机三验证项（步结构模拟 L'≈L / CUDA graph 兼容 / 368KB 阈值定标）**因 twohop_bench.py 卡死中断**（详见 v2 基准 precheck：rank0 python 4020321 99.3% CPU + 469MiB GPU 疑似卡死/长跑）。**Rex 正在修复卡死根因（task #7）。**

### 1.3 S2 定位（与 S1、S3 的边界）
| 阶段 | 验证什么 | 用什么 | 产出 |
|---|---|---|---|
| S1 | 算法正确性 + 四机步结构可行性（已部分完成，被卡死中断） | 单机 CPU mock + 四机 torch 模拟 | mock 通过 |
| **S2（本方案）** | **步结构收益实测兑现 / 双边硬件可行性 / CUDA graph 硬关卡 / 阈值定标** | 四机 torch isend/irecv 模拟 + 微基准 | 数据 → S3 决策 |
| S3 | 真实 NCCL kernel 性能 | 定制库新算法 + A/B | 生产原型 8-12 人日 |

> **S2 的已知边界**：S2 用 torch P2P 模拟，测不出真实 kernel 的协议开销（LL 叠加、proxy 调度、零拷贝）。S2 能回答"**4 步 vs 6 步的延迟收益结构是否成立**"，不能回答"**真实 kernel 绝对延迟**"。因此 S2 的 GO 线是保守线：若 S2（裸模拟）已达 GO，S3 真实 kernel 大概率更优。

---

## 2. 验证矩阵（尺寸 × 场景 × 判据）

### 2.1 符号与统一参数
- 尺寸：`1K / 4K / 16K / 64K / 256K / 368K / 512K / 1M`（与 S1 `SIZES` 一致，覆盖 team-lead 全部 8 档）。
- 算法组合：`ring_real`（torch.distributed.all_reduce，生产路径）/ `ring_manual`（6 步手写模拟，同传输对照）/ `twohop`（4 步 2-hop 模拟）/ `pair`（2 步两两全交换，激进下限数据点）。
- 协议：`auto`（生产 tuner 现状：≤40KB→LL / >40KB→Simple，**主判读**）、`LL`、`Simple`（协议路由定标用）。
- 采样：WARMUP=15、ITERS=60（V4 阈值精扫 ITERS≥200）；正确性全检（每个算法每尺寸 ok 标志）。
- 环境：NCCL_ALGO=RING、NCCL_NET_PLUGIN=none、逐机 PEER_HCA（v4 硬编码）、MAX_NCH=16、IB_HCA 4 dev、LD_PRELOAD ring-only 库（与 S1 相同）。

### 2.2 验证项总表

| # | 场景 | 尺寸 | 算法/协议 | 测量量 | 判据（S2 验收） |
|---|---|---|---|---|---|
| **V1** | 各尺寸延迟对比 | 1K,4K,16K,64K,256K,368K,512K,1M | 4 算法 × 3 协议 | avg/p50 us、per-step 分解、ok | 见 §3 决策线 |
| **V2a** | 双边并发有效性（算法内） | 64K,256K,368K（带宽敏感区） | twohop per-step 分解 | δ_bi.rs=rs1/rs2、δ_bi.ag=ag1/ag2 | δ_bi 随尺寸从 ~1（延迟主导）向带宽正比（rs≈3/ag≈2）过渡，不超线性；256K 无超线性（>4 即争用） |
| **V2b** | 双边并发有效性（硬件微基准，新增） | 64K,256K,368K | 专用 P2P 微基准 | t_both / max(t_right, t_left) | 256K 下 ≤1.3 真并发；≥1.7 争用串行化；中间区间 → S3 用显式 port-pair 调度 |
| **V3** | CUDA graph 兼容（S1 遗留硬关卡） | 1KB buf、B=1/8/16/32/64 | Test A 顺序 / Test B 双边 / Test C 64 档 / Test D 2hop 模拟 capture | capture ok、replay ok、avg/max us、尖峰 | Test B 在 B≥8 全 ok；Test C 64/64；重放无 >2× 尖峰（相对 eager）；Test D 信息项 |
| **V4** | 阈值定标 | 256K,368K,512K | ring_real vs twohop × LL/Simple，ITERS≥200 | per-proto per-size us | 阈值 = ring_real vs twohop 交叉点（ratio_h≤0.95 的最大尺寸）；输出 tuner 路由阈值建议 |

### 2.3 各验证项详细设计

#### V1 各尺寸延迟对比（对应 S2 目标 1）
- 目的：验证 4 步 vs 6 步的 -33% 步数收益在延迟端兑现（L'≈L 前提 + 双边并发收益）。
- 判定构造：
  - `ratio_h = twohop_avg / ring_real_avg`（对生产现状的收益，**主判读**）。
  - `ratio_m = twohop_avg / ring_manual_avg`（同传输 6 步 vs 4 步的纯步数收益，理想 ≈ 0.67）。
  - `δ_fwd = twohop 单边步(rs2/ag2)均时 / ring_manual 单边步均时`（L'≈L 前提，步延迟膨胀 ≤15% 为成立）。
- 预期曲线（供判读对照）：
  - 1-16K：ratio_h 0.60-0.80（延迟主导）；δ_fwd ≈ 1.0-1.15。
  - 64-512K：ratio_h 0.75-1.0（带宽项占比上升 + S1 模拟 1.75S 数据量劣化带宽项）。
  - 1M：ratio_h ≈ 1.0 或更高（带宽饱和，**验证"不路由 >512KB"的假设**）。

#### V2 双边并发有效性（对应 S2 目标 2）
- 目的：2-hop 每步 2 对边同时收发（0↔1‖2↔3）是否真并行——无 HCA 冲突/带宽争用；GB10 单口 55% 下并发收益边界。
- **V2a（复用 V1 per-step 数据，零额外成本）**：
  - `δ_bi.rs = rs1(双边) / rs2(单边)`、`δ_bi.ag = ag1(双边) / ag2(单边)`。
  - 判读口径：
    - 延迟主导区（≤16K）：δ_bi ≈ 1.0-1.3（双边并发协议开销小 = 好）。
    - 带宽主导区（≥64K）：δ_bi 随数据量正比（rs1 出 3chunk vs rs2 出 1chunk → 期望 ~3；ag1 出 2chunk vs ag2 出 1chunk → 期望 ~2）。**若 δ_bi 显著高于数据比（如 rs>4）→ 端口争用/超线性**。
- **V2b（专用硬件微基准，新增，交 Rex）**：
  - 每 rank 用 NcclTransport 同尺寸分别测：仅发右 S/4、仅发左 S/4、同时发左右各 S/4。
  - 指标 `δ_hw = t_both / max(t_right, t_left)`：
    - ≤1.3：两端口真并发（各口独立带宽），双边收益成立。
    - 1.3-1.7：部分争用，S3 需 per-port 调度或降级。
    - ≥1.7：共享瓶颈串行化，双边假设不成立 → 2-hop 收益只剩步数（且真实 kernel 面临同样约束）。
- 该验证直接支撑 S3 实现切入点决策：δ_hw 好 → 完整 4 步 2-hop；δ_hw 差 → 考虑单边步为主的重排变体。

#### V3 CUDA graph 兼容（对应 S2 目标 3，S1 遗留硬关卡）
- 生产 64 档全捕获（`--cudagraph-capture-sizes 1..64`）。2-hop 双边并发通信在 capture/重放下的正确性 = 最高风险项。
- 四测试：
  - **Test A（控制组）**：B 个顺序 full-PG all_reduce 的 graph（B=1/8/16/32/64）。验证生产库在 torch 级 capture 的基线（排除环境问题）。
  - **Test B（双边并发模拟，硬关卡）**：2 个 PG + 2 个 stream 并发 all_reduce 的 graph（B=1/8/16/32/64）。最接近"双边同时收发"的 torch 级代理。**判据：B≥8 全部 capture + replay 正确；无 capture 异常。**
  - **Test C（64 档池，硬关卡）**：capture 64 个 graph（B=8 each）+ 重放正确性 + 尖峰判据（rep_max/rep_avg ≤ 2.5）。对应 vLLM 全捕获规模。
  - **Test D（2-hop 模拟 capture，信息项，新增）**：把 `twohop_allreduce`（含 isend/irecv）包进 `torch.cuda.graph` 重放，验证 2-hop 调度本身能否 capture。**注意**：torch P2P isend/irecv 的 capture 语义与真实 NCCL kernel 的 proxy 机制不同，Test D 失败 ≠ 真实 kernel 失败，只标记"S3 需专项验证"；Test D 通过是强正信号。
- 判据汇总：
  - 硬关卡：Test B（B≥8）+ Test C（64/64）全绿。
  - 信息项：Test D 记录通过/失败模式。

#### V4 阈值定标（对应 S2 目标 4）
- 目的：256/368/512KB 的 ring vs 2-hop 最优路由 → tuner 路由阈值建议。
- 方法：V1 数据中取 256K/368K/512K × auto（主）、LL/Simple（定标）三协议，ITERS≥200 降噪。
- 输出：`阈值建议 = max{size | ratio_h ≤ 0.95}`（在 auto 协议下）。若 256K 已 >0.95 → 阈值收紧 ≤64KB（小消息 only）。

---

## 3. 判读口径（数据表模板 + 决策线）

### 3.1 数据表模板

**表 1 · 各尺寸延迟对比（每协议一张，主看 auto）**
```
# protocol=auto
size    ring_real  ring_manual  2hop   2hop_nobar  pair   ratio_h  ratio_m  delta_fwd  ok
1024    45.2       52.1         30.5    28.9        22.1   0.675    0.585    1.02       T
4096    47.0       53.8         31.8    30.2        23.5   0.677    0.591    1.04       T
...
1048576 294.0      310.0        305.0   298.0       410.0  1.037    0.984    1.10       T
```

**表 2 · 双边并发（V2a 从 per-step 分解派生 + V2b 微基准）**
```
# V2a: twohop per-step (auto)
size   rs1(bi)  rs2(fwd)  ag1(bi)  ag2(fwd)  delta_bi_rs  delta_bi_ag
65536  25.1     9.8       19.2     10.1      2.56         1.90
...
# V2b: hw microbench
size   t_right  t_left  t_both  delta_hw
65536  8.9      9.1     9.6     1.06
262144 30.2     30.5    38.8     1.27
368640 42.0     42.3    58.0     1.37
```

**表 3 · CUDA graph（V3）**
```
B    A:cap A:ok A:rep/max  B:cap B:ok B:rep/max  err
1    T     T    12/18      T     T     20/31      -
8    T     T    95/130     T     T     150/240    -
...
testC: captured=64/64 ok=T avg=...us max=...us per_op=...us
testD: captured=T ok=T rep_avg=... max=... (信息项)
```

**表 4 · 阈值定标（V4）**
```
size   ring_real(auto)  2hop(auto)  ratio_h   ring_real(Simple)  2hop(Simple)  ratio_h_s
262144 145.0            132.0       0.910     ...                ...           ...
368640 173.0            161.0       0.931     ...                ...           ...
524288 220.0            218.0       0.991     ...                ...           ...
# 阈值建议 = 262144（ratio_h ≤ 0.95 的最大尺寸）或 368640 / 仅小消息
```

### 3.2 决策线（S3 进/不进）

**GO 全量（进 S3 生产原型，含 ≤512KB 路由）—— 以下全部满足：**
| # | 判据 | 阈值 | 含义 |
|---|---|---|---|
| G1 | 小消息收益 | `ratio_h ≤ 0.80` 在 {1K,4K,16K} 中 ≥2 档（auto） | 对生产基线 ≥20% 延迟收益（设计下限 -26%，S2 保守留余量） |
| G2 | 机制前提 | `δ_fwd ≤ 1.15`（1-16K） | L'≈L 成立，步数收益 = 4/6 |
| G3 | 中消息无劣化 | 368K `ratio_h ≤ 0.95`、512K ≤ 1.0（auto） | 主 prefill 档不回归 |
| G4 | 双边并发 | 256K `δ_hw ≤ 1.5`（V2b）且 V2a 无超线性 | 双边收益真实存在 |
| G5 | CUDA graph 硬关卡 | Test B @B≥8 全 ok + Test C 64/64 + 重放正确 + 无 >2× 尖峰 | 生产 64 档捕获可复现 |
| G6 | 正确性 | 全部 ok=True（≤512K 路由区间内） | 无数据错误 |

**GO 降级（进 S3，但仅小消息 ≤64KB 路由）：**
| # | 条件 | 处置 |
|---|---|---|
| D1 | 小消息 0.80 < ratio_h ≤ 0.88（-12~20%），G2/G4/G5/G6 满足 | 进 S3，S3 范围砍为"kernel + ≤64KB 路由"，不做 368KB |
| D2 | 小消息满足 G1，但 368K ratio_h 0.95-1.0（无收益不劣化），G5/G6 满足 | 进 S3，阈值收紧 ≤256KB |
| D3 | G4 部分成立（δ_hw 1.3-1.7） | 进 S3，kernel 需显式 per-port 调度，S3 加一项验证 |

**NO-GO（否决 S3）：**
| # | 触发条件 | 理由 |
|---|---|---|
| N1 | 小消息 ratio_h > 0.88（收益 <12%） | 8-12 人日 kernel 开发 + 维护不值 <12% 延迟收益（decode 侧每 step 省 <0.5ms） |
| N2 | CUDA graph 硬关卡失败（Test B @B≥8 或 Test C <64/64） | 生产 64 档全捕获是硬约束，无法绕过 |
| N3 | 路由区间内任一 ok=False | 数据正确性是底线 |
| N4 | 368K ratio_h > 1.0（真回归） | 主 prefill 档劣化不可接受（即使小消息收益好，也需先解决再谈 S3） |
| N5 | δ_hw ≥ 1.7（双边串行化）且步数收益仍 <20%（ratio_h > 0.80） | 双边假设崩塌 + 收益不足 = 双重否决 |

> **决策线解读**：G1 是价值主闸（decode 87 次小 allreduce/step 是核心收益场景）；G5 是风险硬闸（CUDA graph 是生产前提）；N1/N2/N3 任一即否决。G3/G4 决定"全量 vs 降级"。

### 3.3 判读人员与责任
- 执行：SRE（窗口内跑表 + 产物收集）。
- 脚本修复/dry-run：Rex。
- 数据判读 + 决策线裁定：QA（Tessa）出判读报告，Archi 出 S3 决策建议汇总。
- 最终：team-lead + 人类工程负责人批准。

---

## 4. 执行脚本规范（给 Rex，含卡死修复验收）

> 前提：`/opt/2hop-s1/` 在 <node1>。以下是对修复后 twohop_bench.py / cudagraph_test.py 的**接口与输出要求**，Rex 按此实现并先做单机 4 进程 dry-run。

### 4.1 twohop_bench.py 修复验收（卡死问题）
1. **8 尺寸 × 3 协议全量跑完不挂**。每尺寸块独立 watchdog 超时（如 300s），超时打印 `BLOCK_TIMEOUT size=<n> proto=<p>` 并继续下一块；全部结束后以非零退出码 + 超时清单收尾（不静默卡死）。
2. **可定位卡点**：每个尺寸开始/结束 rank0 打印 `# size=<n> start` / `# size=<n> done`；全流程 rank0 心跳（每 10s 打印进度）。
3. **正确性门禁**：所有 ok 标志必须 True；任一 False → SUMMARY 标注 FAIL + 退出码非零。
4. **单机 dry-run**：<node1> 本地起 4 进程（`torchrun --nproc-per-node=4` 或 4×`python` + 独立 RANK）跑 1-2 尺寸 × auto，验证无死锁 + 正确性。**通过后才允许四机执行。**

### 4.2 twohop_bench.py 接口/输出要求（修复版）
- **算法核心不变**：`twohop_algo.py` 的 twohop/ring/pair + NcclTransport/MockTransport 语义保持（S2 依赖同一套算法代码）。只允许修传输层死锁/同步问题。
- **输出格式**：rank0 输出 CSV 表头 + 每尺寸行（与现有 `# size,...` 格式一致，含 `ring_real,ring_manual,2hop,2hop_nobar,pair,ok*`）；末尾 `===SUMMARY===` 块新增 `ratio_h / ratio_m / delta_fwd` 三列。
- **`--json <out.json>`**：结构化落盘每尺寸每算法 avg/p50/per-step/ok + 协议 + 环境快照（NCCL env、库路径/md5）。供判读脚本聚合。
- **`--protocol <auto|LL|Simple>`**：CLI 覆盖 NCCL_PROTO（替代 env 注入，避免 shell 传参歧义）。
- **per-step 标注**：twohop 的 per-step 列表标注类型 `rs1_bilateral / rs2_forward / ag1_bilateral / ag2_forward`（V2a 依赖）。
- **`--sizes ...`**：允许指定尺寸子集（V4 用 `--sizes 262144,368640,524288`）。
- **`--iters N`**：覆盖迭代数（V4 用 200+）。

### 4.3 cudagraph_test.py 修复/扩展要求
1. 修复同样卡死问题（Test B 双 PG + 双 stream 在 capture 下的 barrier/同步死锁；参照 4.1 的心跳 + watchdog）。
2. **Test D（新增）**：capture `twohop_allreduce`（NcclTransport + isend/irecv）进 CUDA graph，重放 K_REPLAY 次 + 正确性 + 尖峰；失败记录异常类型（信息项，不判硬关卡）。
3. 输出：每档一行 + `===SUMMARY===`（含 Test A/B/C/D 的 cap/ok/rep_avg/rep_max）+ `--json` 落盘。

### 4.4 V2b 硬件微基准（新增脚本 `bilateral_micro.py`）
- 输入：尺寸 64K/256K/368K，NcclTransport 复用。
- 每 rank 测：仅发右、仅发左、同时发左右（各 S/4）；WARMUP 15 / ITERS 200。
- 输出：`size, t_right, t_left, t_both, delta_hw` + ok。

### 4.5 编排脚本（沿用 S1，最小改动）
- `run_2hop_bench.sh bench [--protocol auto|LL|Simple] [--sizes ...]`（透传新参数）。
- `run_2hop_bench.sh cudagraph`（跑 Test A-D）。
- `run_2hop_bench.sh bilateral`（跑 V2b）。
- 产物目录 `/opt/2hop-s1/out/`。

---

## 5. 窗口需求（时长 / 前提 / 四机执行步骤）

### 5.1 时长
| 段 | 内容 | 预估 |
|---|---|---|
| 0 | 前置清理 + 四机容器 precheck + 网络空闲确认 | 5-8 min |
| 1 | 单机 4 进程 dry-run（修复后，已可在窗口前完成） | 0（窗口前） |
| 2 | V1：3 协议 × ~1.5min | 5-8 min |
| 3 | V4 阈值精扫（ITERS 200+ × 3 size × 2-3 proto） | 5-8 min |
| 4 | V2b 微基准 | 3-5 min |
| 5 | V3 CUDA graph（Test A-D） | 5-8 min |
| 6 | NCCL init / 连接建立 / 调试余量 | 10-20 min |
| **合计** | | **40-60 min（建议开 60 min 窗口）** |

### 5.2 窗口前提（must-haves）
1. **v2 基准（BENCHV2_20260816_130438，32 档 ~2.5h）完全结束后**串行执行；生产 vLLM 空闲（`num_requests_running==0` 且稳定）。
2. **RDMA 网络 quiesce**：生产无 allreduce 流量（S2 延迟测量对干扰敏感，裸 RDMA 1KB 仅 2.4µs 量级）。
3. **清残留**：杀掉 S1 卡死 bench 残留进程（v2 precheck 标记的 rank0 python 4020321 等），确认四机 GPU 空闲。
4. **四机测试容器** `2hop-s1-rank0..3` healthy；maps 确认 LD_PRELOAD ring-only 库加载；`libnccl.so.2` 符号链接存在。
5. **修复后的脚本**通过单机 dry-run（Rex 交付）。

### 5.3 四机执行步骤（turnkey）
```bash
# 在 <node1> 上执行：
# 0) precheck（SRE）：四机容器 healthy / 清残留 / GPU 0% / 网络空闲
# 1) V1 auto 协议
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench --protocol auto --json /opt/2hop-s1/out/v1_auto.json"
# 2) V1 LL + Simple
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench --protocol LL --json /opt/2hop-s1/out/v1_ll.json"
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench --protocol Simple --json /opt/2hop-s1/out/v1_simple.json"
# 3) V4 阈值精扫
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench --protocol auto --sizes 262144,368640,524288 --iters 200 --json /opt/2hop-s1/out/v4_auto.json"
# 4) V2b 微基准
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bilateral --json /opt/2hop-s1/out/v2b.json"
# 5) V3 CUDA graph
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh cudagraph --json /opt/2hop-s1/out/v3.json"
# 6) postcheck：GPU 回落 0 / 无残留 / 生产无扰动确认
```
**不触碰**：生产库 2be94172、生产容器 env、/opt/aicad-prod。

---

## 6. S3 决策建议输入（基于 S2 数据给出）

### 6.1 实现切入点（NCCL 层新算法 vs 改造 allreduce 路径）
- **推荐：NCCL 层新增算法条目**（`ncclAlgo.h` 新 algo + `enqueue.cc` PerSizeTuner 路由 + device kernel 复用 ring kernel 改步结构）。理由（设计 §3.2 定案）：
  1. LD_PRELOAD 换库即上线/回滚（现有 .bak 机制直接复用）。
  2. CUDA graph 兼容走 NCCL proxy 原生路径（S2 Test B/D 已给出 torch 级代理证据）。
  3. vLLM 0.26 所有 allreduce 已收敛到 ncclAllReduce，Python 零改动。
- **S2 数据对切入点的修正**：
  - 若 V2b δ_hw ≤ 1.3：完整 4 步 2-hop 成立 → S3 kernel 按 RS(2)+AG(2) 全量实现。
  - 若 δ_hw 1.3-1.7：S3 kernel 增加 per-port 调度验证项（双边步显式分 dev）。
  - 若 δ_hw ≥ 1.7：S3 重排为"单边步为主变体"（如 pairwise 或不对称 2-hop），并重新评估收益。
- **S3 修正项（必须写进 S3 规格）**：S1 模拟实现收发总量 1.75S > 设计理想 1.5S。S3 真实 kernel 按 1.5S 理想分块（RS 每 rank 收发 S/2、AG 对称）。**若 S2 的 1.75S 保守模拟已过 GO 线，1.5S kernel 的带宽项更优，收益只增不减。**

### 6.2 与 v1/v4/tuner 补丁的集成方式
| 补丁 | 交互 | 集成动作 |
|---|---|---|
| v1 环邻过滤 | 2-hop 只走环邻 {0-1,1-2,2-3,3-0}，不涉对角 | 天然兼容，零改动 |
| v4 硬编码映射 | 双边步用两个 dev（左口/右口各一）；v4 是 per-peer 单 dev，不同 peer 用不同 dev | 兼容；S3 需在双边步验证 per-peer dev 仲裁不冲突（S1 遗留风险 2） |
| PerSizeTuner | 2-hop 作为新算法条目，tuner 按 S2 阈值路由（≤阈值→2hop / >阈值→ring） | 加条目 + 阈值参数化（默认值来自 V4） |

### 6.3 回滚方案（沿用设计 §5.3）
- 库级：`/opt/nccl-ringonly/libnccl.so.2.30.7.bak-stageB-prod-20260816`（= v3）覆盖 + 重启即回滚。
- tuner 级：移除 2-hop 路由条目即回 ring（无需换库）——**首选**，因为 2-hop 只是新增算法条目，ring 路径与生产完全一致。
- 不做库级替换的过渡方案：S3 先以"ring + 2-hop 条目共存、默认关 2-hop"上线，观察后再开路由。

---

## 7. 风险与已知局限

| # | 风险/局限 | 等级 | 缓解/处置 |
|---|---|---|---|
| 1 | S2 是 torch 模拟，非真实 kernel；测不出 LL 叠加/零拷贝收益 | 中 | GO 线取保守值（0.80 而非设计 0.74）；S2 过线则 S3 更稳 |
| 2 | S1 模拟 1.75S 数据量 > 设计 1.5S → 带宽项劣化，中消息收益被低估 | 中 | V4 实测定标；S3 按 1.5S 实现 |
| 3 | CUDA graph Test B/D 是 torch 级代理，非真实 kernel capture | 中 | Test B/C 作硬关卡（保守）；Test D 信息项；真实 kernel 留 S3 专项 |
| 4 | V2b δ_hw 受 GB10 单口带宽限制，结果可能是"有限并发" | 中 | 判读按 δ_hw 三档；S3 按 δ_hw 决定 kernel 形态 |
| 5 | 卡死根因未修好 → 窗口空转 | 高（前置） | Rex 先单机 dry-run 验证；4.1 有 watchdog/心跳/超时清单 |
| 6 | 与 v2 基准窗口冲突（RDMA + GPU 争用） | 高（调度） | 严格串行；v2 完成后开 S2 窗口 |
| 7 | S1 残留 bench 进程污染 | 高（前置） | 5.2 前置清残留 + precheck GPU 0% |

---

## 8. 数据来源
- 本方案设计输入：`nccl-2hop-kernel-design-architect-2026-08-16.md`（2-hop 机制/收益/风险/阶段划分）/ `nccl-2hop-s1-prep-report-sre-2026-08-16.md`（S1 三验证项 + 卡死状态）/ `nccl-optimization-final-report-2026-08-16.md`（生产终态 2be94172 与回滚预案）/ `nccl-benchmark-v2-plan-qa-2026-08-16.md`（v2 矩阵 + 残留进程污染警告）/ `nccl-followup-tests-qa-2026-08-16.md`（并发放大 + 长窗口判读方法）。
- 脚本源码（本地副本）：`twohop_bench.py` / `twohop_algo.py` / `cudagraph_test.py`（远程 `/opt/2hop-s1/` 同源）。
- 实测锚点（设计文档引用）：裸 RDMA 1KB 2.40-2.42µs、368KB 32.4µs、4MB 313µs；生产 LL 44.6-54.7µs、368KB Simple 173µs。

---

*文档生成：2026-08-16（S2 验证方案，等批准 + 脚本修复 + v2 完成后开窗口）*
