# Step1 结果: stageB tuner 移植 → RING 延迟回 µs 级 (Rex/SRE 2026-08-17)

## 新库
- 源码: /opt/2hop-s1/src/nccl-2hop-proto (commit 23a9798 + enqueue.cc hardened tuner + 未提交)
- 移植内容: 生产 2be94172 hardened stageB tuner (ncclPersizeTunerOverride, if/else 双分支生效,
  NCCL_TUNER_THRESHOLD 默认 40960B; <=40KB->LL, >40KB->Simple; IGNORE(-1.0) 防御; 仅 allreduce)
- 新 md5: d12f3f3f9fcd8ec65e7b4a2f63e3218e (libnccl.so.2.30.7, 60545792 bytes)
- 旧(无 tuner) md5: 2f21f6b9dd7b3d31c1d51e2ea047cd4a (备份为 libnccl.so.2.30.7.before-tuner)

## RING 延迟对照 (4-node, anemll test containers, NCCL_ALGO=RING)
- 旧 proto lib (2f21f6b9, 无 tuner): ~4.5ms 平坦 (已定位根因)
- 新 proto lib (d12f3f3f, +tuner):
  | n      | p50 us | avg us | sum_check |
  |--------|--------|--------|-----------|
  | 1024   | 42.8   | 54.8   | ok=True   |
  | 4096   | 50.4   | 72.7   | ok=True   |
  | 16384  | 88.3   | 103.1  | ok=True   |
  | 65536  | 244.2  | 247.3  | ok=True   |
- 判据达成: RING @1K-64K 回 µs 级 (S2 参考 38.6µs@4K, 同量级), 不再 4.5ms 平坦
