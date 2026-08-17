# NCCL 2-hop Allreduce · S2 验证数据判读口径（伪影/信号区分 + 修正决策线）

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**性质:** 判读口径（只读设计，不执行测试、不碰生产；S2 数据由 Rex 回传后按此口径判读）
**上游:** `nccl-2hop-s2-verification-plan-architect-2026-08-16.md`（S2 方案与决策线）/ Rex S2 中期同步（V2b+V3 优先、卡死三层已修、nobar 对照数据）
**状态:** Accepted（作为 S2 数据到后的统一判读口径）

---

## 0. TL;DR（结论先行）

1. **S2 中期数据已证明绝对延迟不可信、相对/结构信号可用**：ring_real 自身非单调（64K=384µs > 1M=167µs）；1-4KB 档 2hop 显示比 ring 慢（伪影）；但 **nobar 对照符合设计模型**——64K `ratio_h_nb=0.80`（2hop 快 20%）、256K=1.34（混合）、1M=4.51（带宽饱和，印证 ≤512KB 路由设计）。
2. **判读总原则 = 可靠信号优先**：以"同代码路径的结构相对量"为主判据，以"绝对 µs / 跨路径 ratio_h"为辅判据（甚至只作趋势）。
   - **主判据（可信）**：`ratio_m_nb = 2hop_nobar / ring_manual_nobar`（同 torch P2P 路径，4 步 vs 6 步，overhead 大致抵消）；同尺寸内算法相对次序；同 bench 内 per-step 比例（δ_bi、δ_fwd）；≥512K/1M 的带宽饱和单调趋势；V2b δ_hw（同时刻相对量）；V3 capture 正确性（0/1 信号）。
   - **辅判据/仅趋势（不可信绝对值）**：1-16KB 绝对延迟、细粒度 `ratio_h`、`ratio_h_nb` 在中尺寸的绝对值、跨尺寸比较 ring_real 绝对 µs。
3. **修正决策线（一句话版）**：
   - **GO 有条件（进 S3 前置）**：V2b δ_hw 非最差档（<1.7 或 1.3-1.7 有处理路径）+ V3 硬关卡全绿 + **结构信号绿**（`ratio_m_nb ≤ 0.80` @1-16K ≥2/4，或 `2hop_nobar < ring_manual_nobar` 全程）+ 1M 带宽饱和确认 + 正确性全绿 → **进 S3，但 S3 第一阶段强制为"真实 kernel 原型小步验证"（A/B 于 1-2 尺寸 + capture 专项），原型达标才 full implementation**。
   - **GO 降级（S3 仅小消息 ≤64K）**：结构信号部分（ratio_m_nb 0.80-0.88）或 368K 已饱和（阈值收紧 ≤256K）。
   - **NO-GO（收紧为结构性触发）**：结构信号失败（ratio_m_nb >0.88 @≥3/4 且 2hop_nobar ≥ ring_manual_nobar）或 V3 硬关卡失败或正确性失败或 V2b 数据错误 / δ_hw≥1.7 且结构收益也弱。
   - **明确不因"模拟绝对噪声"触发 NO-GO**（N1/N4 原数值判据废用，改为结构/趋势判据）。
4. **S3 前置清单（真实 kernel 原型前必须验证）**：① batch_isend_irecv 语义 ≠ 真实 NCCL kernel 的确认与并发无死锁原型；② 双边 per-peer dev 仲裁（v4 兼容）；③ 真实 kernel capture 专项；④ 1.5S 理想分块修正；⑤ 生产数值再锚定（真实 kernel 的 ratio ≤0.80）；⑥ v1 兼容 + tuner 条目 + 回滚演练。
5. **判读 SOP**：数据到后按 §6 顺序执行（门禁 → 提取 → 伪影过滤 → 逐项判读 → 综合决策 → 回传）。

---

## 1. 数据完整性门禁（判读前强制检查）

> 任何判读开始前先过此门禁。不满足 → 该数据块不可用，报告中标注，按 block_timeouts 处置，不参与决策。

| # | 检查项 | 来源 | 通过条件 | 失败处置 |
|---|---|---|---|---|
| DQ1 | 环境快照 | JSON meta | `world=4`、`protocol∈{auto,LL,Simple}`、`lib_md5` 与预期 ring-only 库一致（记录值）、sizes/iters/warmup 与命令一致 | 不一致 → 该文件标记不可用 |
| DQ2 | 块级完成 | JSON `block_timeouts` / 日志 `BLOCK_TIMEOUT` | 无 timeout；有 timeout 的 size 数据为 NaN，不参与判读 | 标注"超时块"，其 size 从 V1/V4 判读剔除；若超时块 >2 个且含关键尺寸(64K/256K) → 建议重跑 |
| DQ3 | 正确性 | 每 size `ok.{ring_real,ring_manual,2hop,pair}` 全 True；V2b `ok` 全 True | 全 True | 任一 False → 路由区间内正确性失败（触发 N3），立即上报 team-lead |
| DQ4 | JSON 与日志一致性 | rank0 日志 `S ...` 行 vs JSON sizes | 数值一致（±0.1µs 内） | 不一致 → 以 JSON 为准并标注 |
| DQ5 | ring_real 单调性检查 | ring_real_us 跨尺寸 | 不强制单调；若严重非单调（如 64K>1M），标记"绝对延迟不可用" | 触发 §2 全部判读转入相对/结构口径（本口径默认已按此执行） |

---

## 2. 伪影 vs 信号区分框架

### 2.1 噪声/伪影源清单（S2 中期数据证实）

| # | 噪声源 | 影响范围 | 严重度 |
|---|---|---|---|
| A1 | **torch P2P 每-op 固定开销**（Python + torch wrapper + NCCL enqueue），2hop/ring_manual/pair 每步多 op，开销随 op 数累加 | 小尺寸绝对延迟；**跨路径对比 ratio_h**（2hop 多 op vs ring_real 单 all_reduce，不对称） | 高 |
| A2 | **align=True 每步 `dist.barrier()` + 双 `cuda.synchronize()`**（`twohop_algo.NcclTransport.step_begin/end`） | aligned 每步时间、aligned 总延迟（`2hop_us`）；小尺寸被 barrier 主导 | 高 |
| A3 | **GB10 CPU 噪声**（单 CPU 共享、DVFS、后台进程） | 所有绝对 µs；perf_counter 计时抖动 | 高 |
| A4 | **ring_real 自身非单调**（中期 64K=384µs > 1M=167µs） | 跨尺寸绝对比较；`ratio_h`/`ratio_h_nb` 分母失真 | 高 |
| A5 | **跨路径不对称**：ring_real（NCCL 优化 kernel）vs torch-P2P 手写模拟（2hop/ring_manual/pair） | 一切与 ring_real 直接相除的 ratio 绝对值 | 中-高 |

### 2.2 可信信号清单（主判据）

| # | 指标 | 定义 | 为什么可信 | 判读用途 |
|---|---|---|---|---|
| S1 | **`ratio_m_nb`** | `2hop_nobar / ring_manual_nobar`（同 torch P2P 路径，唯一差异=4 步 vs 6 步） | 两算法走同一 `NcclTransport`/同一 op 封装，每-op 开销与 CPU 噪声在比值中大致抵消；无 barrier（align=False） | **结构步数收益主判据**（理想 ≈ 4/6≈0.667） |
| S2 | **同尺寸内算法相对次序** | 同 size 下 `2hop_nobar` vs `ring_manual_nobar` vs `pair` 的排序 | 同一测量环境，系统噪声对三者的扰动方向一致 | 收益有无的定性判据（2hop < ring 6 步 = 步数收益存在） |
| S3 | **同 bench 内 per-step 比例** | `δ_bi_rs = ps_rs1/ps_rs2`、`δ_bi_ag = ps_ag1/ps_ag2`、`δ_fwd = 2hop 单边步均 / ring_manual 步均` | 同一尺寸同一 bench，barrier+op 开销在分子分母中大致抵消 | V2a 端口争用检查、L'≈L 前提 |
| S4 | **带宽饱和单调趋势** | ≥512K/1M 的 `ratio_h_nb` 随尺寸上升且 ≫1 | 带宽主导区相对量仍反映 1.75S vs 1.5S 数据量惩罚 + op 开销 | **路由边界确认**（≤512KB 设计） |
| S5 | **V2b δ_hw** | `t_both / max(t_right,t_left)`，三档（≤1.3 / 1.3-1.7 / ≥1.7） | 同时刻相对测量，CPU 噪声同向抵消 | 双边硬件并发真伪（硬信号） |
| S6 | **V3 capture/replay 正确性** | Test A/B/C/D 的 cap/ok（0/1 布尔） | 正确性/可行性是 0/1 信号，不受噪声影响 | V3 硬关卡（最高风险项） |

### 2.3 不可信清单（只能作趋势或废弃）

| # | 指标 | 为什么不可信 | 修正用法 |
|---|---|---|---|
| X1 | 1-16KB **绝对延迟**（任意算法） | A1+A2+A3 主导 | 废弃绝对 µs；只用 S1/S2 结构量 |
| X2 | 小尺寸细粒度 `ratio_h`（`2hop_us/ring_real_us`） | A1+A5 不对称（2hop 多 op 被高估） | **废用为 GO 判据**；仅作趋势参考 |
| X3 | 中尺寸（256K/368K）`ratio_h_nb` 绝对值 | A4 使 ring_real 分母失真；带宽过渡区 op 开销占比仍大 | 只看趋势（≤512K 上升、1M ≫1）与相对次序 |
| X4 | `ratio_m`（aligned 2hop/ring_manual） | A2 barrier 主导 aligned 总延迟 | 废用；一律用 nobar 版本 |
| X5 | per-step 绝对 µs | A2+A3 | 只用比例（S3），不用绝对值 |

### 2.4 修正判读线（对照 S2 方案原判据）

| 原判据（S2 方案） | 修正判据（本口径） | 修正理由 |
|---|---|---|
| G1：小消息 `ratio_h ≤ 0.80` @1-16K ≥2/4 | **G1'：`ratio_m_nb ≤ 0.80` @1-16K ≥2/4（auto），且 S2 成立（`2hop_nobar < ring_manual_nobar` 各小消息档）**。若 ratio_m_nb 缺测，退化为 `2hop_nobar ≤ ring_manual_nobar` 定性成立 | ratio_h 是跨路径不对称伪影；ratio_m_nb 才是纯结构收益 |
| G2：`δ_fwd ≤ 1.15`（1-16K） | **G2'：δ_fwd ≤ 1.30（对 aligned 噪声容差）；若 δ_fwd 超但 ratio_m_nb 好，以 ratio_m_nb 为准** | δ_fwd 基于 aligned 每步，含 barrier+CPU 噪声 |
| G3：368K `ratio_h ≤ 0.95`、512K ≤1.0 | **G3'（趋势判读）：`368K ratio_h_nb ≤ 1.5` 且 `368K < 512K ≤ 1M`（单调上升仍成立）→ 路由设计成立**；若 368K 已饱和（≈512K 水平）→ 阈值收紧 ≤256K | ring_real 非单调 → 绝对 ratio 不可靠；看单调趋势 |
| （路由假设 ≤512KB） | **确认项 R：1M `ratio_h_nb ≫ 1`（>2 即强确认，中期 4.51 已确认）且 ≥512K 单调上升** | 带宽饱和验证，设计不路由 >512KB |
| V2a：δ_bi_rs~3 / δ_bi_ag~2（带宽区）、无超线性 | **保持，判据容差化：带宽区 δ_bi_rs ≤ 4、δ_bi_ag ≤ 3；≤16K 区 δ_bi ∈ [0.8, 1.5] 即视为"延迟主导无争用"** | per-step 比例相对可信；留出噪声余量 |
| V4：阈值=交叉点 `ratio_h≤0.95` 的最大尺寸 | **用趋势求区间：`路由阈值 ∈ [交叉点 ± 一档]`；若 256K 已饱和（ratio_h_nb≥512K 水平）→ 阈值 ≤64K** | 同 X3 |

---

## 3. 各验证项判读线（数据到后逐项对照）

### 3.1 V1 / V4 延迟对比判读线

```
判读顺序：
① 门禁（§1）通过
② 看 ratio_m_nb（S1）→ 结构步数收益
③ 看同尺寸次序（S2）：2hop_nobar vs ring_manual_nobar vs pair
④ 看 δ_fwd（S3）→ L'≈L 前提
⑤ 看 ≥512K/1M 趋势（S4）→ 路由边界
⑥ 产出：结构收益结论 + 路由阈值建议（区间）
```

**判定表（auto 协议主判读）：**

| 尺寸区 | 期望（设计） | 中期已见 | 判读规则 |
|---|---|---|---|
| 1-16K | ratio_m_nb ≤ 0.75（4/6 + 噪声容差） | 绝对 ratio_h 伪影（2hop 慢于 ring） | **不看 ratio_h**；只看 ratio_m_nb ≤ 0.80 且 2hop_nobar<ring_manual_nobar |
| 64K | ratio_h_nb ≤ 1.0（过渡） | 0.80（2hop 快 20%，强正信号） | ratio_h_nb 0.6-1.1 均为符合 |
| 256K | ratio_h_nb ≈1（混合） | 1.34 | 1.0-1.5 为"混合"，符合预期；>1.5 提示 torch 模拟 overhead 偏大（非设计失败） |
| 368K | ratio_h_nb ≤1.5 且 <512K | 待测 | 单调性 + ≤1.5（G3'） |
| 512K-1M | 单调上升、1M ≫1 | 1M=4.51 | **路由确认 R**（1M>2 即确认 ≤512KB 设计） |

> **重要**：256K ratio_h_nb=1.34 不被判为"中消息无收益/劣化"。理由：1.34 来自 torch P2P 2hop（1.75S 数据量 + 每-op 开销）vs NCCL 优化 ring_real，路径不对称（A5）。真实 kernel 按 1.5S + 原生 proxy 实现，带宽项只会更好。因此中尺寸只作趋势判读，绝对收益留给 S3 原型再锚定。

### 3.2 V2a per-step 判读线（V1 数据内派生，零额外成本）

| 指标 | 延迟主导区（≤16K） | 带宽主导区（≥64K） | 异常信号 |
|---|---|---|---|
| δ_bi_rs = rs1(双边)/rs2(单边) | 0.8-1.5（并发开销小） | 期望 ~3（3 chunk vs 1 chunk），**≤4 接受** | >4 → 端口争用/超线性，标记 |
| δ_bi_ag = ag1(双边)/ag2(单边) | 0.8-1.5 | 期望 ~2（2 chunk vs 1 chunk），**≤3 接受** | >3 → 端口争用，标记 |
| δ_fwd = 2hop 单边步均 / ring_manual 步均 | 0.85-1.30 | ≤1.30 | >1.30 且 ratio_m_nb 也差 → L'≈L 前提动摇 |

> 判读规则：δ_bi 超线性（>数据比）→ 记 V2a 告警，与 V2b δ_hw 交叉验证；**V2a 超线性 + V2b δ_hw≥1.7 同时出现** → 双边硬件假设崩塌（触发 N5 候选）。

### 3.3 V2b δ_hw 判读线（硬件双边并发真伪）

```
δ_hw = t_both / max(t_right, t_left)，sizes 64K/256K/368K，ITERS=200
```

| δ_hw 区间 | 含义 | 决策处置 |
|---|---|---|
| **≤1.3** | 两端口真并发（各口独立带宽），双边收益成立 | S3 完整 4 步 2-hop（RS/AG 双边步全量实现） |
| **1.3-1.7** | 部分争用（共享瓶颈部分串行），双边并发收益缩水 | S3 kernel 需显式 per-port 调度（双边步分 dev）；收益预期下调 |
| **≥1.7** | 共享瓶颈串行化，双边假设不成立 | 2-hop 收益只剩步数；真实 kernel 同样受限 → 触发重评（单边步为主变体） |

**附加判读（防误判）：**
1. **p50 优先**：avg 受尖峰污染，判读同时看 `t_both_p50` 与 `max(t_right_p50,t_left_p50)`；若 avg 档与 p50 档结论冲突 → 以 p50 为准并在报告中标注。
2. **方向对称性**：`t_right / t_left ∈ [0.67, 1.5]` 视为对称；超出 → 检查 PEER_HCA/dev 映射是否配置对称（单口故障/错映射嫌疑），该 size 数据标记待核。
3. **数据量 sanity**：`t_both` 不应显著小于 `max(t_right,t_left)`（<0.8 不合理，检查计时）。理想真并发下 t_both ≈ max(t_right,t_left)；串行化下 t_both ≈ t_right+t_left。
4. **尺寸相关**：若 64K δ_hw≤1.3 但 368K δ_hw≥1.7 → 小消息并发成立、大消息争用 → 路由阈值收紧（2-hop 只在并发成立区用）。
5. **ok 全 True**：任一 False → 数据错误（DQ3，触发 N3）。

### 3.4 V3 CUDA graph 判读线

| Test | 性质 | 判据 | 失败处置 |
|---|---|---|---|
| **Test B**（双 PG+双 stream 并发 all_reduce 的 graph，2-hop 双边代理） | **硬关卡** | B∈{8,16,32,64} 全部 `cap=T` + `ok=T`（capture 成功 + 重放正确）；B=1 仅信息项 | 任一 B≥8 失败 → **NO-GO（N2）**，上报 team-lead |
| **Test C**（64 档池，vLLM 全捕获规模） | **硬关卡** | `captured=64/64` + `okC=T`（重放正确）；尖峰为**告警项**：`rep_max/rep_avg ≤ 2.5`（或相对 eager ≤2×） | capture<64 或重放错误 → **NO-GO（N2）**；仅尖峰超 → 告警（记录进 S3 前置"生产尖峰观察"，不否决） |
| **Test A**（顺序控制组） | 控制 | 全 B ok；失败 → 环境/库问题（排除法） | Test A 失败但 B/C 通过 → 记录环境告警；A/B/C 全失败 → 环境问题，判读暂停 |
| **Test D**（2-hop 模拟 capture，信息项） | 信息项 | 记录 `captured/ok/rep_avg/rep_max/err` | **失败 ≠ 真实 kernel 失败**（torch P2P isend/irecv 的 capture 语义 ≠ 真实 NCCL proxy 机制），只标记"S3 capture 专项必做"；通过是强正信号 |

**判读原则：**
- 硬关卡只接受 0/1 正确性失败为失败；**尖峰是告警不是否决**（CPU/GPU 调度噪声可致单次 replay 尖峰）。
- Test B/C 是 torch 级代理但比 Test D 更接近生产（全用 `dist.all_reduce` = 真实 NCCL 调用）；Test D 是 2-hop 特有但语义不匹配 → 信息权重低。
- **V3 是全 S2 中风险最高的硬关卡**：若 V2b 有疑但 V3 全绿，仍可能 GO（降级）；若 V3 硬关卡失败，无论 V1/V2 多好都 NO-GO。

---

## 4. 综合决策（可靠信号优先）

### 4.1 决策状态定义

**GO 有条件（进 S3 前置，推荐路径）** —— 以下**结构信号**全绿，允许 V1 绝对延迟噪声大：
| # | 判据 | 阈值 | 判定项 |
|---|---|---|---|
| C1 | 结构步数收益 | `ratio_m_nb ≤ 0.80` @1-16K ≥2/4（auto）或退化 `2hop_nobar < ring_manual_nobar` 全程 | S1/S2 |
| C2 | 中尺寸无真回归 | 368K ratio_h_nb ≤ 1.5 且 368K<512K≤1M（单调） | S4 |
| C3 | 路由边界确认 | 1M ratio_h_nb > 2（中期 4.51 已满足） | S4 |
| C4 | 双边硬件可行 | V2b ok 全 True 且 δ_hw < 1.7（≤1.3 理想；1.3-1.7 触发 S3 per-port 调度分支，仍算有条件过） | S5 |
| C5 | V3 硬关卡 | Test B @B≥8 全绿 + Test C 64/64 | S6 |
| C6 | 正确性 | 全部 ok=True（路由区间内） | DQ3 |
| C7 | 数据完整性 | 门禁通过，超时块不覆盖关键尺寸 | DQ1/DQ2/DQ4 |

> C1-C7 全满足 → **"有条件通过（进 S3）"**。理由：S2 证明"步数收益结构 + 双边硬件可行性 + capture 硬关卡 + 路由边界"四个可行性问题全部为是；S2 无法证明的是"真实 kernel 的绝对生产数值"，这正是 S3 第一阶段的职责。

**GO 降级（进 S3，但范围收敛）：**
| 触发 | 处置 |
|---|---|
| C1 部分（ratio_m_nb 0.80-0.88 @≥2/4）且 C4-C7 满足 | 进 S3，范围砍为"kernel + ≤64KB 路由"，不做 368KB |
| C2 不满足（368K 已饱和，ratio_h_nb≥512K 水平）且 C1 满足 | 进 S3，阈值收紧 ≤256KB |
| C4 部分（δ_hw 1.3-1.7） | 进 S3，kernel 需显式 per-port 调度（S3 前置清单 ② 必做） |

**NO-GO（否决 S3）—— 收紧为结构性触发：**
| 触发 | 理由 | 相对原方案 |
|---|---|---|
| N1'：结构收益失败：`ratio_m_nb > 0.88` @≥3/4 且 `2hop_nobar ≥ ring_manual_nobar` 全程 | 4 步 vs 6 步的结构收益都不存在 → 8-12 人日 kernel 不值 | **原 N1（ratio_h>0.88）废用**（伪影），改结构判据 |
| N2：V3 硬关卡失败（Test B @B≥8 或 Test C <64/64 或重放错误） | 生产 64 档捕获是硬约束 | 保持 |
| N3：路由区间内任一 ok=False（含 V2b ok） | 数据正确性是底线 | 保持 |
| N4'：368K 真回归（ratio_h_nb 单调饱和到 368K 且结构收益也不足） | 主 prefill 档劣化不可接受 | **原 N4（368K ratio_h>1.0 绝对）放宽为趋势+结构组合** |
| N5'：δ_hw≥1.7（双边串行化）且结构收益弱（ratio_m_nb>0.80 @≥2/4） | 双边假设崩塌 + 收益不足 = 双重否决 | 保持精神，收益度量换 ratio_m_nb |

**明确不触发 NO-GO 的情形（重要）：**
- 1-16K 绝对 ratio_h 高（>0.88 甚至 >1）→ 伪影（A1/A5），只看 ratio_m_nb。
- 256K ratio_h_nb≈1.3-1.5 → 混合/过渡，符合设计，非失败。
- 单一尺寸单次测量偏差 → 需趋势/多数一致才可判定。

### 4.2 决策输出物

判读完成后向 team-lead 回传：
1. 各验证项通过/告警/失败表（对照 §3 判定表）。
2. 综合决策状态：GO 有条件 / GO 降级 / NO-GO（附触发条款）。
3. 路由阈值建议（区间，若 V4 数据够则给单点）。
4. S3 前置清单位 + 建议的 S3 第一阶段范围。

---

## 5. S3 前置清单（真实 kernel 原型前必须验证）

> S2 用 torch P2P 模拟，以下项是 S2 结论翻译到真实 kernel 前**必须先闭合**的验证，全部完成且通过后才允许 full implementation。

| # | 前置项 | 内容 | 验收标准 | 对应 S2 证据缺口 |
|---|---|---|---|---|
| P1 | **batch_isend_irecv 语义 ≠ 真实 NCCL kernel 的确认** | torch 批量 P2P 并发是用户态 batch enqueue；真实 kernel 用 proxy + channel 并发。需确认 NCCL 层"双边步"（同一 rank 同时向左右邻居 send/recv）的 proxy 并发实现不引入 ring 式死锁（enqueue 顺序、channel 分配、超时检测） | 单机 4 rank + 四机 4 rank kernel 原型跑 4 尺寸正确性 + 无 hang；对照 ring kernel 的 enqueue 顺序文档 | S2 只证明 torch batch 层不死锁 |
| P2 | **双边 per-peer dev 仲裁（v4 兼容）** | 左/右邻居映射的 HCA/dev；双边步同一时刻两个 send 的 dev 分配；若落到同一 HCA → port-pair 调度或时间分片。**依据 V2b δ_hw 结果选实现分支**（≤1.3 全量 / 1.3-1.7 per-port 调度 / ≥1.7 重排变体） | dev 分配表 + 冲突规避逻辑评审；A/B 实测双边步带宽 = 单口带宽 ×2（或符合 δ_hw 档） | S1 遗留风险 2（v4 单 dev vs 双边双 peer） |
| P3 | **真实 kernel capture 专项** | 真实 NCCL proxy 机制 + kernel launch 在 capture/重放下验证；用 S2 V3 Test B/C 同一结构对真实库重跑 | Test B @B≥8 全绿 + Test C 64/64；记录 proxy 在 capture 下的行为 | Test D 是 torch 代理，语义不匹配 |
| P4 | **1.5S 理想分块修正** | kernel 按 RS 每 rank 收发 S/2、AG 对称（总量 1.5S，非 S1/S2 模拟的 1.75S）；验证带宽项改善 | 大消息（256K/368K）kernel 实测 ratio 显著优于 S2 模拟（结构级比较） | S2 用 1.75S 模拟，带宽项保守 |
| P5 | **生产数值再锚定** | S2 只给了结构信号；真实 kernel 的绝对收益必须在原型阶段锚定 | 原型 A/B：1K/16K/256K × auto，`ratio_real ≤ 0.80` @1-16K（真实 kernel 无 torch 层每-op 开销，应更好）；达标后才 full implementation | S2 X1/X2 绝对伪影 |
| P6 | **v1 环邻过滤 + tuner 路由 + 回滚** | 2-hop 只走环邻（与 v1 对角过滤兼容）；PerSizeTuner 加 2-hop 条目默认关（观察后开）；回滚演练（tuner 关条目 / .bak 库，均瞬时） | 集成评审 + 回滚演练 SOP 通过 | — |

> **S3 第一阶段建议范围（对应 GO 有条件）**：P1+P2+P3 单机原型 + P5 在 1K/16K 两尺寸的 A/B 锚定；全绿后进入 full implementation（P4/P6 随实现完成）。S3 总规模 8-12 人日不变，但增加一个"原型门"防止在 torch 模拟结论上直接投入 full kernel。

---

## 6. 判读 SOP（Rex 数据到后执行步骤）

```
Step 0  门禁（§1）：DQ1-DQ5
Step 1  拉取 JSON：twohop_bench × 3 协议（auto/LL/Simple）+ bilateral_micro + cudagraph
Step 2  伪影过滤：标记 X1-X5 涉及指标，一律不看绝对值
Step 3  V1/V4：按 §3.1 判定表 → 结构收益（ratio_m_nb）+ 路由阈值建议
Step 4  V2a：按 §3.2 → δ_bi/δ_fwd 表
Step 5  V2b：按 §3.3 → δ_hw 三档 + 对称性 + p50 复核
Step 6  V3：按 §3.4 → Test B/C 硬关卡 + Test D 信息项
Step 7  综合决策（§4.1）→ 输出状态 + 触发条款
Step 8  若 GO（有条件/降级）→ 输出 S3 前置清单（§5）+ S3 第一阶段范围
Step 9  回传 team-lead + QA（Tessa 出判读报告，Archi 出 S3 决策建议汇总）
```

---

## 7. 风险与已知局限

| # | 局限 | 处置 |
|---|---|---|
| 1 | S2 中期只回传 3 个尺寸的 nobar 摘要；1-16K 的 ratio_m_nb 尚未回传 → 结构收益判据（C1）待全量数据 | 数据到后按 §3.1 执行；若 1-16K 结构信号缺测，退化为定性（S2：2hop_nobar<ring_manual_nobar） |
| 2 | ring_real 非单调 → 绝对延迟结论全部让位于结构量 | 已在 §2 固化 |
| 3 | V2b δ_hw 是三档判读；GB10 单口 55% 线速下"有限并发"概率高 | 按档位处置；1.3-1.7 档不否决，转 per-port 调度分支 |
| 4 | V3 Test C 尖峰受噪声影响 | 尖峰仅告警；0/1 正确性才是硬关卡 |
| 5 | 判读依赖 Rex 回传数据的完整性（JSON + 日志） | 门禁 DQ1-DQ5 强制；缺失 → 上报 team-lead 决策是否补跑 |

---

## 8. 数据来源
- S2 方案与原始决策线：`nccl-2hop-s2-verification-plan-architect-2026-08-16.md`
- S2 中期同步（Rex）：nobar 对照数据（64K ratio_h_nb=0.80 / 256K=1.34 / 1M=4.51）、ring_real 非单调（64K=384µs>1M=167µs）、卡死三层已修（lazy-init 2-rank 域→device_id+barrier / eager unbatched P2P 串行化死锁→batch_isend_irecv / 目录非共享假死锁→统一同步）
- 脚本源码（本地副本，已核对判据字段）：`nccl-2hop-s2-scripts/twohop_bench.py` / `twohop_algo.py` / `bilateral_micro.py` / `cudagraph_test.py`
- S1 报告：`nccl-2hop-s1-prep-report-sre-2026-08-16.md`

---

*文档生成：2026-08-16（S2 数据判读口径，S2 数据到后立即按此执行判读）*
