# NCCL 2-hop Allreduce · S2 数据判读结果 + S3 决策建议（Archi）

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**上游:** `nccl-2hop-s2-readout-architect-2026-08-16.md`（判读口径）/ S2 窗口数据（out-s2：v1_auto/ll/simple.json + bench-rank0 日志）+ team-lead 汇总（V2b/V3 结果）
**状态:** 判读完成，S3 决策建议待 team-lead + 人类批准
**性质:** 只读设计判读，不执行测试、不碰生产（生产已恢复：四机 healthy、md5 2be94172）

---

## 0. TL;DR（结论先行）

1. **S2 判读结论 = 未达 GO，但非严格死刑**：**有条件进 S3 前置原型门（受限 de-risk spike）**，范围收敛 **≤64KB**，三硬门（正确性 / 真实 kernel capture / 小消息收益锚定）。
2. **结构收益证据不一致（关键新发现）**：S2 中期"nobar 符合模型"（64K ratio_h_nb=0.80）**未在最终窗口数据中复现**。我口径的主判据 `ratio_m_nb`（同路径 nobar）avg 版几乎全尺寸 >1（auto 1-64K = 1.78-2.77，2hop 更慢）；p50 版混合（auto 16K/64K=0.88/0.89 有利、1K/4K=1.22/1.49 不利；LL/Simple 多数 ≤64K 有利 0.87-0.94）。**结构步数收益"未证实"而非"兑现"。**
3. **带宽区（≥256K）确认放弃**：V2b δ_hw=1.81/3.10 @256K/368K（≥1.7 串行化）+ 368K ratio_m>1 跨协议（auto 1.22/LL 1.37/Simple 1.41）→ 双边带宽收益在本机不成立 → **路由上限 ≤64KB**（"GO 全量含 512KB"永久关闭）。
4. **Test B 硬关卡裁定：转为 S3 P3 真实 kernel capture 硬门（原型门），不直接 NO-GO**——理由：Test B 用"双 PG + 双 stream"（torch 级代理），非生产模式（vLLM 每 op 单 all_reduce；真实 2-hop kernel = 单 all_reduce 内部多 channel 并行，与 ring 同构，而 Test A/C 证明单 all_reduce graph 可捕获）。**但 P3 必须为硬门**：真实 kernel capture 失败即终止，不再投入。
5. **S3 第一阶段（原型门，2-4 人日）**：P1 正确性/无死锁 → P3 真实 kernel capture → P5 小消息收益锚定（A/B @1K/16K，`ratio_real ≤ 0.80` 才 full implementation）。全绿 → full implementation（P4 1.5S 分块 + P2 per-port + tuner/回滚）；任一失败 → 终止。

---

## 1. 数据完整性门禁（DQ1-5）

| # | 检查项 | 结果 | 说明 |
|---|---|---|---|
| DQ1 | 环境快照 | ✅ | world=4、lib_md5=2be94172（生产库）、NCCL_ALGO=RING、NET=IB、NET_PLUGIN=none、MAX_NCH=16、PEER_HCA 逐机配置 |
| DQ2 | 块级完成 | ✅ | 3 协议 block_timeouts 全空（[]），无超时块 |
| DQ3 | 正确性 | ✅ | 8 尺寸 × 4 算法 × 3 协议 ok 全 True |
| DQ4 | JSON vs 日志一致 | ⚠️ | 本机仅有 JSON，rank0 日志一致性由 QA（testing-expert）独立复算 |
| DQ5 | ring_real 单调性 | ❌ 绝对不可用 | auto 1K=284µs（异常高，p50=354 异常）> 4K=38µs；368K=128µs<256K=160µs；LL 1M=748µs>512K=469µs → **绝对延迟不可用，判读全部走相对/结构口径** |

**门禁结论**：数据可用于相对/结构判读；绝对 µs 一律弃用（与判读口径一致）。

---

## 2. V1/V4 判读（3 协议汇总）

### 2.1 关键指标表（ratio_m=aligned 2hop/ring_manual；ratio_m_nb=nobar；p50 版为 2hop_nobar_p50/ring_manual_nobar_p50）

| size | ratio_m (auto) | ratio_m (LL) | ratio_m (Simple) | ratio_m_nb avg (auto) | ratio_m_nb avg (LL) | ratio_m_nb avg (Simple) | ratio_m_nb p50 (auto) | p50 (LL) | p50 (Simple) |
|---|---|---|---|---|---|---|---|---|---|
| 1K | 0.657 | 1.142 | 0.941 | 2.773 | 1.917 | 1.355 | 1.49 | 0.94 | 0.88 |
| 4K | 0.716 | 1.373 | 0.833 | 2.584 | 1.877 | 1.871 | 1.22 | 1.23 | 0.90 |
| 16K | 0.685 | 0.722 | 0.939 | 1.783 | 1.614 | 1.670 | **0.88** | **0.89** | **0.87** |
| 64K | 0.737 | 1.180 | 0.952 | 1.873 | 1.088 | 1.541 | **0.89** | **0.88** | **0.87** |
| 256K | 0.964 | 1.236 | 1.056 | 2.180 | 0.889 | 1.598 | 1.75 | 0.90 | 1.18 |
| 368K | 1.223 | 1.366 | 1.407 | 1.779 | 2.130 | 1.477 | 1.09 | 1.12 | 1.13 |
| 512K | 1.422 | 0.904 | 1.071 | 1.983 | 0.884 | 0.976 | 1.15 | 0.98 | 0.89 |
| 1M | 0.996 | 1.006 | 0.979 | 1.000 | 0.920 | 1.203 | 0.91 | 0.90 | 0.91 |

### 2.2 判读

| 项 | 判读 | 依据 |
|---|---|---|
| ratio_h | **弃用（如预期）** | auto 4K=14.5、16K=12.6，纯 torch-P2P vs NCCL 路径不对称伪影（X2/X5） |
| ratio_m（aligned） | **不可作主判据** | 跨协议不一致（auto 1-64K≈0.66-0.74 看似 4/6，但 LL/Simple 不重现）→ aligned 被每步 barrier + 协议交互主导（X4） |
| **ratio_m_nb（主判据）** | **未证实（avg 反证 / p50 部分正）** | avg 版 auto/LL/Simple 1-64K 几乎全 >1（2hop 更慢）；p50 版 16K/64K 跨协议有利（0.87-0.89），但 1K/4K auto 不利（1.22-1.49）。**C1（ratio_m_nb≤0.80@≥2/4）未达标** |
| δ_fwd（L'≈L） | **≤64K 成立（auto）；LL/Simple 劣化** | auto 1K-64K=0.82-0.96；LL 1K=1.69/4K=1.86、Simple 1K-64K=1.09-1.39 → 协议噪声大，仅 auto≤64K 可信 |
| δ_bi（V2a） | **≤64K 无超线性** | auto δ_bi.rs 1-64K=1.15-1.45、δ_bi.ag=1.02-1.28（无争用）；256K δ_bi.rs=1.83（上升，与 V2b δ_hw 一致） |
| 路由边界 | **≥256K 放弃** | 368K ratio_m 跨协议 >1（1.22/1.37/1.41）、ratio_m_nb>1；结合 V2b δ_hw≥1.7 → 双边带宽收益不成立 |
| V4 阈值 | **阈值 ≤64KB（区间 16K-64K）** | 256K 起 ratio_m≥0.96/ratio_m_nb p50≥0.90（无收益）→ 路由上限 64KB，更保守取 ≤16K 需原型定 |

> **对 S2 中期数据的重要修正**：Rex 中期同步的 nobar 对照（64K ratio_h_nb=0.80 / 256K=1.34 / 1M=4.51）在最终窗口 JSON 中**未复现**（最终 auto ratio_h_nb：64K=7.02 / 256K=5.86 / 1M=3.42；ratio_m_nb：64K=1.87 / 1M=1.00）。差异来源：中期为 smoke/_min 早跑（条件不同/样本小），最终为全量 60 iter。**以最终窗口数据为准**：nobar avg 受罕见慢迭代污染（avg≫p50 严重），p50 才是中位数真相。结论不变——**结构收益未证实，需真实 kernel 定论**。

---

## 3. V2b δ_hw 判读（team-lead 汇总）

| size | δ_hw | 档位 | 判读 |
|---|---|---|---|
| 256K | 1.81 | ≥1.7（串行化） | 双边并发在 256K 失效；带宽区 2-hop 收益死 |
| 368K | 3.10 | ≥1.7（串行化） | 同上，更劣 |
| 64K | **缺测** | ? | **需补 V2b 64K 值**确认 ≤64K 是否安全（V2a δ_bi 64K=1.15 auto 提示无争用，但非直接证据） |

**裁定（team-lead 问题 2）**：
- δ_hw≥1.7 @256K+ 是**硬性硬件约束** → **路由范围收敛 ≤64KB**；同时 S3 原型加 per-port 行为验证（P2-lite）——但前提是 64K δ_hw 也安全。
- **不触发 NO-GO**：≤64K 是延迟主导区，双边步不需要带宽翻倍即可受益（只需不严重串行）；256K+ 的争用不影响 ≤64K 路由。
- **若 64K δ_hw 也 ≥1.7** → 连 ≤64K 的双边并发也存疑 → S3 原型需优先验证 per-port 行为，且收益预期下修（只剩步数收益 4/6）。

---

## 4. V3 CUDA graph 判读（team-lead 汇总）

| Test | 结果 | 判读 |
|---|---|---|
| Test A（顺序控制组） | ✅ 全过 | 环境/库基线正常 |
| **Test B（双 PG 双 stream 并发 capture）** | **cap=True 但 replay 全 B 失败**（eager 并发 OK，capture 特有失败） | **触发"硬关卡争议"（team-lead 问题 1）——裁定见下** |
| Test C（64 档池） | ✅ 64/64 | 生产 64 档全捕获（顺序路径）可行 |
| Test D（2-hop 模拟 capture） | captured=False | 信息项：torch isend/irecv 在 graph capture 下不支持（代理语义），按口径不否决 |

**Test B 裁定（问题 1）——转为 S3 P3 硬门，不直接 NO-GO**：
1. **代理不代表性成立**：Test B 用"2 个 PG + 2 个 stream 各自 all_reduce"近似双边并发；**vLLM 生产不用该模式**（每 op 单 all_reduce）。真实 2-hop kernel = **单 ncclAllReduce 内部多 channel 并行**，与 ring kernel 同构（ring 已多 channel 并行且 Test A/C 证明单 all_reduce graph 捕获/重放正常）。
2. **但该失败是有信息量的告警**：它在 torch 级暴露"并发通信 + graph capture"组合脆弱性；真实 kernel 是否安全必须用真实库复测。**因此 P3（真实 kernel capture 专项）设为 S3 原型硬门，通过才 full implementation；失败即终止。**
3. **这是对原判读口径（Test B 失败=N2 NO-GO）的受控偏离**，理由如上（代理 ≠ 生产路径），需 team-lead + 人类批准该偏离。

---

## 5. 综合决策（team-lead 问题 3）

### 5.1 结论：**有条件进 S3 前置原型门（受限 spike），非 GO 全量、非 GO 降级、非严格 NO-GO**

| 状态 | 是否 | 判据 |
|---|---|---|
| GO 全量（≤512KB 路由） | **否** | V2b δ_hw≥1.7 @256K+ + 368K ratio_m>1 → 带宽区双边收益死 |
| GO 降级（≤64KB，真实收益已证） | **否** | C1（ratio_m_nb≤0.80@≥2/4）未达标；V1 结构收益"未证实" |
| **S3 前置原型门（受限 spike）** | **是（推荐）** | 见 5.2 |
| 严格 NO-GO | 备选 | 若 team-lead 判定 torch 模拟证据足够强（avg ratio_m_nb>1 全尺寸）→ 也是合理保守选项 |

### 5.2 为什么"原型门"而非"严格 NO-GO"（关键论证）

**S2 遗留两个"只有真实 kernel 才能回答"的决定性问题**：
1. **小消息延迟收益真伪**：torch P2P 每-op 固定开销（~30-50µs）淹没了 1-16K 的真实延迟差，nobar avg/p50 分裂严重。真实 kernel（proxy + 少拷贝 + 1.5S 分块）没有这层开销，S2 既不能证实也不能证伪其收益。
2. **双边并发 capture 真伪**：Test B（双 PG）失败但代理非生产模式；真实 kernel 的 capture 行为未知。

这两个问题都可以用**最小 kernel 原型（2-4 人日）**低成本、决定性地回答。相比：
- **严格 NO-GO** 在代理伪影上否定特性，浪费 S2 已投入 + 抹掉 decode 侧小消息收益的潜在价值；
- **直接 full GO（8-12 人日）** 在"收益未证实 + capture 风险未清除 + 带宽区已死"三重不确定性上重注，风险过高。

**原型门 = 中间路径**：用小成本把"不确定性"转成"确定答案"，再决定是否 full implementation。

### 5.3 原型门触发条件（硬门）

| # | 硬门 | 判据 | 失败处置 |
|---|---|---|---|
| G1 | 正确性/无死锁 | 单机 + 四机 kernel 原型 4 rank × 4 尺寸正确性 + 无 hang | 终止 |
| G2 | **真实 kernel capture**（对应 P3） | Test B/C 同结构对真实库：Test B @B≥8 全绿 + Test C 64/64 | **终止（capture 是生产硬前提）** |
| G3 | **小消息收益锚定**（对应 P5） | A/B @1K/16K × auto：`ratio_real = 2hop_kernel / ring_kernel ≤ 0.80` @≥1 档（16K 主判；1K 作参考） | **终止（收益不达标则 8-12 人日不值）** |
| G4 | 双边 per-port 行为（P2-lite） | ≤64K 双边步并发无严重争用（对照 δ_hw 档） | 若争用 → 下修收益预期/改单边主导变体后再评 |

> 全绿 → full implementation（P4 1.5S 分块 + P2 per-port + tuner 条目 + 回滚演练，8-12 人日）；任一失败 → **终止，不回滚生产（生产已恢复 2be94172，无任何变更在途）**。

---

## 6. S3 第一阶段范围与排序（team-lead 问题 4）

**目标**：以最小成本过 5.3 的四个硬门。**范围 = 受限原型，非 full kernel**。

| 序 | 项 | 内容 | 验收 | 依赖 |
|---|---|---|---|---|
| 1 | **P1 正确性/无死锁** | kernel 原型（4 rank 单机 mock + 四机）：RS1/AG1 双边步（2 channel 同时 send/recv 不同 peer）无 ring 死锁；enqueue 顺序对照 ring kernel | 4 rank × 4 尺寸 ok + 无 hang | 无 |
| 2 | **P3 capture 硬门** | 用 S2 V3 Test B/C 同结构对真实库重跑（单 all_reduce graph 捕获/重放） | Test B @B≥8 全绿 + Test C 64/64 | P1 |
| 3 | **P5 收益锚定硬门** | A/B：2hop kernel vs ring kernel @1K/16K × auto（LL/Simple 备选），四机真实延迟 | `ratio_real ≤ 0.80` @16K（主）+ @1K（参考） | P1 |
| 4 | **P2-lite per-port** | ≤64K 双边步 per-peer dev 分配/冲突规避；补测 V2b 64K δ_hw | 无争用或可规避；否则收益下修 | P1 |
| 5 | （通过后才做）P4/P6 | full implementation：1.5S 分块修正 + tuner 2-hop 条目（默认关）+ 回滚演练 | 全量尺寸 A/B + 生产回滚 SOP | 1-4 全绿 |

**排序逻辑**：正确性（P1）→ capture（P3，最高生产风险，早死早止损）→ 收益锚定（P5，价值主闸）→ per-port（P2-lite，硬件细节）→ full。P4/P6 只在 1-4 全绿后启动。

---

## 7. 风险与待办

| # | 项 | 处置 |
|---|---|---|
| 1 | **V2b 64K δ_hw 缺测** | 请 Rex 补 v2b.json 64K 值（或 S3 P2-lite 补测）；若 64K 也 ≥1.7 → G4 收紧、收益预期下修 |
| 2 | DQ4（JSON vs 日志）未由我复算 | QA（testing-expert）判读报告独立复算 |
| 3 | 中期 nobar 数据与最终窗口不一致 | 以最终窗口 JSON 为准；判读报告注明 |
| 4 | Test B 偏离原口径（硬 NO-GO → P3 硬门） | 需 team-lead + 人类批准该偏离 |
| 5 | S3 原型人日（2-4 pd）需排期 | 建议紧跟 S2 数据确认后启动；与生产窗口错峰 |

---

## 8. 数据来源
- S2 数据（本地）：`deliverables/engineering-assurance/nccl-2hop-s2-data/v1_auto.json` / `v1_ll.json` / `v1_simple.json`
- S2 判读口径：`nccl-2hop-s2-readout-architect-2026-08-16.md`
- team-lead 汇总：V2b δ_hw（256K=1.81、368K=3.10）、V3（A✅/B❌/C✅/D cap=F）、生产恢复状态
- 基线：BenchV2 QA 报告（32K PR 2425 / 131K PR 2200 / DE 全档）——S3 P5 锚定对象

---

*文档生成：2026-08-16（S2 判读完成，S3 决策建议待批准）*
