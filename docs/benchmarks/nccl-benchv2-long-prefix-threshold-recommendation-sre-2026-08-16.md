# v2 基准长前缀并发档 · 独立阈值与引擎参数建议（Rex / SRE）

**日期**: 2026-08-16
**作者**: Rex（SRE 工程师）
**上游**: `nccl-benchmark-v2-report-qa-2026-08-16.md`（QA §6.4 建议 3/4/5）/ bench_v2.py 60s 读超时修复（本次）
**性质**: 建议文档，供 team-lead / QA 采纳；不改变 bench_v2.py 语义
**状态**: 补跑数据收集后定稿（131K@C6 执行中）

---

## 1. 背景

v2 基准 32 档中 4 档（131076@C2/C4/C6、32768@C6）因 bench_v2.py 客户端 60s 读超时 bug 失败。
修复（`min(timeout,60)` → 全量 request-timeout + ReadTimeout 归 timeout 类）后补跑，131K 并发档恢复。

本建议回答 QA §6.4：
- 建议 3「长前缀并发档设置独立超时阈值」→ 是否/如何设；
- 建议 4「引擎参数观察（max-num-seqs / long-prefill-token-threshold / 调度）」→ 是否需要调；
- 建议 5「131K 段拆出单独执行」→ 是否采纳。

---

## 2. 实测 TTFT 数据（补跑 BENCHV2_FIX_20260816T165051Z，全 72/72 ok）

| 档 | 并发 | ok | TTFT p50 (s) | TTFT p95 (s) | prefill p50 (tps) | wall-agg prefill (tps) |
|---|---|---|---|---|---|---|
| PR_C1_L131076（v2 原有效档） | 1 | 3/3 | 53.7 | — | 2147 | 2142.6 |
| PR_C2_L131076 | 2 | 6/6 | **100.6** | 101.6 | 1145 | 2263.9 |
| PR_C4_L131076 | 4 | 12/12 | **187.8** | 190.7 | 614 | 2419.2 |
| PR_C6_L131076 | 6 | 18/18 | **199.5** | 305.2 | 578 | 2270.0 |
| PR_C2_L32768 | 2 | 6/6 | 22.1 | 23.5 | 1300 | 2457.0 |
| PR_C4_L32768 | 4 | 12/12 | 42.4 | 43.4 | 678 | 2687.1 |
| PR_C6_L32768 | 6 | 18/18 | 43.6 | 64.8 | 660 | 2638.4 |

> 全部 72 条请求 status=ok，acceptance=1.0；无 timeout / http_err / conn_err / model_err / other。
> 131K@C6 monitor 标注 IMPOLLUTED（max running=5，采样错峰伪影）；acceptance 与行级数据不受影响。

**特征**：
1. 131K TTFT 随并发超线性：C1 53.7 → C2 100.6 → C4 187.8 → C6 199.5（p50）/ 305.2（p95）。
2. 131K per-request prefill 线性衰减：C1 2147 → C2 1145 → C4 614 → C6 578（≈0.27x）。
3. **131K wall-agg 随并发从 C1 2142 升至 C2-C6 2260-2420 后持平**——批处理收益存在但 per-slot 递减；prefill 在 C≥2 饱和。
4. 32K 同构但幅度小：TTFT C2 22.1 → C6 43.6；wall-agg C2-C6 2450-2690。
5. 补跑 4 档（原失败）+ 2 档（重跑）补齐 131K 并发曲线与 32K@C6 干净值（原 1910 为失败稀释）。

---

## 3. 建议一：request-timeout 阈值（runner 层）

**结论：长前缀并发档用独立、更高的 request-timeout，且把 131K 段从主矩阵拆出单独执行。**

| 项 | 建议 | 理由 |
|---|---|---|
| 全局默认 --request-timeout | 保持 1800s | 60s 读超时 bug 已修；wall-clock 截止真正生效 |
| 131K@C≥2 档专用 | **≥1200s（20min）**，推荐 1800s | 实测 C6 p50=199.5s / p95=305.2s / max=305.4s；留 ≥4x 余量 |
| 档级独立窗口 | 131K PR 档单独 invocation 跑 | 避免一个慢档拖垮整批（QA 建议 5 采纳）；`--out` 各自目录 |
| 波级超时（可选增强） | runner 增加每请求 TTFT>阈值打点（WARN + continue） | 便于观测/诊断，不设硬 kill（避免误杀真慢请求） |

> 说明：60s 读超时的根因是「per-read inactivity timeout」，现已放开为「request wall-clock timeout」，
> 两者语义不同——wall-clock 是对总时长兜底，不会在长 prefill 静默期误判。因此 131K 档的 60s 以下
> 误杀已消失；1800s 兜底足够。

---

## 4. 建议二：引擎参数（vLLM 层）

**结论：本轮数据**不构成** max-num-seqs 下调理由；无需立即调参。观察项列出供 full 阶段对照。**

| 参数 | 现值 | 判读 | 建议 |
|---|---|---|---|
| `--max-num-seqs` | 6 | C6 即上限；per-slot 效率 C6≈0.4-0.5x C1，符合批处理预期 | 维持 6；不建议为 PR 单独下调 |
| `--long-prefill-token-threshold` | 1024 | 131K 前缀已 chunk 化调度；TTFT 超线性增长主因 TP4 ring prefill 带宽饱和，非排队（monitor 显示 running 达 C） | 维持；如需改善长 prefill 并发可后续专项评估 |
| 调度策略 | 生产默认 | 131K@C≥2 的 per-request prefill TPS 衰减（0.29x）符合共享带宽模型 | 观察；full 阶段 e2e 验证时对照 |

> 重要衔接：131K 段**不在 2-hop 路由范围（≤64K）**。2-hop full 阶段能改善的是 16K-64K 的
> allreduce 延迟，从而影响 DE/prefill 中短前缀的 TTFT 与 decode 尾部；131K 长前缀曲线仍是 ring 基线，
> 不作为 2-hop 收益判据。

---

## 5. 建议三：基准口径（采纳 QA 建议 2 延续）

- wall-time 口径为主、wave-agg 为辅，写入 runner summary（消除跨版本歧义）。
- 补跑完成后将 32 档合并为 v2 基线 v1.0；回归门禁沿用 v1 阈值体系重标。

---

## 6. 数据来源与待办

- 数据源：`/opt/aicad-prod/verification-logs/BENCHV2_FIX_20260816T165051Z/`
- 待办：QA 复核后定稿；补跑数据已并入 v2 基线候选（32 档完整）。

---

*文档生成：2026-08-16（阈值建议 v0.9，补跑完成后定稿）*
