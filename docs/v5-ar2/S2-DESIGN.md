# S2 项目设计 — ar2：GPU 2 轮全交换 AllReduce 传输模块

日期：2026-09-03（S2 立项，用户采纳）
上游证据链：CPU 微测 9.49µs@4KB（4.65×）→ GPU 真实内存语义 SIRCL 探针 21.2µs@4KB（vs NCCL ring 31.4µs，+33%）→ 收益区 ≤16-32KB
参考实现：`~/sparkring-kit/sparkring/spark_transport`（SparkRing 克隆，错误处理范式与 enqueue 开销账单来源）

---

## 1. 目标函数（用户定标）

**每层矩阵数据交换完成总时间最短** —— 不是单点/单 op 延迟。每 decode step 本集群 AR 次数 128（86+42），故优化对象是：

```
T_layer = launch 摊销 + Σ(op 延迟) − 流水线重叠
```

验收口径以 **layer-loop**（k 个 AR 背靠背，总时间/k + 首 op 延迟单列）为准，单 op p50 仅作参考项。

三档执行模式，按摊销深度递进：

| 模式 | 每 op host 开销 | 状态 |
|---|---|---|
| M1 eager inline：每 op 2 kernel launch + 2 WR burst | ~2×launch+2 post | 基线（探针路径模块化） |
| M2 graph replay：capture 一次 [kR0,kR1]，每 op 1 graphLaunch | 1×graphLaunch+2 post | 主攻档 |
| M3 persistent + device 队列：每 layer 1 launch，内核自驱 | ~0 launch+2 post | 冲刺档（v0.2，需 credit 流水） |

## 2. 架构

```
┌─ vLLM/torch 调用方（bf16, in-place, ≤ S_max=64KB）
│    ar2_init / ar2_allreduce[(_begin/_poll)] / ar2_layer_* / ar2_abort / ar2_finalize
├─ ar2_core.cpp   协议引擎（串行深度=1）、WR 合批、MR 注册缓存、错误模型
├─ ar2_kernel.cu  门外铃自旋+规约内核（abort 感知、双等待语义）
├─ ar2_graph.cu   M2 capture/replay（seq 经 device 可见计数参数化）
└─ 传输层          2×VerbsEndpoint（linkA=rank^1/rocep1s0f1，linkB=rank^3/roceP2p1s0f0，GID 3）
    + TCP 控制面（bootstrap / EndpointInfo 交换 / ABORT 广播）
```

数据面（相对 SparkRing 的三处削减，均有探针证据）：
1. **零暂存直写**：R0 直接从用户 GPU buffer（注册 MR 缓存命中后）RDMA WRITE；peer 写入 arena recv 槽；内核原地规约 `x += recv`。无 mapped-host 暂存拷贝（SparkRing 单 SM staging 是其大 payload 塌陷主因）。
2. **WR 合批**：每轮 1 次 `ibv_post_send` 携 [bulk(不签名), doorbell(签名+inline)]（SparkRing 每轮 3 post 6/op；S2 = 2 post/op）。
3. **无 ack 尾 WR**：2 槽 + 严格 seq 门外铃替代 serial-ack 往返（探针 v6 验证）。

协议（探针 v6 语义固定化）：
- 门外铃 8B = `[magic16=0xA2C0][flags16][seq32]`；flags.ABORT=0x1；64B 对齐；magic 检错（SparkRing wire_protocol 思路）。
- 每 op：R0 发 x 全量 S 至 linkA，收 peer 全量，`x += recvA`（kR0）；R1 发 x 至 linkB，收对方部分和，`x += recvB`（kR1）。每 rank 总线 2S。
- **双等待语义**（消除覆写竞态）：kR0 同时等 ① peer doorbell（NIC 写入 device 标志）② 本端 send0_done（host 收割 bellA CQE 后写 GPU 可见标志）。②通常先于①到达，不进关键路径；arm1 ⇒ send0 已完成，host 只等 arm1 即可 post R1。
- 槽复用：2 槽交替，串行深度 1（poster 严格按 op 序）下安全链闭合；v0.2 M3 用 4 槽+credit 解深度 3。

## 3. 错误处理与报错终止（对标 SparkRing，四处强化）

**继承**（spark_transport 实测范式）：
- 所有等待有 deadline（env `AR2_TIMEOUT_MS`，默认 5000，与 kGraphProtocolTimeout 同量级）；到期抛 `ar2_error`（runtime_error 语义 + 上下文串）。
- **native work 入队后 fail-fast**：一旦本 op 的 bulk WR 已 post，错误 ⇒ 进程终止路径（SparkRing README 不变量：CUDA stream 可能含未满足 wait，进程内回退不安全）。
- 会话毒化：同步路径错误置 `poisoned_`，后续调用立即报错不重试。
- teardown 逆序幂等：sync stream → 等已发布命令收敛 → join 线程 → endpoint（QP→CQ→MR→PD→ctx）先于 buffer 释放；构造半途失败走同一 cleanup。

**强化一：ABORT 门外铃传播**（SparkRing 无 peer 通知，靠各 rank 各自等满 5s）
本端任一等待超时 ⇒ ① 置本地 abort 槽 ② 向两条 link 各 post 一个 ABORT 门外铃（peer 的内核/spin 立即解锁）③ TCP 控制面广播 ABORT 给全部 rank（覆盖非 link 邻，如 rank2 对 0-1 链故障）。故障感知 5s → 亚毫秒。

**强化二：内核 abort 感知退出**（SparkRing `graph_fatal_wait()` 无限 nanosleep 占 SM）
所有 device 自旋循环每 1024 次检查 abort 槽；发现即写出 device 错误码并**正常退出**内核，不占 SM。不变量违例（seq 超前、ring 破损）同路径。

**强化三：门铃 magic + flags 校验**——错序/错线/腐化门外铃立判，不静默错账。

**强化四：两级终止语义显式化**（API 契约写明）：
- `AR2_ERR_*` 可返回：错误发生在本 op 首个 WR post 之前（会话未污染）或仅 CPU 侧（绑参/尺寸超限/poisoned）。
- `ar2_fatal()`（noreturn 语义：打印后 abort）：RDMA post 之后发现的错误。调用方（未来 V5/vLLM 集成）按此设计重试/重启边界。

## 4. Host enqueue 压缩清单（21.2 → 目标 ≤14µs@4KB，M2）

| 开销源（SparkRing 账单） | S2 对策 |
|---|---|
| 每 op 2×cudaLaunchKernel + cudaEventRecord + cudaEventQuery 自旋 | M2：1×graphLaunch；事件门整体删除（caller stream 语义由 API 契约接管） |
| 6×ibv_post_send | 2×（每轮 1 burst：bulk+bell） |
| mutex + 2 condvar + 进度线程串行化 | v0.1 无锁单写者：caller 线程内联驱动（深度 1 下无竞争） |
| 单 SM mapped-host staging 拷贝 | 删除：NIC 直读用户 GPU MR（探针验证），内核原地规约 |
| 自旋无 pause 烧核打总线 | 分层 pause（aarch64 yield / 4096 miss 后 std::yield，SparkRing adaptive policy 取核内段） |

M2 细节（吸收 SparkRing graph 教训——其 2.8ms/call 来自 yield 停车 + 逐 op 校验 + 逐 iter 全同步，而非 graph 本身；其 burst 门 25µs 证明热路径快）：
- capture 固定 [kR0, kR1] 于 caller stream；seq/slot 参数化 = host 在两次 replay 之间写 device 可见 `cur_seq` 字（kernel 自读，无 graph 参数变更）。
- replay 后 caller 线程内联：等 arm1（host 可见 GPU 标志，GB10 一致性 <1µs 可见）→ post R1 → 等 done。
- 探针脚本必须 burst 化（无逐 iter 校验/同步），验证 pass 单独跑。

## 5. 内存纪律（OOM 事故后置顶）

- 全部内存在 init 一次性预分配：2 link × 4 槽 × (S_max 收 + S_max 发) + 控制块 ≈ **1.1MB/rank**（S_max=64KB，槽 4——深度 1 只用 2 槽，4 槽为 M3 预留）；`AR2_SMAX` 可调。
- 数据路径零分配（MR 缓存 = 固定 128 槽开地址表，无 malloc）。
- 自测门：10k op RSS 增量 < 8MB；进程数/线程数固定（1 控制面线程 + caller 线程）。

## 6. V5 集成接口（预埋，S2 收口后启用）

```c
/* 按尺寸路由咨询——V5 tuner 在 enqueue 决策点调用 */
ar2_recommended(S) -> AR2 | RING    /* 交叉点实测定版，env AR2_CROSSOVER_B 覆盖（默认 32768） */
ar2_available() -> bool             /* 环境就绪性（QP/内存语义/拓扑检查） */
```
V5（NCCL 2.30.7 hardened 树 + skip-tree-pat）将把 ≤ crossover 的 TP AR 改道 ar2（LD_PRELOAD 旁路或 tuner 内直调），> crossover 维持 ring Simple/LL 现行；交叉点以窗口 G2 实测定版。镜像化：S2 库与 V5 lib 一起烘入 baked-v6 测试镜像。

## 7. 验收门（窗口 W3 执行）

- **G1 正确性**：1/2/4/8/12/16/24/32/48/64KB × bf16 × 200 iter × M1/M2，逐元素精确；abrt 注入下无挂起。
- **G2 延迟**：单 op p50@4KB ≤ 16µs（stretch 13）；@16KB ≤ 34µs；**layer-loop（8 op 背靠背）每 op 摊销 ≤ 1.15× 单 op**。
- **G3 错误终止**：kill -9 任一 peer 中途 → 存活 rank 3 端 ≤ deadline 内返回错误码（非挂起）；TCP 广播覆盖非 link 邻；teardown 后容器可干净重启（QP/端口无残留 TIME_WAIT 堆积）。
- **G4 内存**：10k iter RSS Δ < 8MB/rank；arena 常驻 ≤ 2MB；无新增长驻线程/进程。

## 8. 当前轮次交付边界与实测状态（2026-09-03 W1 轮更新）

W1 轮已完成的实测（生产外部停机窗口内）：
- **M1 全绿**：四机 GPU 全尺寸正确+计时（1KB 20.5µs -28%、4KB 24.9µs -21% vs NCCL；16KB 持平；64KB 落后=价值区外交还 ring）
- **错误模型全验证**：ABORT 门铃传播 33µs；G3 kill 测试 6s 干净终止无挂起；RSS 门 4KB/10k op
- **M2 未过**：graph 内核读到旧 seq 字（want=23 obs=1160 实锤），修复方向=device 端 seq claim（SparkRing graph_publish_command 模式）或 replay 前 device fence——冻结待修，验收门 G2 的 layer-loop 摊销项顺延
- 详见 S2-W1-REPORT-20260903.md

非窗口轮次只做：设计定稿、v0.1 实现、glibc 2.35 兼容构建、单机 CPU 自环错误路径自测（<100MB 足迹）。GPU/四机实测封进 runbook（run_s2.sh），等停机窗口。
