# 功能-文档引用映射表（QA / Tessa）

**审计人**：泰莎（Tessa）· 测试专家 | 工程保障团队
**日期**：2026-08-17
**要求**：新增功能代码必须有文档引用；功能 → 实现文件 → 文档位置 可追溯

---

## 0. TL;DR

- 全部新增功能**均有对应文档**：NCCL 定制库（ADR-015 S1.5-S1.13 + 部署指南附录 + 最终基线）、bench_v2（判读报告+基线）、修复的 bench_prefill_decode_async（followup 报告）、2-hop proto（kernel-design + s2/s3 报告 + 归档清单）。
- **无"有功能无文档"的硬缺口**。
- 处置的缺口属**代码注释层面**：本次已为 bench_v2.py / bench_prefill_decode_async.py / 2hop 脚本 / v027 脚本补上文档引用（见注释审计报告）。
- **file-registry.md 陈旧（TP2 时代）**：已追加 §4 TP4 新功能索引（写操作完成，备份在位）。

---

## 1. 功能 → 实现文件 → 文档位置 映射表

| # | 功能 | 实现文件 | 文档位置 | 覆盖判定 |
|---|------|---------|---------|---------|
| 1 | v1 环邻过滤（P2P 仅连 ring prev/next） | 生产库 2be94172（官方 2.30.7 干净重建 + v1-ring-only.patch，src/transport.cc） | ADR-015 S1.7/S1.8；backup/nccl-official-2307-hardened-20260816/patches/v1-ring-only.patch；部署指南附录 | ✅ |
| 2 | v4 硬编码 per-peer 双 dev 映射（even/odd channel 轮换） | 生产库 2be94172（v4-netdev-hardcode.patch，src/transport/net.cc） | ADR-015 实现要点（映射表）+ S1.5-S1.7；部署指南附录"库：官方 2.30.7-1 + v1 + v4" | ✅ |
| 3 | Stage B per-size tuner（≤40KB→LL / >40KB→Simple） | 生产库 2be94172（stageB-tuner-two-band.patch，src/enqueue.cc） | ADR-015 S1.11；部署指南附录（GLIBC 修复重编 + 部署记录）；nccl-stageb-verification-2026-08-16.md；nccl-stageb-fulltest-qa-2026-08-16.md | ✅ |
| 4 | tuner 双分支加固（SPCX tuner 存在与否均生效） | 生产库 2be94172（stageB-hardened-two-branch.patch） | ADR-015 S1.12；部署指南"Stage B 加固更新"；nccl-final-performance-baseline §1.3（NCCL_NET_PLUGIN=none 说明） | ✅ |
| 5 | bench_v2.py（DE/PR/接受率/dspark/monitor 隔离） | /opt/aicad-prod/bench_v2.py | nccl-benchmark-v2-report-qa-2026-08-16.md（判读）；nccl-final-performance-baseline-2026-08-17.md（数据定版）；本次已补代码头引用 | ✅ |
| 6 | 修复版 bench_prefill_decode_async.py（asyncio 真并发 wave 语义） | /opt/aicad-prod/bench_prefill_decode_async.py | nccl-followup-tests-qa-2026-08-16.md（Stage B 遗留项复测）；test-nccl-ab-plan-2026-08-14.md；v027-perf-results-2026-08-15.md；本次已补代码头引用 | ✅ |
| 7 | 2-hop proto 库（Form A-minimal，RS(2)+AG(2)） | /opt/2hop-s1/proto-lib/ + 2hop-proto-host-plumbing.patch / 2hop-proto-kernel.patch；归档 backup/nccl-2hop-proto-archive-20260817/ | nccl-2hop-kernel-design-architect-2026-08-16.md；nccl-2hop-s2-report-qa-2026-08-16.md；nccl-2hop-s3-final-adjudication-architect-2026-08-17.md；nccl-2hop-archive-manifest-v1-architect-2026-08-17.md；ADR-015 S1.13（D 收尾） | ✅ |
| 8 | 2-hop 测试脚本/工具（26 个） | /opt/2hop-s1/（run_2hop_bench.sh、twohop_algo.py、s3/* 等） | 归档清单 nccl-2hop-archive-manifest-v1；本次已为全部脚本补代码头引用 | ✅ |
| 9 | v027 flashinfer patch 测试脚本（21 个） | /opt/aicad-prod/scripts/v027-test/ | test-v027-perf-ab-plan-2026-08-14.md；v027-perf-results-2026-08-15.md；归档 backup/v027-nvfp4-archive-20260815/；本次已补代码头引用 | ✅ |
| 10 | NCCL A/B 延迟测试 | /opt/aicad-prod/scripts/nccl-ab-B/run_lat.sh | nccl-ab-results-2026-08-16.md；本次已补代码头引用 | ✅ |

---

## 2. ADR-015 S1.5-S1.13 覆盖核对

| 章节 | 内容 | 覆盖功能 |
|---|---|---|
| S1.5 | R14v4/v5 复验（两层模型：核心层 vs 插件层） | 定位 v4 落点 |
| S1.6 | 双副本实锤（CollNet vs NET 区分） | 排除误判 |
| S1.7 | 最终决策：官方源码干净重建 | 功能 1/2 决策链 |
| S1.8 | Step 0 零补丁基线 + v1 diff 提取 | 功能 1 基线 |
| S1.11 | Stage B 上线 + 全量测试放行 | 功能 3 |
| S1.12 | 双分支加固上生产（2be94172） | 功能 4 |
| S1.13 | 2-hop kernel D 收尾（归档定稿） | 功能 7/8 |

**结论**：ADR-015 完整覆盖生产库 2be94172 的 v1/v4/tuner 双分支全部功能与 2-hop 收尾。

---

## 3. 部署指南覆盖核对

- **§5 补丁功能（8/13 版 P1-P5）**：覆盖早期 v1→v3 / PEER_HCA / shim v8 / capture-sizes / 编排修复——**为历史链**，未描述 8/16 官方干净重建链。
- **附录：NCCL per-size tuner（Stage B）部署记录（8/16 追加）**：覆盖 GLIBC 阻断与重编、3d9cf539 上线、**2be94172 双分支加固**、回滚链（.bak-hardened → .bak-stageB-prod → v3 b7784b49）——**为当前生产链**。
- **最终基线 §1.2/§1.3**：列出软件栈 2be94172 + 全量 env（无 NCCL_PROTO、NET_PLUGIN=none、TUNER_THRESHOLD=40960）。

**结论**：部署指南对当前生产链有覆盖（附录），但 §5.1 与附录并存易误导 → 已建议加交叉引用（P2）。

---

## 4. 缺口与处置汇总

| 缺口 | 类型 | 处置 | 状态 |
|---|---|---|---|
| bench_v2.py / bench_prefill_decode_async.py 头部未指向文档 | 代码注释 | 补 关联文档 行 | ✅ 已完成 |
| 2hop 26 个脚本 / v027 21 个脚本 / nccl-ab-B 无文档引用 | 代码注释 | 补 关联文档 行（归档清单/结果报告） | ✅ 已完成 |
| file-registry.md 停留在 TP2 时代，未收录 TP4 新功能 | 文档索引 | 追加 §4（TP4 新增文件/功能索引） | ✅ 已完成（备份在位） |
| 部署指南 §5.1 与附录并存 | 文档交叉引用 | 建议 §5.1 加"当前生产链见附录"一行 | 📋 建议（未改正文） |
| secrets/vllm.env 仅核验 01 | 权限核验 | 建议 02/03/04 同构文件一并核验 | 📋 建议 |

---

## 5. 数据来源

- /opt/aicad-prod/deliverables/engineering-assurance/（40+ 份，8/16-8/17）
- /opt/aicad-prod/docs/tp4-service-deployment-guide-2026-08-13.md（含 8/16 附录）
- /opt/aicad-prod/docs/file-registry.md（本次追加 §4）
- /opt/aicad-prod/docs/finalbase-run-record-sre-2026-08-17.md

---

*报告落盘：本地 deliverables/engineering-assurance/nccl-function-doc-mapping-qa-2026-08-17.md + 服务器 /opt/aicad-prod/docs/*
