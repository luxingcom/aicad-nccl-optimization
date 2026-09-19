# 架构资料 — ar2 模块 (ringonlyV5 / S2)

配套代码：`src/`（本文所有断言以代码为准；不标行号防漂移，以函数名/结构名定位）

---

## 1. 设计目标与约束

| 项 | 值 | 来源 |
|---|---|---|
| 优化目标 | **每层矩阵数据交换完成总时间最短**（端到端，含 host enqueue） | 用户立项指示 |
| 目标域 | 解码期小消息 allreduce，bf16，16B ≤ S ≤ 32KB | W2 窗口 SIRCL 实测收益区 |
| 平台 | 4× DGX Spark (GB10/SM121, arm64, CUDA 13.0)，RoCE 双网卡对偶环 | 集群台账 |
| 错误处理 | 对标 SparkRing 并强化（见 ERROR-MODEL.md） | 用户立项指示 |
| 非目标 | ≥64KB 大消息（单 QP 串行带宽塌陷，交还 NCCL ring） | W2 实测 |

## 2. 拓扑与链路几何

```
        linkA (rank^1)              linkB (rank^3)
rank0(186) ──── rank1(187)      rank0 ──── rank3(188)
    │  ↕  round1 交换 partner=rank^3: (0,3) (1,2)
    │
rank3(188) ──── rank2(189)      rank1 ──── rank2
```

- **round0**：与 `rank^1` 交换（直连邻居），链路 dev0（生产 = `rocep1s0f1`）
- **round1**：与 `rank^3` 交换（跨环邻居），链路 dev1（生产 = `roceP2p1s0f0`）
- 两轮各用**不同物理网卡** → 避开 W2 实测的 δ_hw 双边并发串行化（64K 边界 1.30 / ≥256K 1.81-3.10）
- world=2 时 linkB 自环（`peer_of`: `world==2 → rank`），仅用于 CPU 后端自测

## 3. 进程/线程模型

```
每个 rank 一个进程 (probe/vLLM worker):
┌──────────────────────────────────────────────────┐
│ 调用线程 (=engine, 单线程!)                        │
│   ar2_allreduce / ar2_allreduce_layer             │
│   ├─ Device::op_submit ──→ ar2 stream (非阻塞)    │
│   ├─ engine_wait (自旋 host 旗标)                 │
│   └─ post_burst (ibv_post_send ×1 + reap CQE)     │
│ GPU: ar2_fused_kernel (1 block × 256 线程/op)     │
│   自驱: claim → stage → 等门铃 → 归约 → 发布       │
│ TCP 控制面线程: 无专门线程 (poll 复用 engine 自旋) │
└──────────────────────────────────────────────────┘
```

**关键决策**：engine（host 驱动）与 kernel（device 自驱）**分工而非轮转**——
kernel 完成数据搬运与归约并在 device 侧自旋等待门铃；engine 只做 verbs post 与 CQE 收割。
这样每 op 的 host 工作只有 2 次 `ibv_post_send`（SparkRing 为 6 次）。

## 4. 内存布局（每链路一个 arena）

```
arena (cudaHostAllocMapped, NIC 可注册 + device 可见):
┌─────────────────────────────────────────────┐
│ recv  区: nslots × smax   (对端 NIC DMA 写入)│  offset 0
│ send  区: nslots × smax   (本端 kernel staged)│  offset nslots×smax
│ Ar2Ctl: 56B 控制块 (NIC/host/device 三方可见) │  offset arena_ctl_off
│ seq 区:  64 × 8B                              │  offset ctl+56
│   word0 = device claim 计数器 (atomicAdd)      │
│   word1 = 偏斜命中计数 (诊断)                  │
│   word2/3 = kernel 金丝雀 (取证)               │
└─────────────────────────────────────────────┘
默认 smax=65536, nslots=2 → 每 arena 2×2×65536+56+512B ≈ 256KB
```

`Ar2Ctl` 七字契约（偏移即契约，`ar2_internal.hpp`）：

| 偏移 | 字段 | 写者 | 含义 |
|---:|---|---|---|
| 0 | dbell | **对端 NIC** (inline WRITE) | 门铃字 [magic16\|flags16\|seq32] |
| 8 | producer | 本端 kernel | x 已 staged 进 send 槽 (seq) |
| 16 | send_done | 本端 engine | 门铃 CQE 已收割，send 源可复用 (seq) |
| 24 | arm1 | 本端 kernel | round0 已归约进 linkB send 槽 (seq) |
| 32 | done | 本端 kernel | 最终结果已写回 x (seq) |
| 40 | abort | 本端 host/device 双方 | abort 代数 (非 0 = 终止) |
| 48 | dev_err | 本端 kernel | 错误码 [code8\|seq24] |

## 5. 执行模式

### M1 — 单 op 串行（`allreduce_one`, src/ar2_core.cpp）
```
入检(abort/门铃) → seq=++seq_ → op_submit(launch kernel)
→ wait producer(seq) → postA(槽) → send_done → prepare(1)
→ wait arm1(seq) → postB(槽) → send_done → prepare(2)
→ wait done(seq) → return
```
kernel launch 与 engine wait 并行推进；`prepare_milestone` 仅 CPU 后端有实现。

### M2 — 整层固化（`ar2_capture_layer` + `layer_replay`, src/ar2_core.cpp）
```
capture: BeginCapture(ThreadLocal) → 录制 n 个 kernel launch → Instantiate
replay : base=seq_+1; seq_=base+n-1 (算术对齐 device claim)
         launch_graph → for i: 与 M1 相同的 engine 循环 (seq=base+i)
```
- graph 内 kernel **线性链**（同流捕获），执行序 = claim 序 = engine 算术序
- seq 由 **kernel 执行时原子 claim**（非 host 写入）——跨 replay 安全（W2 教训）
- 缓冲区/字节数组不匹配时 `graph_matches` 失败 → 自动回退 M1 串行（兼容层）

### M3 — 回退路径
`AR2_NO_GRAPH=1` 或 capture 返回 UNSUPPORTED（非 CUDA 后端）→ layer API 退化为逐 op M1。

## 6. 数据面时序（单个 op，四视角）

```
engine(rank r)                kernel(r)                    engine(rank r^1)             kernel(r^1)
─────────────                 ──────────                   ───────────────              ───────────
wait producer(m)  ◄─────────── claim m → stage x→sA ──────┐
postA: [bulk(sA→peer.recv) ────┐                          │
        bell(m)→peer.ctl] ───────────────────────────────►│ wait producer(m)…
reap CQE → send_done=m         wait_two(A,m) ◄── 对端 bell(m)+bulk 落槽
wait arm1(m)     ◄───────────── sB=sA+rA → arm1=m
postB: [bulk(sB) + bell(m)]    
reap CQE → send_done=m         wait_two(B,m) ◄── 对端 bellB(m)+bulk
wait done(m)     ◄───────────── x=sB+rB → done=m
```

每 rank 每 op 发 4 个 WR（linkA 2 + linkB 2，各为 bulk+门铃合链；对端对称亦 4）；每 rank 总线量 2S。

## 7. 槽复用安全性论证（load-bearing 不变式，改动前必读）

`nslots=2` 时 `slot(m) = (m-1)%2`，op m 与 op m+2 共享槽。四个共享方向均被门铃/CQE 链闭合：

1. **本端 send 槽被 kernel(m+2) 覆盖 vs engine(m) 的 bulk DMA 读**：
   kernel(m+2) 在 kernel(m+1) 退役后才执行，而 kernel(m+1) 的 B-wait(m+1) 需要 engine 的
   postB(m+1)——而 engine 在 postB(m+1) 前已完成 post_burst(m) 的**门铃 CQE 收割**
   （bulk(m) 的 DMA 源读已完成）。⇒ 覆盖必然晚于 DMA 读。
2. **本端 recv 槽被对端 bulk(m+2) 覆盖 vs kernel(m) 的 rA 读**：
   对端 post(m+2) 需对端 producer(m+2) ← 对端 kernel(m+2) ← 对端 kernel(m+1) 退役 ←
   对端 B-wait(m+1) ← **本端 bellB(m+1)** ← 本端 arm1(m+1) ← 本端 kernel(m+1) A-wait(m+1)
   ← 本端 kernel(m) 已退役（rA 已读毕）。⇒ 时序闭合。
3. **round1 sendB/recvB 同理**（arm1/done 门铃链）。
4. **有界偏斜**（wait_two 容忍 d==seq+1）不破坏 2：对端最多领先 1 op，其 m+2 门铃仍被
   本端 m+1 依赖链挡住 ⇒ recv 槽内 seq 数据永远完好。

> 违反前置条件的改动（如 nslots>2、engine 异步化、kernel 提前 stage）必须重新论证此节。

## 8. 模块依赖图

```
include/ar2.h ─── 公共契约 (11 函数/错误码/配置)
      │
src/ar2_internal.hpp ─── 内部契约 (Ar2Ctl/arena/Link/Device 接口/工具)
      ├─ src/ar2_core.cpp    引擎+控制面+verbs+M1/M2+abort+取证   [必链]
      ├─ src/ar2_dev_cuda.cu CUDA 后端 (弱符号 make_cuda_device)   [GPU 可选]
      └─ src/ar2_dev_cpu.cpp CPU 后端 (自测)                        [必链]
tools/ar2_probe.cu / ar2_selftest.cpp ── 验证面 (不进生产链)
```

弱符号设计：selftest 仅链 core+cpu 时 `make_cuda_device` 解析为 null → `ar2_available()` 报 CPU。

## 9. 与参考实现 (SparkRing) 的对照

| 维度 | SparkRing (参考) | ar2 (本模块) |
|---|---|---|
| 每 op WR 数 | 6 | **2**（bulk+门铃合链） |
| seq 分配 | host 写映射字 | **device 原子 claim**（graph replay 安全） |
| 超前门铃 | eager 容忍 / graph 严格 | **有界容忍 d≤seq+1，>seq+1 报错** |
| abort | 各 rank 等满 deadline | **33µs 门铃级联 + kernel abort 感知退出** |
| 错误面 | 有限 | 两层分级 (可恢复 rc / FATAL 进程终止) + 取证转储 |

## 10. 已知架构边界（变更风险区）

- `AR2_MAX_LAYER_OPS=64`：单 graph 固化上限；DSV4 生产层几何 = 8 op × 12288B
- 单 block kernel：>128KB 消息时 256 线程拷贝成为瓶颈（价值区外，不修）
- engine 单线程假设：所有 host 侧自旋/ posting/取证环都假设调用线程唯一
- arena 为 host 映射内存：kernel 对槽数据用 `__stwt/__ldcv`（W3 防御性保留）


## 11. NCCL ringonly V5 hook 分层与 fence-arm 时序（2026-09-04 定版）

```
vLLM (torch/c10d ProcessGroupNCCL)
  └─ ncclAllReduce()  C 入口          [libnccl.so.2 = nccl-ringonly-v5 树]
       ├─ V5-HISTO 尺寸普查 (AR2_V5_HISTOGRAM=1, 先于一切早退)
       ├─ 条件①~⑥: bf16/就地/nRanks=4/16≤B≤crossover(8192)/对齐/group 规则 v3
       ├─ 条件⑦: cudaStreamIsCapturing ≠ None → 原生 + 锁存 v5SawCapture
       ├─ 条件⑧ 锁存: 未武装且(未见捕获 | 小 op | 已弃) → 原生
       │    触发点 = 捕获后首个 >crossover 大 AR (全 rank 同逻辑必经)
       │    → ar2_arm_fence: worker 'F' → rank0 共享10s 收齐 → 'G' (失败 'N' 对称失败)
       │    → v5Armed=1 此后 SPMD 锁步分发
       ├─ [armed] ar2_allreduce_stream(comm, buf, bytes, caller_stream)
       │    └─ dlopen libar2.so.1 (懒加载一次, leak-by-design)
       │         └─ M1 五拍: stage/claim → wait producer → postA → round0 → postB → round1+终写
       └─ [任一条件不满足/失败] → 原生 ncclEnqueueCheck (NCCL ring)
```

关键不变式：**分发决策必须是全 rank 逐 op 一致的函数**。启动期无全局栅栏，故用锁存+栅栏
把"开始分发"这一相变对齐到全 rank 同逻辑的大 AR 上；武装后服务是 SPMD 锁步，天然一致。

### E2E 结构定谳（决策输入）
生产 FULL_AND_PIECEWISE CUDA graph 形态下，稳态 decode 的 TP 通信在 **graph 重放内**
执行（重放不经过 ncclAllReduce 入口），prefill AR 全为 >crossover 大尺寸 ⇒ NCCL hook 型
集成的稳态可达人群 ≈ 0（E2E-REPORT §6：满载 2.5h 分发 <65536 op vs 理论 ~5.8M）。
收益落地路线 = 捕获期集成（ar2_capture_layer/M2 在 vLLM 捕获点接线，vLLM patch 级），
见 OPEN-ISSUES #10 与 docs/INTEGRATION-ROADMAP.md。
