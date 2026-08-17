# docs/ — 文档索引

> 本目录精选自工程保障团队 `deliverables/engineering-assurance/`（2026-08-15 ~ 2026-08-17）全部核心文档。
> 建议阅读顺序：**先根 README** → `adr/`（决策脉络）→ `reports/00-FINAL-REPORT`（结果总览）→ `benchmarks/`（基线数据）→ `ops/`（运维落地）。

## 目录结构

```
docs/
├── adr/          # 架构决策记录（ADR-014 / ADR-015 含 S1.1-S1.13 演进）
├── reports/      # 各阶段分析/验证/审计报告（35 份）
├── benchmarks/   # 性能基线文档（v1/v2 基线 + FINALBASE 终版）
└── ops/          # 运维文档（部署/runbook/自恢复/治理）
```

## adr/ — 决策记录

| 文件 | 决策 | 状态 |
|---|---|---|
| `ADR-014-per-size-protocol-internal-tuning-vs-plugin.md` | per-size 协议控制：内部 tuning.cc 双带 vs 外部 tuner 插件（S1 阻断后裁决：采用内部改码） | Accepted |
| `ADR-015-ringonly-netdev-hardcode-S1-S1.13.md` | ring-only P2 netDev 硬编码 per-peer 映射（S1.1-S1.14 全演进：源码漂移→官方重建→StageB→双分支加固→2-hop 归档→**B1 通道数 16→4 固化**） | Accepted |
| `b1-compat-adjudication-criteria-architect-2026-08-17.md` | **B1 兼容性判读口径**（tuner 路由 / 112KB / 368KB 外推接受区间 / 通道数 / 连接 / md5 / shim / health / 端到端，供实测验收） | 参考 |

## reports/ — 报告（35 份）

**核心总览**
- `00-FINAL-REPORT-nccl-optimization-2026-08-16.md` — **最终报告**（三阶段优化历程 + 生产部署 + 端到端验证）★先读

**Archi 架构分析**
- `nccl-tuner-implementation-architect-2026-08-16.md` — tuner 实施方案
- `nccl-latency-head-balance-architect-2026-08-16.md` — 延迟头部平衡分析
- `nccl-small-msg-trtllm-bypass-architect-2026-08-16.md` — 小消息 trtllm 绕过研究
- `nccl-allreduce-offload-research-architect-2026-08-16.md` — allreduce offload 研究
- `nccl-large-msg-nonmonotonic-architect-2026-08-16.md` — 大消息非单调性
- `nccl-tree-algo-feasibility-architect-2026-08-16.md` — Tree 算法可行性（P2-3 关闭）
- `nccl-tuner-stageA-recheck-architect-2026-08-16.md` — Stage A 复检

**SRE / QA 验证**
- `nccl-tuner-s1-report-sre-2026-08-16.md` / `nccl-tuner-s1-reverify-report-sre-2026-08-16.md` — S1 插件阻断与复验
- `nccl-t1am4-e2e-verification-2026-08-16.md` / `nccl-maxch16-e2e-verification-2026-08-16.md` / `nccl-maxch16-large-msg-2026-08-16.md` — 阶段验证
- `nccl-stageb-fulltest-qa-2026-08-16.md` — StageB 全量测试判读
- `nccl-followup-tests-qa-2026-08-16.md` — 遗留项复测（131K decode / 并发放大）
- `nccl-ab-results-2026-08-16.md` — A/B 结果
- `nccl-maxch16-ab-window-sop-2026-08-16.md` — MAX_CH16 A/B 窗口 SOP
- `nccl-p0-scan-results-2026-08-16.md` / `nccl-proto-threshold-scan-2026-08-16.md` — 扫描数据

**2-hop 项目（D 收尾归档）**
- `2hop-s3-final-adjudication-2026-08-17.md` — **终审裁定**（干净否定）★
- `2hop-archive-manifest-v1-2026-08-17.md` — 归档清单 v1.0
- `nccl-2hop-kernel-design-architect-2026-08-16.md` / `nccl-2hop-p0-diagnosis-result-architect-2026-08-16.md`
- `nccl-2hop-s1-prep-report-sre-2026-08-16.md`
- `nccl-2hop-s2-verification-plan-architect-2026-08-16.md` / `nccl-2hop-s2-readout-architect-2026-08-16.md` / `nccl-2hop-s2-readout-result-architect-2026-08-16.md` / `nccl-2hop-s2-adjudication-architect-2026-08-16.md` / `nccl-2hop-s2-report-qa-2026-08-16.md`
- `nccl-2hop-s3-phase1-gate-spec-architect-2026-08-16.md` / `nccl-2hop-s3-phase1-build-status-sre-2026-08-16.md` / `nccl-2hop-s3-phase1-window-execution-sre-2026-08-16.md` / `nccl-2hop-s3-phase1-qa-checklist-2026-08-16.md` / `nccl-2hop-s3-step12-adjudication-framework-architect-2026-08-17.md`

## benchmarks/ — 性能基线

| 文件 | 内容 |
|---|---|
| `00-FINAL-BASELINE-v3-2026-08-17.md` | **最终性能基线 v3 定版（FINALBASE v1.0，MAX_CH16）**（32 档完整数据 + FINALBASE 确认；⚠️ 已由 B1 v2.0 取代，见 B1 标注）★ |
| `nccl-final-performance-baseline-v2-B1-2026-08-17.md` | **最终性能基线 v2.0（B1）正式定版**（32 档 × B1 vs MAX_CH16，17 有利/15 持平/0 劣化；DE +5.5~23.1%）★ 当前基线 |
| `nccl-final-performance-baseline-v2-B1-plan-architect-2026-08-17.md` | v2.0（B1）预案（历史输入，已由正式定版取代） |
| `finalbase-run-record-sre-2026-08-17.md` | FINALBASE 补测运行记录 |
| `nccl-final-baseline-structure-review-architect-2026-08-17.md` | 基线结构审核 |
| `nccl-benchmark-v2-plan-qa-2026-08-16.md` | v2 基准方案（32 档协议） |
| `nccl-benchmark-v2-report-qa-2026-08-16.md` | v2 判读报告 |
| `nccl-benchmark-v2-finalization-prep-qa-2026-08-16.md` / `nccl-benchmark-v2-final-qa-2026-08-16.md` | v2 定版流程 |
| `nccl-benchv2-command-matrix-qa-2026-08-16.md` / `nccl-benchv2-final-commands-qa-2026-08-16.md` | 命令矩阵 |
| `nccl-benchv2-long-prefix-threshold-recommendation-sre-2026-08-16.md` | 长前缀阈值建议 |

## ops/ — 运维文档（19 份）

**自恢复 / 演练**
- `production-self-healing-plan-architect-2026-08-17.md` — 自恢复方案（systemd + healthcheck + 互杀守卫）
- `P1实施与自恢复演练记录-20260817.md` — P1 实施 + 三场演练记录（Rex）
- `P1实施与自恢复演练审核结论-20260817.md` — P1 审核定稿（Archi）
- `四机重启自恢复演练-QA报告-20260817.md` — QA 判读
- `self-recovery.md` / `fault-tolerance.md` / `maintenance-plans.md` / `ops-discipline-quickref.md` — 运维纪律手册

**治理 / 审计**
- `nccl-secret-audit-qa-2026-08-17.md` — 明文密码/密钥审计（结论：生产运行链无明文凭据）
- `nccl-script-comment-audit-qa-2026-08-17.md` — 脚本注释审计
- `nccl-sudoers-nopasswd-plan-qa-2026-08-17.md` — sudoers NOPASSWD 白名单方案（待批）
- `nccl-function-doc-mapping-qa-2026-08-17.md` — 函数→文档映射
- `file-registry.md` — 文件注册表（权威运维文档索引）

**日常运维**
- `server-maintenance-handbook.md` — 服务器运维手册
- `tools-index.md` — 工具/脚本索引
- `日志与临时文件自动维护方案-20260817.md` — 日志/临时文件维护
- `关键资料双机镜像清单-20260817.md` — 双机镜像清单
- `生产小问题处理记录-NCCL_IB_PEER_HCA清理-20260817.md` — PEER_HCA 清理记录
- `production-issues-fix-confirmation-2026-08-17.md` — 生产问题修复确认

> ⚠️ 脱敏说明：本目录文档中密码/API key 一律脱敏（`AS12<REDACTED>` / `c3b4<REDACTED>4594`）。
