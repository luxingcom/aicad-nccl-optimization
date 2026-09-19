# 错误模型 — ar2 错误码/超时层级/终止语义

错误码以 `include/ar2.h` 为唯一权威（本表 2026-09-03 与之逐行核对）。

---

## 1. 错误码

| 码 | 名 | 含义 | 可恢复性 |
|---:|---|---|---|
| 0 | AR2_OK | 成功 | — |
| -1 | AR2_ERR_INVALID | 参数非法（null/未对齐/超 smax/n 越界/几何不符） | 可（调用方修正后重试） |
| -2 | AR2_ERR_NOMEM | 内存/verbs 资源分配失败 | 一般不可恢复（环境问题） |
| -3 | AR2_ERR_TIMEOUT | 等待超时（engine_wait / CPU wait_dbell / ctrl 连接） | **不可**——已发 ABORT，comm poison |
| -4 | AR2_ERR_ABORTED | 主动/被动中止（abort 级联命中） | 不可（comm poison） |
| -5 | AR2_ERR_PROTOCOL | 协议错账（门铃 magic/seq 超界、CQE wr_id 错配、PeerInfo 几何失配、engine_wait 旗标超前） | 不可 |
| -6 | AR2_ERR_VERBS | RDMA 调用/CQE 失败（post 错误、WC 非 SUCCESS） | 不可 |
| -7 | AR2_ERR_POISONED | 会话已毒化（后续调用立即返回） | 状态码（终态） |
| -8 | AR2_ERR_UNSUPPORTED | 能力不支持（CPU 后端要 bf16 / 非 CUDA 要 graph / AR2_NO_GRAPH） | **可**（库内自动降级，调用方可继续） |
| -9 | AR2_ERR_FATAL | 保留码（当前无产生路径，审计口径 2026-09-03）；历史语义=不可恢复内部不变式破坏 | **进程必须终止**（若未来启用） |
| -10 | AR2_ERR_REMOTE | 对端错误经控制面传来 | 不可 |
| -11 | AR2_ERR_CUDA | CUDA API 失败（launch/capture/instantiate） | 不可 |

两层语义（对标 SparkRing 并细化）：
- **可恢复**（INVALID/UNSUPPORTED）：comm 未 poison，调用方可换参数/降级模式继续。
- **不可恢复**（TIMEOUT/ABORTED/PROTOCOL/VERBS/REMOTE/CUDA）：`abort_path` 已 poison——后续任何
  数据面 API 立即返回 poison_reason（通常表现为 TIMEOUT/ABORTED/POISONED）；进程层面应停止本
  collective 组的推理并退出/重建。
- **FATAL(-9)**：进程立即终止（不允许"带病续跑"）。

## 2. 超时层级（四级，从严到松）

| 层 | 值 | 作用 |
|---|---|---|
| kernel wait_two | 无自身 deadline | 由 engine 侧 deadline 兜底（kernel 只认 abort/dev_err） |
| engine_wait | `timeout_ms`（默认 5000, env AR2_TIMEOUT_MS） | 每旗标等待；超时 → TIMEOUT + abort 级联 |
| bell CQE 收割 | 5s（AR2_QP_TIMEOUT_S 常量） | verbs 传输异常兜底（与 QP retry 7×timeout14 匹配） |
| sync_stream | 5s | finalize 防御（kernel 已 abort 感知，正常会退出） |

**engine_wait 匹配语义**：本端旗标（producer/arm1/done）严格 `v==expect` 通过、`v>expect` 即
PROTOCOL（同 rank 旗标无偏斜可言）；对端门铃的超前容忍只在 kernel wait_two 层（有界 +1）。

**op 入口预检**：每次 allreduce 入口先查 `abort` 字与门铃 ABORT flag——对端已死时**不再 post**
（省去 QP transport retry 的秒级等待；W1 实测省 ~3.5s）。

## 3. abort 级联路径（数据面最快 33µs）

见 ALGORITHMS §7。三检查点：
1. kernel 自旋环（每 64ns 查 abort 字 + 门铃 ABORT flag）
2. engine_wait（本地 abort 字每次自旋转查；每 256 自旋查门铃 flags；每 4096 自旋查 TCP poll + deadline）
3. op 入口预检（post 前拦截）

## 4. dev_err（kernel 侧错误上报）

kernel 检测到 wait_two 错误时写 `ctl.dev_err = [code:8b][seq:32b@bit8]` 后全 block 退出；
engine_wait 自旋中发现非零 dev_err → 解码打印（link/码/want-seq/claim_ctr/engine-seq）→ 返回 PROTOCOL。
**kernel 永不无限自旋**：所有等待循环都有 abort/dev_err 出口（对比参考实现的 nanosleep 死等）。

## 5. kill 语义（外部死亡）

进程被 _exit/OOM-kill 时：对端表现 = 旗标等待超时（TIMEOUT，≤timeout_ms）——TCP RST 本身**不**
触发 REMOTE（`ctrl_poll_abort` 只认完整 8B 魔数消息）；对端 kernel 在门铃到达前不写 x，**不产生**
部分数据损坏。实测（W3）：rank1 _exit(9) @op30 → rank0（直连伙伴）干净 TIMEOUT（~5s）、
rank2/r3 经 ABORT 门铃级联秒级返回；无挂死、无僵尸、无进程 abort。
REMOTE 仅在收到 reason 未知名的 abort 广播时出现（罕见路径）。

## 6. 调用方契约（vLLM/上层集成时必读）

1. 任一数据面 API 返回非 OK 且非 UNSUPPORTED ⇒ **该 comm 生命周期结束**，只能 finalize。
2. UNSUPPORTED 是**能力协商**（如无 CUDA graph），库内已自动降级，调用方可以继续。
3. 一次 ar2_abort(reason) 可主动发起全局级联（reason 透传到控制面广播）。
4. 多线程：数据面 API **单线程调用**（engine 假设）；ar2_abort 可从任意线程调用（尽力而为）。
5. FATAL 类（-9）必须进程退出——不允许清理后续跑（内部不变式已破坏，取证优先：AR2_DUMP=1）。


## 7. NCCL ringonly V5 集成的失败语义（2026-09-04 E2E 定版）

V5 hook（nccl-ringonly-v5/src/collectives.cc）在 ar2 库错误模型之上叠加两层集成语义：

### 7.1 优雅降级（op 失败 → 永久禁用 + 本 op 原生重做）
ar2 op 失败（超时/协议/abort）时 hook **绝不向调用方抛错**（首版抛 ncclInternalError 直接
击穿 vLLM 启动链，E2E #1 实测）：置 g_v5Disabled 永久禁用，本 op 回落原生 NCCL 重做。
安全性依据：M1 用户缓冲区唯一写点（bf16_add_final）在最后一次 wait_two 之后，
失败 ⇒ 未到写回 ⇒ 缓冲区仍持原值；对端原生 op 挂起等本端加入，原生重跑即汇合。
（审计A3 修复补强：done 等待失败后有 100ms 宽限复查，封死"kernel 正在正确写回瞬间被误判
失败 → 原生重做读已归约输入"的微秒竞态窗口，见 ar2_core.cpp done_wait。）

### 7.2 fence-arm 失败 → 永久全原生（错误方向=安全方向）
四 rank 控制面栅栏（ar2_arm_fence）失败（共享 10s deadline 内未到齐 / NACK / 连接错）
→ v5ArmDead 永久置位，此后该进程全部分发关闭，恒走原生 NCCL。任何一 rank 降级/未武装
都会让其对端在下一个分发 op 上超时并同样降级（邻端经入口毒化检查立即失败，非 5s），
毫秒级收敛到"全 rank 全原生"一致态。

### 7.3 启动期禁分发（锁存）
见过 graph 捕获事件之前的所有 op（dummy run 等）一律不分发；捕获后首个大 AR 才触发栅栏。
依据：vLLM 启动期 warmup(eager) 与 capture(录制) 相位跨 rank 错位，本地判据不可靠
（E2E #1/#2 两次事故定谳，PITFALLS 2026-09-04 #1）。
