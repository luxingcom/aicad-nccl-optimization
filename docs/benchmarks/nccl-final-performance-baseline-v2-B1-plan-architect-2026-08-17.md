# 最终性能基线 v2.0（B1）预案

**日期**：2026-08-17
**作者**：Archi（系统架构师）
**状态**：✅ **已定版——本预案已由《nccl-final-performance-baseline-v2-B1-2026-08-17.md》（v2.0 正式定版）取代**（Tessa 32 档数据已回填，B1 v2.0 生效）
**上游**：`nccl-final-performance-baseline-2026-08-17.md`（FINALBASE v1.0，MAX_CH16 基线）/ `nccl-ab-B-execution-report-2026-08-17.md`（B1 窗口）/ ADR-015 S1.14（B1 固化决策）/ `b1-compat-adjudication-criteria-architect-2026-08-17.md`（兼容性判读口径）

---

## 0. TL;DR（预案摘要）

- **B1 已固化生产**（NCCL_MAX_NCHANNELS 16→4，2026-08-17 18:5x），集群 healthy。
- **v2.0 定版条件**：① Rex 环境确认通过（B1 兼容性判读口径全项）＋ ② Tessa 完整基准（32 档 × B1 vs MAX_CH16 同参对比）后回填本预案 → 正式定版。
- **结构**：FINALBASE v1.0 基础上**追加 B1 列**（32 档每档 B1 实测值 + Δ vs MAX_CH16），并新增「B1 收益摘要」。
- **不重写历史**：FINALBASE v1.0 保留为 MAX_CH16 基线文档（历史定版），v2.0 为独立演进版。

---

## 1. 生产环境基线（B1 终态）

| 项 | 值 |
|---|---|
| NCCL 库 | 2.30.7 ring-only hardened **2be94172**（未变） |
| `NCCL_MIN_NCHANNELS` | **4** |
| `NCCL_MAX_NCHANNELS` | **4（B1：16→4）** |
| `NCCL_BUFFSIZE` | 8388608（8M） |
| per-size tuner | ≤40KB→LL / >40KB→Simple（`NCCL_TUNER_THRESHOLD=40960`） |
| `NCCL_NET_PLUGIN` | none |
| `NCCL_PROTO` | 无覆盖 |
| 启动脚本 | 四机 `NCCL_MAX_NCHANNELS=4`（备份 `.bak-ncclB1`） |

## 2. B1 收益摘要（nccl-tests + 端到端，已实测）

| 维度 | MAX_CH16（B0/FINALBASE） | **B1（4ch）** | Δ | 判定 |
|---|---|---|---|---|
| 112KB allreduce | 126.3µs | **83.2µs** | **-34%** | ✅ 显著 |
| 224KB allreduce | 160.0µs | **86.1µs** | **-46%** | ✅ 显著 |
| 14KB（decode 主） | 41.3µs | 43.2µs | +2µs（噪声带） | 🟢 端到端不可见 |
| c1@131K | PR ~2200 / DE ~100 / TTFT ~52s | PR 2180.75 / **DE 104.07** / TTFT 52.4s | DE **+4%** | ✅ |
| c1@32K | PR ~2420 / DE ~99 / TTFT ~12s | PR 2387.91 / DE 96.83 / TTFT 11.93s | 持平 | ✅ |

**机制一句话**：368KB/16ch=23KB 分片 Simple 延迟不友好 → 4ch 分片更大（92KB）延迟更优；14KB LL 由 tuner 保证，不受通道数影响。

## 3. v2.0 定版结构（相对 FINALBASE v1.0 的增量）

### 3.1 新增「B1 vs MAX_CH16」对比列（32 档）

在 FINALBASE v1.0 的 32 档基线表（DE 12 + PR 20）基础上，每档增加两列：

- **B1 实测值**（Tessa 完整基准：与 v2 v1.0/FINALBASE 完全同参）
- **Δ% vs MAX_CH16**（wall-agg 主口径，±5% 判定沿用）

示例行（DE 档，最终以 Tessa 实测回填）：

| 档位 | MAX_CH16 WA（v1.0） | **B1 WA** | Δ% | 判定 |
|---|---|---|---|---|
| DE_C1_coding | 101.1 | **TBD** | TBD | TBD |
| DE_C1_json | 104.1 | **TBD** | TBD | TBD |
| …（12 DE + 20 PR 全列） | | | | |

### 3.2 新增「B1 收益摘要」章节

- nccl-tests 关键档（14KB/28KB/56KB/112KB/224KB/368KB）B1 vs B0（MAX_CH16）全表。
- 端到端锚定三档（32K/131K@C1、C4 32K agg）B1 vs FINALBASE v1.0。
- 收益归因（通道分片机制）与代价（14KB +2µs 噪声带）说明。
- B3/B4/B2 关闭项记录（防重复实验）。

### 3.3 定版判定协议

| 检查 | 判据 | 判定 |
|---|---|---|
| DQ 门禁 | 32/32 档 acceptance=1.0、rows 全 ok、0 reject | 同 FINALBASE v1.0 |
| 一致性 | B1 vs MAX_CH16 wall-agg Δ：≤40KB 档在 ±5% 噪声带；112KB/224KB 档显著改善（-20% 以上）；131K DE ≥ 基线 | 🟢 通过 |
| 锚定 | c1@131K DE ≥ 100；c1@32K PR/DE/TTFT 与 v1.0 持平 | 🟢 通过 |
| 兼容性 | Rex 判读口径 9 项全通过（b1-compat-adjudication-criteria） | 🟢 通过 |
| 回滚门禁 | 若 131K DE < 基线或一致性核验系统性超差（查因指向库/env）→ 回滚 MAX_CH16（.bak-ncclB1） | — |

### 3.4 产出物

- 正式 v2.0 基线文档：`nccl-final-performance-baseline-v2-B1-2026-08-1X.md`（定版后命名，由 Tessa 判读）
- 数据源：`/opt/aicad-prod/verification-logs/B1_<ts>/`（Tessa 执行）
- 本预案归档为定版输入

---

## 4. 待办与依赖

| # | 项 | 负责 | 状态 |
|---|---|---|---|
| 1 | Rex B1 环境确认（兼容性判读口径 9 项） | Rex | 待执行 |
| 2 | Tessa 完整基准 32 档（B1 生产基线同参） | Tessa | 待执行 |
| 3 | 回填本预案 → 定版 v2.0 | Archi/Tessa | 待数据 |
| 4 | Grafana 面板 16ch 注释同步 4ch | Rex | 待执行 |
| 5 | 02 镜像同步（docs + deliverables） | Rex（mirror_to_02.sh） | 待执行 |

---

*本预案由架构师编制，定版以 Tessa 完整基准 + Rex 环境确认为准。*
