# 线上协议规范 — ar2 门铃协议 v2

版本：AR2_VERSION（`include/ar2.h`）；协议骨架血统 = `proto_2round_ar.c` v6（fabric 实测验证）
**v2（R3, 2026-09-04）**：PeerInfo 布局变更（`qpn[AR2_MAX_QPS]` + `nqp`），数据面新增多 QP 条带
与到达旗标字（seq 区 word16+）；nqp=1 时与 v1 行为逐位等价。v1/v2 会话混布被几何校验拒绝。

---

## 1. 控制面（TCP 星型，仅建连/交换/abort 中继/拆除）

- rank0 监听 `ctrl_port`（默认 9500）；workers 连 rank0，首字节自报 rank（**1 字节**，见 PITFALLS #1）
- 无效连接（rank 越界 / 重复 rank / 扫描器）**丢弃继续等**，不占槽
- worker 连接重试 240 × 0.5s，**每次重建 socket**（ECONNREFUSED 后旧 fd 已废，PITFALLS #2）
- 会话期保持连接：`ctrl_poll_abort`（MSG_DONTWAIT 8B 魔数消息 0xA2B0A2B0<<32|reason）与 finalize 拆除 barrier 复用

### PeerInfo 交换（一次性）
```
struct PeerInfo { u32 magic=0xA2C0A2C0; u32 version; u16 rank, dtype;
                  u32 smax, nslots; u8 gid[16];
                  u32 qpn[AR2_MAX_QPS]; u8 nqp; u32 rkey; u64 addr; }   /* v2 */
```
rank0 聚合 4×2 份广播全员；全员做**几何校验**（magic/version/smax/nslots/dtype/addr/nqp 任一不符 → AR2_ERR_PROTOCOL）。
随后 ready barrier（1 字节）确保全员 QP RTS 后才放行第一个 op（对端未 RTS 时 post 会 transport retry 秒级等待）。

## 2. 数据面（RDMA RC 单边 WRITE）

QP 参数（`link_connect`）：RC / path MTU min(active, 4096) / timeout 14 / retry_cnt 7 / rnr_retry 7 /
max_rd_atomic 1 / GRH gid_index 3（生产）/ hop_limit 64。R3：每链 nqp（1..4, env `AR2_QPS`）个 QP
共享 PD/CQ/MR，建连按 qpn 一一配对，参数逐 QP 独立迁移且与单 QP 期一致。

### 每 op 每 QP 两 WR 合链 post（`post_burst`, R3 条带形态）
```
每 QP q ∈ [0, nqp):
WR0: RDMA_WRITE  bulk 分段  local=send 槽[slot×smax + off_q, len_q]
                       remote=peer.arena + slot×smax + off_q        (recv 区)
                       unsignaled; len_q≤64B 时 INLINE
WR1: RDMA_WRITE  旗标   local=&db(8B 栈上)
                       remote= q==0: peer.arena + arena_ctl_off      (Ar2Ctl.dbell, 原协议)
                               q>0 : peer.arena + ctl_off + 56 + (16+q)×8   (seq 区旗标字)
                       INLINE | SIGNALED; wr_id=seq
→ ibv_post_send ×nqp；随后 reap_bell 计数收齐 nqp 个 wr_id==seq 的 SUCCESS CQE
（残留 CQE 会污染下一 op 的 wr_id 校验 —— 必须收齐才算 burst 完成）
```
**bulk 无 CQE**：完成性由旗标 CQE（同 QP 后继 WR）传递——RC 队列内保序，旗标可收割 ⇒ 本 QP bulk 已被对端 NIC 接收。
条带切分：bytes 连续切段摊到 nqp 个 QP（余数给前段），无对齐要求；消费侧收齐 dbell+全部旗标才动槽数据。

### 门铃字编码（64b）
```
┌─ magic 0xA2C0 (16b) ┬─ flags (16b) ┬─ seq (32b) ┐
flags bit0 = ABORT（其余保留，必为 0）
seq = 发送方引擎的单调 op 序号（**每 rank 单一 claim 计数器**，同一 seq 双链复用，从 1 起）
```
校验规则（读者侧，kernel `wait_two` 与 CPU `wait_dbell` 一致，比较用模 2^32 差 `diff = seq_doorbell − expect`）：
- `dbell==0`：未到达，继续自旋（**不是错误**，PITFALLS #7）
- magic 不符 → AR2_ERR_PROTOCOL
- flags bit0 → AR2_ERR_ABORTED
- `diff == 0xFFFFFFFF`（对端落后 1，含低 32 位回绕）→ 未到达，继续自旋
- `diff <= 1`（`seq == 期望值` 或 `seq == 期望值+1`，**有界偏斜容忍**，见 ALGORITHMS §4）且 `send_done ≥ 期望` → 通过；`diff==1` 计 skew 诊断（seq 区 word1）
- `diff` 为其他值（对端超前 >1 = 真错账）→ AR2_ERR_PROTOCOL
- ctl.abort≠0 → AR2_ERR_ABORTED

### R3 到达旗标（QPq>0，kernel `wait_flag` / CPU 镜像 `wait_flag`，仅 nqp>1 时逐 q≥1 校验）
- 值编码/校验与门铃字同源（magic/模 2^32 差/ABORT bit），落点 = 本端 arena seq 区 `word(16+q)`
  （word0/1=claim/skew，word2/3=金丝雀，4..15 预留，16..19 = 旗标，AR2_MAX_QPS=4）
- **无独立 send_done 门槛**：RC 队列内有序放置 ⇒ 旗标到达即本 QP 数据段已落槽（与门铃的
  bulk→doorbell 推理同源）；有界偏斜（diff==1）沿用槽数学直接放行
- abort 观测走所属链 `ctl.abort`（host abort_path 经 QP0 发 ABORT 门铃 + 本地字）

## 3. 旗标协议（host/device 握手, 每 op 五拍）

| 拍 | 发布者 | 旗标 | 观察者 | 语义门槛 |
|---|---|---|---|---|
| 1 | kernel | `producer=m` | engine | x 已拷入 send 槽（staged, fenced） |
| 2 | engine | 门铃 m（RDMA） | 对端 kernel | bulk+门铃已入对端 |
| 3 | engine | `send_done=m` | kernel | 门铃 CQE 已收割，send 槽可被 m+2 复用 |
| 4 | kernel | `arm1=m` | engine | sB=sA+rA 已写 linkB send 槽 |
| 5 | kernel | `done=m` | engine | x=sB+rB 已写回（本 op 完结） |

内存序契约：
- kernel 侧发布 = `__threadfence_system()` + volatile store（`dev_pub`）
- engine 侧发布 = `__atomic_store_n(..., __ATOMIC_RELEASE)`（`st_release`）；读取 = ACQUIRE（`ld_acquire`）
- 槽数据访问 = `__stwt`（写透系统内存）/ `__ldcv`（绕 L2 易变读）——W3 防御性强化

## 4. 序号（seq）语义

- 每 rank 一个全局 claim 计数器（linkA arena seq 区 word0，kernel `atomicAdd_system` / CPU `__atomic_fetch_add`）
- op 的 seq = claim 返回值+1，**执行时**分配（graph replay 安全）
- engine 的 `seq_` 为算术镜像：layer_replay 按一次 n 个对齐；正常路径下 `claim_ctr == seq_` 恒成立
  （finalize 取证会打印两者；不等即协议错账）
- 槽选择唯一公式：`slot(m) = (m-1) % nslots`——**engine/kernel/对端三方必须同式**（曾有错位教训，PITFALLS #6）
- 门铃 seq 与 bulk 槽绑定：对端按 seq 定槽写，本端按 seq 定槽读

## 5. ABORT 语义（三层传播）

1. 本端立即：`abort=1` 写双 ctl + `poisoned=true`（后续 API 调用直接返回 poison_reason）
2. 数据面尽力：双链各发 1 个 ABORT 门铃（unsignaled inline，无 CQE 不等待）→ 对端 kernel/engine 自旋环内 33µs 级发现
3. 控制面保底：TCP 广播魔数消息 → 慢路径 rank 在 engine_wait 每 4096 自旋的 poll 中发现

错误码透传规则：abort 消息携带首个 reason；被动方收到后以 AR2_ERR_ABORTED（或透传 reason）失败。

## 6. 拆除（finalize）

`sync_stream`（kernel abort 感知，5s 上限）→ 取证输出（AR2_DUMP=1 时）→ 双向 1 字节 barrier
（尽力而为 500ms）→ 关闭 TCP/销毁 QP/MR/arena。**不保证在途 op 完成**——错误路径下允许丢弃。
