# 2-hop 归档增量（2026-08-17 D 收尾的服务器原始执行层报告）

> 来源：dgxspark01 `/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/`。
> 本目录是 `docs/reports/` 已有 2hop 文档的**增量补齐**（内容级去重后保留 10 份此前未入库的执行层文件）。
> 结论与版本链定位见 [`../VERSION-LANDSCAPE.md`](../VERSION-LANDSCAPE.md)。

## 文件清单

| 文件 | 内容 |
|---|---|
| `nccl-tuner-netdev-hardcode-adr-architect-2026-08-16.md` | **ADR 原件**（根因链 S1.13：2HOP 未注册 device kernel table + nAlgos 溢出） |
| `nccl-2hop-p0-diagnosis-result-architect-2026-08-16.md` | P0 诊断结果（垃圾值 [783.875] 根因） |
| `nccl-2hop-kernel-design-architect-2026-08-16.md` | 2-hop kernel 设计文档 |
| `nccl-2hop-s2-report-qa-2026-08-16.md` | S2 QA 报告（reports/ 已有 s2-adjudication/readout，此为 QA 视角） |
| `nccl-2hop-s2-verification-plan-architect-2026-08-16.md` | S2 验证计划 |
| `s3-step1-tuner-result-rex-2026-08-17.md` | step1：hardened tuner 移植，RING 延迟 4.5ms → µs 级（lib `d12f3f3f`） |
| `s3-step2-diagnosis-result-rex-2026-08-17.md` | step2 根因闭环（`d3fc78a4` 2HOP+runRing ok=True） |
| `s3-step2a-formc-result-rex-2026-08-17.md` | form C pairwise kernel 结果（lib `cfa8c14c`，illegal memory access） |
| `s3-step2b-carry-result-rex-2026-08-17.md` | carry 变体结果（lib `9176e156`，同样崩溃 → 机制级否定） |
| `production-issues-fix-confirmation-2026-08-17.md` | 生产问题修复确认（bench_v2 60s timeout，`f72e9e84`） |

## 配套入库（不在本目录）

- 补丁脚本：`patches/apply_2hop_patch.py`、`patches/record_2a.sh`、`patches/record_2b.sh`
- 自包含 git-bundle + SHA 映射：`archive/2hop-proto/nccl-2hop-proto-20260817.bundle`（clone 复现）
- lib md5 血统总表：`archive/2hop-proto/2HOP-LIB-MD5-RECORD.txt`
- S3 门数据 / 失败日志：`archive/2hop-proto/s3-gate-data/`、`failure-logs/`
