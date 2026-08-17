# 2-hop 项目归档清单 v1.0（Archi / 架构审核）

**日期:** 2026-08-17
**作者:** Archi（系统架构师）
**审核对象:** `/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/`（服务器）+ 本地镜像 `nccl-2hop-archive-20260817/`
**性质:** 只读归档清单审核——依据 S1.13 收尾决策（D 归档），定义归档完整性判据并核对实际产物；不执行测试、不碰生产
**状态:** 清单 v1.0（**归档进行中，Rex 执行；本清单为待办对照 + 缺失项提示**）

---

## 0. TL;DR

归档覆盖目标 **8 类全部命中**（源码树 / git bundle / patch / lib md5 表 / 失败复现日志 / 全部报告 / 终审裁定 / ADR）为完成。当前（2026-08-17 11:3x）核对：**7 类源产物已就位，1 项待办（git bundle）**；正式归档目录尚未创建（Rex 执行中）。缺失/待补项见 §4。

---

## 1. 归档目录结构（目标布局）

```
nccl-2hop-proto-archive-20260817/
├── README.md                 # 归档说明（背景/结论/清单索引/回滚指引）
├── MANIFEST.md               # 本清单（或等价物）
├── MD5-RECORD.txt            # lib md5 总表（proto/prod/中间变体）
├── source/                   # 源码树（git worktree 副本，不含 build 产物）
├── git-bundle/               # 2hop-proto 分支 bundle（全历史）
├── patches/                  # 补丁 + 应用脚本
├── libs/                     # lib md5 表 + 关键变体备份（可选，体积大）
├── failures/                 # 失败复现日志（2hop-failures + /tmp 对照）
├── data/                     # 门数据（s3-g1-ring / s3-g3-ring-baseline / isolation）
├── reports/                  # 全部 2-hop 报告（S1-S3 + 设计 + P0）
└── adjudication/             # 终审裁定 + step12 框架 + 本 ADR 副本
```

---

## 2. 完整性判据（8 类逐项）

| # | 类别 | 必须覆盖 | 状态（源产物核对） | 判定 |
|---|---|---|---|---|
| 1 | **源码树** | 2hop-proto 完整源码（干净 2.30.7 + v1/v4 + 2HOP plumbing + kernel，含未提交 device table 修复） | `/opt/2hop-s1/src/nccl-2hop-proto`（HEAD 23a9798 + 未提交 diff 5 文件，含 generate.py "2HOP" / device.h nAlgos 7 / tuning.cc / enqueue.cc / all_reduce.h） | ✅ 就位 |
| 2 | **git bundle** | `git bundle create` 2hop-proto 分支全历史（6eac659..23a9798 + 未提交需 commit 后重建） | 服务器无 bundle 文件；分支 ref 23a9798 存在 | ⚠️ **待办（Rex）**：先 commit 未提交改动（或另存 diff）再 bundle |
| 3 | **patch** | host-plumbing.patch + kernel.patch + apply 脚本 | `/opt/2hop-s1/2hop-proto-host-plumbing.patch`（64 行）/ `2hop-proto-kernel.patch`（115 行）/ `src/apply_2hop_patch.py`；本地 `nccl-2hop-s3-data/` 已有副本 | ✅ 就位 |
| 4 | **lib md5 表** | 全变体 md5：before-tuner 2f21f6b9 / step1-tuner d12f3f3f / step2-carry c47b4637 / form C cfa8c14c / carry 9176e156 / 根因闭环 d3fc78a4 / 生产 2be94172 | 服务器 proto-lib 现存 2f21f6b9、d12f3f3f、c47b4637、9176e156、2be94172；**cfa8c14c / d3fc78a4 二进制已不在磁盘**（仅报告/record 脚本中记录 md5） | ⚠️ 表需补全（二进制缺失变体以 md5 记录 + 报告引用代替） |
| 5 | **失败复现日志** | 2hop-failures（mini2hopOK/T/F/S 等）+ /tmp fd_* 对照 + mini3dir | `/opt/2hop-s1/out-s3/2hop-failures/`（含 mini2hopOK_r0-3 / mini3dir / mini3hop 等）+ `/tmp/fd_*`（fd_NEWLIB/OLDLIB 对照）+ `/tmp/mini2hop*` | ✅ 就位 |
| 6 | **全部报告** | kernel-design / s1-prep / s2 系列（verification-plan / readout / readout-result / adjudication / report-qa）/ s3 系列（gate-spec / build-status / window-execution / qa-checklist / step12 / final-adjudication）/ p0-diagnosis | 本地 deliverables/engineering-assurance/ 14 份 2hop 报告齐；服务器 5 份旧副本 + 本清单后补同步 | ✅ 就位（服务器同步待 Rex 归档时一并补齐） |
| 7 | **终审裁定** | `nccl-2hop-s3-final-adjudication-architect-2026-08-17.md` + `nccl-2hop-s3-step12-adjudication-framework-architect-2026-08-17.md` | 本地已就位；服务器 deliverables 尚无 2026-08-17 文件（未同步） | ⚠️ 归档时需将 2 份 08-17 文档一并落盘 |
| 8 | **ADR** | `nccl-tuner-netdev-hardcode-adr-architect-2026-08-16.md` **含 S1.13** | 本地 + 服务器均已更新（S1.13 已追加，服务器 227 行） | ✅ 双份就位 |

---

## 3. 门数据/隔离记录核对（归档数据完整性的基础）

| 数据 | 服务器路径 | 判定 |
|---|---|---|
| G1 ring 正确性 | `/opt/2hop-s1/out-s3/s3-g1-ring.json`（md5 1833B） | ✅ |
| G3 ring 基线 | `/opt/2hop-s1/out-s3/s3-g3-ring-baseline.json`（15292B） | ✅ |
| 生产隔离 pre/post | `/opt/2hop-s1/out-s3/s3-isolation-pre.json` / `s3-isolation-post.json` | ✅ |
| Step1/2 结果 | `s3-step1-tuner-result` / `s3-step2-diagnosis-result` / `s3-step2a-formc-result` / `s3-step2b-carry-result`（4 份 rex md） | ✅ |
| 本地镜像 | 本地 `nccl-2hop-s3-data/`（patch ×2 + BUILD_ARTIFACTS + s3-g1/g3 + isolation + COPY/SCP marker） | ✅ 部分（见 §4.4） |

---

## 4. 缺失项提示（归档时核对关闭）

### 4.1 高优先级（影响可复现性）
1. **git bundle 未生成**：需先将 worktree 未提交改动（device table 修复 = 根因闭环关键）commit 到 2hop-proto 分支，再 `git bundle create` 全历史；否则 bundle 缺失根因修复，未来复现会回到"垃圾值状态"。
2. **根因闭环 lib（d3fc78a4）二进制已不在磁盘**：归档 lib 表须显式标注"该 md5 仅存于报告引用 + record_2a.sh 脚本"，并附上 lib 构建路径（从当前 worktree 未提交 diff 可重建，需 5-10 分钟 clean build）；**不得在归档中声称 d3fc78a4 二进制已保留**。
3. **form C lib（cfa8c14c）同理**：二进制缺失，md5 记录于 `s3-step2a-formc-result`。

### 4.2 中优先级（完整性）
4. **服务器 deliverables 未同步 08-17 文档**：`nccl-2hop-s3-final-adjudication` / `nccl-2hop-s3-step12-adjudication-framework` / `nccl-2hop-s3-data/`（本地 10 项）需在归档时一并 scp。
5. **bench_v2 60s 修复（f72e9e84）归档位置**：`/opt/aicad-prod/bench_v2.py` + `.bak-60s-fix-20260816` 属生产问题记录（S1.13 §附带），应随归档附 md5 说明（或单列 production-notes），不并入 2hop source。
6. **`/opt/2hop-s1/old-lib/`（2f21f6b9）与 `prod-lib/`（2be94172）**：确认在 lib 表中明确区分"旧 proto（无 tuner）"与"生产 hardened"两个角色，避免归档后混淆。

### 4.3 低优先级（可选增强）
7. 归档 README 应含**复现指引**：如何从 bundle 重建 d3fc78a4 / cfa8c14c / 9176e156（build cmd：`make src.build NVCC_GENCODE='-gencode=arch=compute_120,code=sm_120'`，anemll 0.2.1 容器）。
8. 建议附 `record_2a.sh` / `record_2b.sh`（结果生成脚本）到 failures/，保证 md 与数据可追溯。

### 4.4 本地镜像核对说明
- 本地 `nccl-2hop-s3-data/` 已有：2 份 patch + BUILD_ARTIFACTS.txt + 4 份门数据 + COPY/SCP marker。
- 本地缺失：**失败复现日志副本**（仅服务器 out-s3/2hop-failures + /tmp，本地未镜像）、**git bundle**（待生成）、**中间 lib 备份**（体积大，建议仅 md5 表 + 报告引用）。
- 建议：本地镜像以"清单 + 报告 + patch + md5 表 + 门数据"为核心，大体积（lib 二进制/build 产物）仅存 md5 与路径引用，保持镜像轻量。

---

## 5. 审核结论

1. **归档结构设计正确**：8 类覆盖与 D 收尾范围（ADR S1.13 §影响）一致；失败复现（2hop-failures）已纳入，符合"干净否定证据"的可追溯要求。
2. **主要风险 = 根因闭环不可复现**：d3fc78a4 二进制缺失 + git bundle 未生成，两者叠加会使未来重建回到"垃圾值状态"。**建议 Rex 优先 commit 未提交 diff 并生成 bundle，重建一次 d3fc78a4 验证可复现性**（预计 5-10 分钟，成本低）。
3. **服务器同步缺口**：08-17 三份文档（final-adjudication / step12-framework / s3-data）需随归档补齐。
4. **本清单 v1.0 为待办对照**：Rex 归档完成后，应按 §2 逐项回填判定（✅/⚠️），产出 v1.1 最终核验。

---

## 6. 数据来源
- 服务器实查：`/opt/2hop-s1/`（src/proto-lib/out-s3/out-s2/old-lib/prod-lib）、`/opt/aicad-prod/backup/`、`/opt/aicad-prod/deliverables/engineering-assurance/`、`/tmp/fd_*`、`/tmp/mini2hop*`、`/tmp/record_2*.sh`
- 本地：`deliverables/engineering-assurance/`（14 份 2hop 报告 + nccl-2hop-s3-data/ + benchv2-data/）
- ADR：`nccl-tuner-netdev-hardcode-adr-architect-2026-08-16.md` S1.13

---

*文档生成：2026-08-17（2-hop 项目 D 收尾——归档清单 v1.0，待 Rex 归档完成后回填核验）*
