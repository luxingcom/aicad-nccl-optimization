# 生产环境问题修复确认清单 (2-hop 收尾配套, Task 2)
**日期:** 2026-08-17 | **作者:** Rex (SRE) | **状态:** 逐项已核对

---

## 汇总
| # | 问题 | 结论 | 状态 |
|---|------|------|------|
| 1 | bench_v2.py 60s 读超时 bug | 已修复并生产在位 | 已修复✅ |
| 2 | 4.5ms 延迟异常 | proto 测试库缺 stageB tuner (非生产问题) | 非生产问题✅文档化 |
| 3 | 测试容器 LD_PRELOAD 生产库挂死 | 非生产问题, 已知限制 | 非生产问题✅文档化 |
| 4 | NCCL_IB_PEER_HCA env 残留 | ADR/部署指南已记录弃用; 脚本仍残留 | 已记录弃用✅, 建议清理🔧 |
| 5 | nccltune 遗留容器 | 已清理 (S2 前 25 个), 无复发 | 已修复✅ |
| 6 | 生产四机脚本 env 一致性 | 与部署指南一致 (实测 4 rank) | 已修复✅ |

---

## 1. bench_v2.py 60s 读超时 bug
- **问题**: run_one() 读超时硬编码 `min(timeout,60)`, 长前缀并发下首块等待 >60s 被误判超时; ReadTimeout 非 Timeout 子类, 落到 Exception 被归 other。
- **根因**: requests read timeout 是"每读"而非总量, 60s 上限误伤长首块。
- **处置**: FIX-20260816 → `timeout=(connect_timeout, timeout)` 全量放开; ReadTimeout 显式归 timeout 类; wall-clock deadline 兜底。
- **状态**: 已修复✅
- **生产在位**: /opt/aicad-prod/bench_v2.py md5 f72e9e84397ebd8cb6ffbcc8825535bf (43,868 B)
- **备份**: /opt/aicad-prod/backup/bench_v2.py.bak-60s-fix-20260816 md5 6ed8ce93db5a2c95a4cbd8a20a42ebb6
- **文档位置**: 本清单; ADR S1.13; archive MD5-RECORD.txt §3

## 2. 4.5ms 延迟异常
- **问题**: 2-hop proto 测试容器 RING allreduce 延迟 ~4.5ms 平坦。
- **根因**: proto 测试库缺 stageB tuner (非生产缺陷; 生产 2be94172 有 tuner 正常 µs 级, BenchV2 PR 2414-3800 tps 佐证)。
- **处置**: proto 库移植 stageB tuner 后恢复 µs 级 (step1: 1K=42.8µs / 4K=50.4µs / 16K=88.3µs / 64K=244.2µs)。
- **状态**: 非生产问题✅文档化
- **教训**: 测试库必须带 tuner, 否则延迟失真 (不得据此判定生产)。
- **文档位置**: s3-step1-tuner-result-rex-2026-08-17.md; archive/data/s3-g3-ring-baseline.json (对照); 本清单

## 3. 测试容器 LD_PRELOAD 生产库挂死 (S3 窗口发现)
- **问题**: 2be94172 进 S3 测试容器 init 前挂。
- **根因**: 测试容器兼容性 (非生产问题; 生产容器跑 2be94172 正常 healthy)。
- **处置**: 记录为已知限制; S3 改用独立构建 proto 库测试。
- **状态**: 非生产问题✅文档化
- **教训**: 测试容器兼容性需先行验证, 不得直接假设生产库可注入任意测试容器。
- **文档位置**: s3-phase1-window-execution-sre / s3-phase1-qa-checklist; 本清单

## 4. NCCL_IB_PEER_HCA env 残留
- **问题**: Stage B 部署时发现 NCCL_IB_PEER_HCA env 仍传入, 被新库忽略。
- **根因**: v4 硬编码 per-peer netDev 映射内置, 库忽略该 env (ADR-015 决策 B)。
- **处置**: ADR-015 记录弃用; 部署指南 L504 注明 "NCCL_IB_PEER_HCA 已弃用 (v4 硬编码映射内置, 库忽略)"。
- **状态**: 已记录弃用✅; 脚本仍残留 🔧建议清理
- **实证**: 四机运行容器均仍带 NCCL_IB_PEER_HCA (rank0-3), 但服务 healthy, 证明库确实忽略。
- **建议**: 下次部署窗口从 start_tp4_head.sh L122 / start_tp4_worker_deepgemm.sh L117 移除 (低风险, 不阻塞当前)。
- **文档位置**: ADR-015 (nccl-tuner-netdev-hardcode-adr-architect-2026-08-16.md); 部署指南 L504; 本清单

## 5. nccltune 遗留容器
- **问题**: 曾发现 25 个 nccltune 遗留容器。
- **处置**: S2 前已清理 25 个。
- **状态**: 已修复✅ 无复发 (docker ps -a 无 nccltune 容器)
- **文档位置**: 本清单; cleanup-index-20260812

## 6. 生产四机脚本 env 一致性
- **实测 4 rank (docker exec env)**:
  | rank | 节点 | ALGO | MIN_CH | MAX_CH | BUFFSIZE | NET_PLUGIN | NCCL_PROTO |
  |------|------|------|--------|--------|----------|------------|------------|
  | 0 | 01 | RING | 4 | 16 | 8388608 | none | (无) |
  | 1 | 02 | RING | 4 | 16 | 8388608 | none | (无) |
  | 2 | 04 | RING | 4 | 16 | 8388608 | none | (无) |
  | 3 | 03 | RING | 4 | 16 | 8388608 | none | (无) |
- **部署指南要求**: 无 NCCL_PROTO / NET_PLUGIN=none / ALGO=Ring / MIN_CH4 / MAX_CH16 / BUFFSIZE 8M
- **结论**: 全部一致✅
- **注意**: start_tp4_worker_deepgemm.sh 与 start_tp4_worker_b12x.sh 为变体脚本 (MIN=2), 非当前生产运行脚本; 当前生产用 start_tp4_worker.sh (MIN=4)。
- **文档位置**: 部署指南 L502-514; 本清单

## 7. 生产终态锚点
- 生产库 /opt/nccl-ringonly/libnccl.so.2.30.7 md5 **2be94172** (未变)
- 备份锚点: .bak-stageB-prod / .bak-stageB (b7784b49), .bak-hardened (3d9cf539), .bak-v2 (4cc43e3b) — 全部在位
- 生产容器: 四机 vllm-tp4-rank0-3 healthy (Up 12h+)
- 8001 endpoint: deepseek-v4-flash-0731 正常响应
