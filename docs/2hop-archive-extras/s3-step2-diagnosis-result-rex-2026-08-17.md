# Step2 结果: 根因诊断 — 结构性确认 (Rex/SRE 2026-08-17)

## 结论
2HOP 算法路径的失败是【结构性/基础设施】问题, 而非 kernel 层 in-place 竞态。
carry/temp-buffer 修复(Arch 裁定假设)无法解锁。判据 bilateral kernel ok=True 未达成
(SIMPLE 死锁; LL 走 ring fallback 仍是同一垃圾值) -> 结构性确认 -> A/D 决策点。

## 关键对照实验 (4-node, mini3, 期望 6.0)
| 测试 | lib | algo | proto | 结果 |
|------|-----|------|-------|------|
| RING | d12f3f3f (tuner) | RING | LL (默认) | ok=True [6.0], 40.2µs |
| 2HOP ring-fallback | 2f21f6b9 (old) | 2HOP | LL (强制) | ok=False [783.875, 3.015686] |
| 2HOP ring-fallback | d12f3f3f (tuner) | 2HOP | LL (默认) | ok=False [783.875, 3.015686] |
| 2HOP ring-fallback | d12f3f3f | 2HOP | Simple | ok=False [783.875] (64K) |
| 2HOP carry-kernel | c47b4637 (step2) | 2HOP | LL (4K, 落入fallback) | ok=False [783.875] |
| 2HOP carry-kernel | c47b4637 | 2HOP | Simple (64K, 真跑carry) | 死锁/挂起 (rc=1, timeout 220s, log 30B) |

## 核心逻辑
1. commit 23a9798 的 run2Hop = 【无条件 runRing】, 与 RING 完全同一份 kernel 代码。
2. 2HOP 与 RING 顶层 setup 一致: proto LL, channel{0..0}, count 1024, sendbuff==recvbuff, 相同 ring 连接。
3. 但 2HOP 走同一份 runRing 产生垃圾 [783.875], RING 却正确 -> 2HOP 的 algo 级集成(成本模型/工作结构/代理)损坏。
4. carry 修复 kernel (双缓冲 temp buffer, send 源=C0/C1, recv-reduce 只写 M):
   - SIMPLE(64K): 真跑 carry kernel -> 死锁 (历史已知 SIMPLE 死锁 双 Primitives 问题复现)
   - LL(4K): 因 tuner 阈值语义 (threshold=0 不生效, 4K<=40KB->LL) 落入 ring fallback -> 同垃圾值
5. 三种调度(形式B/形式C/direct primitives) + ring-fallback + carry-fixed 全部同一垃圾值 -> 单一机制根因
   在 algo 基础设施, 不在 kernel。

## 新库
- Step2 lib (carry kernel): md5 c47b463796a058851e17d1dbde21d580 (备份 libnccl.so.2.30.7.step2-carry)
- 编译: 需 NVCC_GENCODE='-gencode=arch=compute_120,code=sm_120' 全量 clean 重建
  (默认 gencode 集会导致 nvlink sm_75 未定义引用错误)

## 对 A/D 决策的建议方向
- D-分析: 深挖 2HOP algo 级集成缺失点 (graph/tuning bandwidths 为 2HOP 初始化? proxy op pattern? chunkGrains?)
- 或回归 RING 基线 (已 µs 级 ok) 评估 2-hop 是否值得继续

## 根因方向 (NCCL_DEBUG=TUNING 实证)
2HOP 的成本模型未初始化: ncclTunerConstantsDefaults (tuning.cc:148) 的 baseLatencies/hwLatencies
只初始化了 7 个 algo (Tree/Ring/CollNetD/CollNetC/NVLS/NVLSTree/PAT), 无 index 7 (2HOP) 条目 -> 0 填充。
NCCL_DEBUG=TUNING 表显示:
  RING AllReduce LL latency = 36.6, PAT LL = 5.0
  2HOP AllReduce LL/LL128/Simple latency = 0.0/0.0/0.0   (bandwidth 列在该表中全为 0, 不具判别性)
=> 2HOP 的 topoGetAlgoInfo 成本计算退化 (latency=0), 导致 work 参数/调度异常, 即使同一份 runRing 也产生垃圾。
建议 Archi 优先检查: tuning.cc ncclTunerConstantsDefaults 补 baseLatencies[7]/hwLatencies[][7]
(镜像 RING 值), 以及 graphs[7] 的图/连接是否真正为 2HOP 建好。
