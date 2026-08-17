# NCCL 2-hop Allreduce · S2 判读分歧终审裁定（Archi / 架构）

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**上游:** `nccl-2hop-s2-readout-architect-2026-08-16.md`（判读口径）/ `nccl-2hop-s2-readout-result-architect-2026-08-16.md`（我首轮判读）/ `nccl-2hop-s2-report-qa-2026-08-16.md`（Tessa QA 报告）/ Rex S2 执行简报 / team-lead 分歧征询
**状态:** 终审裁定，待 team-lead + 人类批准
**性质:** 只读架构裁定，不执行测试、不碰生产

---

## 0. 裁定摘要（TL;DR）

1. **主判据（Q1）**：**S2 的 torch-P2P 时序比（aligned 与 nobar 均）对 2-hop 双边步不作为主判据——S2 时序结构信号不可判定**。决定性证据：**移除 barrier 不可能使总时变慢**（nobar 是 aligned 去掉 4 个 `dist.barrier()` 的同序列），但 2hop @1K aligned=471µs < nobar=868µs（1.84× 反转）；ring_manual 方向正常（aligned 718 > nobar 313）。该反转证明 **nobar 仪器对 2-hop 失效**；aligned 早已被 X4 判废（barrier 计数主导）。两个指标都不可用 → **S2 不能判定"4 步是否墙钟更快"**。
2. **测量异常（Q2）**：反转+重尾 = **torch 代理伪影**（单 PG op-matching + 双边步双口在 pipelined 下的跨步背压 stall），**不是"2-hop 机制物理缺陷"**——aligned（barrier 分离步）无此罚（δ_fwd auto≤64K=0.82-0.96），若有物理缺陷应同样出现在 aligned 逐步。**V2b δ_hw≥1.7 @256K+ 是独立的真实硬件约束**（支持 256K+ 带宽区结论），但**不支持推广到 ≤64K**（64K δ_hw 缺测）。
3. **Test B（Q3）**：**无论 B≥8 是否失败，S2 N2 硬否决不适用**——双 PG+双 stream 代理非生产模式（vLLM 每 op 单 all_reduce）；Test C 64/64 已证明生产"单 all_reduce graph"捕获模式正常。**P3（真实 kernel capture 专项）升格为 S3 非协商硬门**，P3 失败 = NO-GO。
4. **最终决策（Q4）**：**有条件进 S3 前置原型门（P0 定向诊断 + P1 正确性 + P3 capture + P5 收益锚定；P2 per-port 强制）**。P0 为第一阶段门，结果分叉：伪影确认 + 64K δ_hw≤1.3 → 前进；真实 ≤64K 争用 → **提前终止（有效 NO-GO）**。**不签 NO-GO（基于失效指标）、不签 GO（基于废用指标）**——两者都是"在无效工具上做终审"。
5. **口径修订（Q5）**：`ratio_m_nb` 在双边步/双口场景**作废**；S2 判据收窄为 4 类可靠信号（正确性 / V2b δ_hw 直接硬件 / V3 capture 0/1 / 带宽区无收益）；小消息延迟收益移交 S3 真实 kernel A/B（`ratio_real`）。

---

## 1. 分歧的本质：两种对"无效仪器"的误用

| 立场 | 依据 | 错误 |
|---|---|---|
| **Rex（有条件 GO）** | `ratio_m`（aligned）0.657-0.737 @1-64K "步数收益兑现" | 使用**口径 X4 已判废**的 aligned 指标；且仅 auto 协议成立（ll/simple 为 0.72-1.37） |
| **Tessa（NO-GO 信号）** | `ratio_m_nb`（nobar）1-16K 全 >1（auto 1.78-2.77），N1' 触发 | 逻辑正确（按字面口径确实触发），但**该指标被测量异常污染**，其"2hop 更慢"结论不可信 |

**架构裁定：双方都各执一个失效指标**。Tessa 的正确在于发现了 nobar 仪器失效（反转证明）——这是本轮最有价值的发现；Rex 的正确在于 aligned 不可用（X4）与 torch 代理不代表性。**正确结论不是任一方，而是"S2 的 torch 时序仪器对 2-hop 双边步整体失效"**。

---

## 2. Q1 裁定：主判据与"torch P2P 是否适用"

### 2.1 决定性证据（独立于任何机制假设）

```
干净测量下：nobar = aligned 去掉 4 个 dist.barrier() 的同 op 序列
→ nobar 总时 必须 ≤ aligned 总时（移除同步只会更快或持平）

实测 @1K auto：
  ring_manual : aligned=717.9µs > nobar=312.9µs   ✅ 正常
  2hop        : aligned=471.4µs < nobar=867.7µs   ❌ 反转（1.84× 更慢）
```

**反转在物理上不可能**（除非 nobar 引入了额外伪影）。这是**自足的证明**：`2hop_nobar` 作为测量量已失效，`ratio_m_nb = 2hop_nobar / ring_manual_nobar` 作为主判据**必然失效**。

### 2.2 两个指标为何都不可用

| 指标 | 失效机制 | 状态 |
|---|---|---|
| `ratio_m`（aligned） | 每步 `dist.barrier()` 主导 → 测的是 barrier 计数比 4/6，非步传输收益；跨协议不一致 | 废用（口径 X4，维持） |
| `ratio_m_nb`（nobar） | 单 PG 双口步在 pipelined 下触发跨步 op-matching/端口背压 stall → 反转+重尾 | **作废（本裁定新增）** |

### 2.3 结论

**torch-P2P 墙钟比（aligned/nobar 均）对 2-hop 双边步不适用，S2 时序结构信号不可判定。** 但 S2 仍有 4 类可靠信号：

| # | 可靠信号 | 判读 | 依据 |
|---|---|---|---|
| S-A | 正确性 | ✅ 全 true | 0/1 信号，不受时序伪影影响 |
| S-B | V2b δ_hw（直接硬件微基准） | 256K=1.81 / 368K=3.10（≥1.7）→ 256K+ 双口不并发 | 同时刻相对量，CPU 噪声鲁棒 |
| S-C | V3 capture（0/1，proxy 但 pattern 相关） | Test A/C 过（单 all_reduce graph OK）；Test B 双 PG 失败（非生产模式）；Test D 失败（信息项） | 布尔信号，与 2-hop 真实 kernel 的 capture 风险相关但不决定性 |
| S-D | 带宽区无收益 | 368K ratio_m>1 跨协议（auto 1.22/LL 1.37/Simple 1.41）+ δ_hw≥1.7 → **256K+ 放弃** | 跨协议一致 + 直接硬件印证 |

**小消息（≤64K）延迟收益：移交 S3 真实 kernel A/B（P5 硬门）裁决**——S2 既不能证实也不能证伪（仪器失效）。

---

## 3. Q2 裁定：测量异常定性（代理伪影 vs 真实争用）

### 3.1 分层结论（必须分开看）

| 现象 | 定性 | 证据 |
|---|---|---|
| **a) aligned<nobar 反转 + 重尾（torch bench）** | **torch 代理伪影**（单 PG op-matching + 双边步双口在无 barrier 下的跨步背压） | 反转物理不可能（§2.1）；aligned（barrier 分离步）无此罚（δ_fwd auto≤64K=0.82-0.96）→ 若为算法物理缺陷，aligned 逐步应同样受损 |
| **b) V2b δ_hw≥1.7 @256K+（直接硬件）** | **真实硬件争用**（256K+ 双口同时收发不并发，共享瓶颈串行化） | 直接微基准，非 torch 算法模拟 |
| **c) ≤64K 双口行为** | **未知（缺 V2b 64K δ_hw）** | V2a δ_bi 64K auto=1.15（aligned 逐步比，无争用）为间接提示，非直接证据 |

### 3.2 对 Tessa 立场的裁决

- ✅ **认同**：nobar 主判据被污染（反转证明）；双边端口争用是真实风险方向（V2b 印证）。
- ⚠️ **不认同**：将"2hop 双边步端口争用"推论为"**真实 kernel 同样吃这个损失**"——该推论只对 **256K+** 成立（V2b 直接证据），**≤64K 无直接证据**；且 torch 单 PG 串行化机制与真实 kernel 的 channel/slot 调度不同，代理机制不直接映射到 kernel。
- **结论**：b) 支持"256K+ 带宽区双边收益死"（已是既有裁定）；**不**支持"≤64K 机制物理缺陷"。≤64K 需 P0 补测 64K δ_hw + P3/P5 真实 kernel 裁决。

---

## 4. Q3 裁定：Test B 与 N2

### 4.1 裁定

**无论 B≥8 是否失败，S2 的 N2 硬否决均不适用。** 理由（机制级）：
1. **代理非生产模式**：Test B = 2 个 PG + 2 个 stream 各自 `dist.all_reduce` 近似双边并发；**vLLM 生产不用双 PG**（每 op 单 all_reduce）。torch 对"同图内双 PG/双 stream 并发"的 capture 限制是 torch 级问题。
2. **生产捕获模式已绿**：Test C 64/64（64 graph × 8 顺序 all_reduce）通过 → vLLM 生产 64 档全捕获的前提成立。
3. **真实 2-hop kernel 的捕获路径与 ring 同构**：单 ncclAllReduce 内部多 channel 并行（ring kernel 已多 channel 并行且 Test A/C 证明可捕获）→ 2-hop 的 capture 风险需用真实库验证，不能用 torch 双 PG 代理断言。

### 4.2 处置

- **Test B 失败 = 有效告警，不判 N2**。
- **P3（真实 kernel capture 专项，Test B/C 同结构对真实库）升格为 S3 非协商硬门**：P3 失败 = NO-GO（capture 是生产硬前提，不可绕过）。
- **注意**：若 Rex 补数据确认 B=8（最小并发档）即失败，P3 的优先级应再上调（排 P1 之后第一个）；但决策不变——仍由 P3 定。

---

## 5. Q4 裁定：最终决策

### 5.1 决策

**有条件进 S3 前置原型门（P0 定向诊断 + P1 正确性 + P3 capture + P5 收益锚定；P2 per-port 强制）**。

| 备选 | 裁定 | 理由 |
|---|---|---|
| **严格 NO-GO** | 不签 | 基于失效指标（ratio_m_nb 被反转证明污染）；Tessa 本人也建议先诊断防误杀 |
| **无条件 GO / GO 降级** | 不签 | 基于废用指标（aligned ratio_m，X4）+ 收益未证实 |
| **定向诊断后再终审** | **采纳为 P0，并入原型门** | 诊断有价值（区分伪影/真实争用、补 64K δ_hw），但"torch 修复后"仍不代表性 → 决定性裁决仍在真实 kernel |
| **有条件进 S3 前置（含 P0 + 强制 P2）** | **✅ 推荐** | 见 5.2 |

### 5.2 决策树（P0 分叉）

```
S3 Phase-0（P0 定向诊断，≤1 天）
├─ P0-1 补 V2b 64K δ_hw（<1h，决定性）
├─ P0-2 反转机制复现：单 PG 串行化 vs 双 PG(按方向分 PG) 并发对比
│       → 确认反转是否为 torch 单 PG op-matching 伪影
├─ P0-3 若伪影确认 & 64K δ_hw ≤1.3
│       → 进入 P1（正确性/无死锁）→ P3（capture 硬门）→ P5（收益锚定硬门）
│         全绿 → full implementation（P4 1.5S 分块 + P2 per-port + tuner + 回滚）
│
└─ 若 64K δ_hw ≥1.7（真实 ≤64K 争用）或固定代理仍无收益
        → 提前终止（有效 NO-GO，投入仅 P0 1 天）
```

### 5.3 原型门硬门（全绿才 full；任一失败终止）

| # | 硬门 | 判据 |
|---|---|---|
| G1 | 正确性/无死锁 | 原型 4 rank × 4 尺寸正确性 + 无 hang |
| G2 | **真实 kernel capture（P3）** | Test B/C 同结构对真实库：B@B≥8 全绿 + C 64/64；**失败即 NO-GO** |
| G3 | **小消息收益锚定（P5）** | A/B @16K（主）+1K（参考）：`ratio_real ≤ 0.80`；**失败即 NO-GO** |
| G4 | **per-port 行为（P2 强制）** | ≤64K 双边步并发无严重争用；若争用 → 改单边主导变体重评，或终止 |

**S3 第一阶段排序**：P0（诊断+64K δ_hw）→ P1（正确性）→ P3（capture，早死早止损）→ P5（收益锚定，价值主闸）→ P2 per-port（与 P5 并行/紧随）。P4/P6 只在 1-5 全绿后启动。

---

## 6. Q5 裁定：口径修订

### 6.1 判据替代表

| 场景 | 原判据 | 修订后 | 依据 |
|---|---|---|---|
| S2 小消息结构收益 | `ratio_m_nb ≤0.80`（作废） | **不作判定，移交 S3 `ratio_real`** | 反转证明 nobar 仪器失效；aligned 早废 |
| S2 双边硬件可行性 | V2b δ_hw 三档 | **维持**（唯一可靠时序信号）；64K 档补测 | 直接硬件微基准 |
| S2 带宽区 | 368K ratio_h_nb≤1.5 | **维持"放弃 256K+"**（依据跨协议 ratio_m>1 + δ_hw≥1.7，非 ratio_h_nb 绝对值） | 直接证据组合 |
| S2 V3 | Test B 硬关卡 | **降为告警；P3 升为 S3 非协商硬门** | 代理非生产模式 |
| S3 收益 | （未定义） | **`ratio_real`（真实 kernel A/B @16K 主）≤0.80** | 真实 kernel 无 torch 层伪影 |
| 通用 | torch P2P 墙钟比用于 2-hop | **口径级禁用作主判据**（aligned 与 nobar 均） | 本裁定 §2 |

### 6.2 口径级新增结论（写入 S2 判读终版）

> **"torch-P2P 时序模拟对 2-hop 双边步算法不适用"**——单 PG 串行化 + 每-op 固定开销 + 双口步 pipelined 背压三者叠加，aligned 与 nobar 两个变体分别在相反方向失真。**任何基于 torch P2P 墙钟的 2-hop 收益结论（GO 或 NO-GO）均不成立**；2-hop 的真实收益只能由真实 kernel A/B 裁定。这同时解释了 Tessa 的 NO-GO 信号与 Rex 的 GO 信号为何都不可信。

---

## 7. 待办与数据缺口

| # | 项 | 责任 | 状态 |
|---|---|---|---|
| 1 | **V2b 64K δ_hw**（P0-1 决定性输入） | Rex | 待补（决定 P0 分叉方向） |
| 2 | **Test B 失败档位**（B=1 vs B≥8） | Rex | 待补（影响 P3 优先级，不改变裁定） |
| 3 | **v2b.json / v3.json / bench-rank0 日志**落本地 | Rex | QA 独立复核 + DQ4/时序最终确认 |
| 4 | P0 诊断实施（1 天） | Rex/SRE（或并入 S3 原型） | 待 team-lead 批准路径 |
| 5 | 生产状态 | 已恢复 | 四机 healthy、md5 2be94172、无变更在途 |

---

## 8. 数据来源
- V1 三协议 JSON（本地）：`nccl-2hop-s2-data/v1_auto/ll/simple.json`
- 判读口径：`nccl-2hop-s2-readout-architect-2026-08-16.md`
- 首轮判读：`nccl-2hop-s2-readout-result-architect-2026-08-16.md`
- QA 报告：`nccl-2hop-s2-report-qa-2026-08-16.md`（Tessa，认可其测量异常发现）
- V2b/V3：team-lead 简报（256K=1.81/368K=3.10；Test A✅/B❌/C✅/D cap=F）

---

*文档生成：2026-08-16（判读分歧终审裁定，待批准）*
