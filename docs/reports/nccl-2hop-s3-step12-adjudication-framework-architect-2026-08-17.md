# NCCL 2-hop Allreduce · S3 Step1/Step2 裁审框架（Archi / 架构）

**日期:** 2026-08-17
**作者:** Archi（系统架构师）
**性质:** 只读裁审框架——预置判据与映射；含 2026-08-17 对照实验后的补充裁定（§7）；不执行测试、不碰生产
**状态:** 更新（根因已精确定位 = ncclTunerConstantsDefaults 缺 2HOP 常量 → A' 继续已批准，待 Rex 补常量重测）

---

## 0. 背景速记（来自已落盘数据）

- **S3 窗口执行已定**：RING 基线全绿（G1 4 尺寸 ok+sum_check、G3 p50≈4.5-4.7ms 平坦）；2HOP kernel 三版/四调度全失败（LL 错值 `[783.875, 3.015686, ...]` 完全一致、SIMPLE 死锁）→ 已裁定为"双 Primitives + direct 原语机制"问题，非调度问题。
- **两路并行攻坚**：
  - **Step1（tuner 移植）**：把生产 stageB tuner（2be94172 同源）移植到 proto lib → 判据 = proto RING 回 µs 级（当前 4.5ms 异常）。
  - **Step2（temp buffer/carry 根因诊断）**：用临时缓冲/进位缓冲解耦直接写覆盖 → 判据 = bilateral ok=True。
- **4.5ms 异常**：proto lib（无 tuner）RING p50 1K=4549µs / 16K=4570µs / 64K=4660µs 全平坦；生产同镜像 sglang S2 环境 ring_real@4K=38.6µs。~100× 异常，疑似无 tuner 的协议/通道选择差异或镜像差异。

---

## 1. Step1 判据（tuner 移植 → proto RING µs 级）

| 项 | 规格 |
|---|---|
| 被测 | proto lib（tuner 移植后新 md5）+ RING 路径 |
| 主判据 | `RING p50 @16K ≤ 300µs`（µs 级回恢；生产 ring_real@4K≈38.6µs，16K 留裕度） |
| 辅助判据 | p50 随尺寸单调（1K<4K<16K<64K），且不再平坦 4.5ms |
| 数据要求 | 同 G3 采样（warmup=15, N=200, p50/p95/p99）+ DQ（lib md5、NCCL_ALGO、block_timeouts） |

### 1.1 Step1 分叉

```
Step1 结果
├─ ✅ p50@16K ≤ 300µs（µs 级回恢）
│     → G3 测量前提成立；进入 G1-G3 完整裁审（Step2 解锁前提）
│
└─ ❌ 仍 ms 级（tuner 移植不解决）
      → 4.5ms 异常不是"缺 tuner"单一原因（协议选择/镜像差异/补丁副作用）
      → 分支：
         a) 若 Step2 已解锁且 G1/G2 可过：G3 在当前环境不可测 →
            先定位 4.5ms 根因（≤1 天，D-优先）再测 G3；定位失败 → 视为环境不可测，
            收益裁定移交 A/D 框架（A 需先解决测量有效性）
         b) 若 Step2 未解锁：直接进 A/D
```

> **架构提示**：Step1 与 Step2 相互独立——Step1 决定 **G3 能不能测**，Step2 决定 **kernel 对不对**。两者都过才是完整解锁；只过其一需降级/分叉。

---

## 2. Step2 判据（temp buffer/carry → bilateral ok）

### 2.1 结果映射表（核心裁审逻辑）

| # | Step2 结果 | 解读 | 后续 |
|---|---|---|---|
| 2-1 | temp/carry 下 **LL+SIMPLE 全 ok** | 根因 = in-place buffer 别名/直接写覆盖 → **机制解锁** | 进 G1-G3；G3 需按实际数据量调整期望（见 §3.2） |
| 2-2 | temp/carry 下 **LL ok、SIMPLE 仍死锁** | 根因 = direct 并发在 SIMPLE 下固有限制（协议相关） | 部分解锁：G3 目标区是小消息（LL 为主，vLLM 生产可选 LL），可先 LL-only 评估 G3；SIMPLE 不可用需记录为 full 阶段限制 |
| 2-3 | temp/carry 下 **LL 仍同值错** | 根因 **不是 buffer 别名**，更深层（双 Primitive 并发原语框架） | **结构性确认 → A/D 决策点** |
| 2-4 | temp/carry 下 **正确但并发被串行化**（fwd/bwd 不再同时） | 正确性保住了，但 per-edge 并发丢失 | **降级**：2-hop 步数收益仍在（4 步 vs 6 步），但双口并发收益丢失；G3 期望 ratio 上调约 +5-8%（按 volume 修正） |

### 2.2 判据所需数据（请 Rex 随结果附带）

1. **逐协议结果**：LL / SIMPLE / LL128（若已测）各自 ok / 错值 / 死锁 + block_timeouts。
2. **失败模式是否变化**：若仍失败，错值是否与修复前**完全相同** `[783.875, 3.015686, ...]`——相同 → 根因非别名（2-3）；不同 → 部分进展（2-2/2-4）。
3. **temp/carry 数据路径**：temp 是 **kernel 内 GPU memcpy 本地中转**（保住 4 步调度，开销低）还是 **额外网络传送**（加步 → 2-hop 优势被侵蚀）？→ 决定 G3 可行性。
4. **固定设计的数据量**：S/rank 实际值（proto 1.75S；temp/carry 后是否增加）→ G3 期望修正输入。
5. **并发保持性**：修复后 fwd/bwd 双 Primitive 是否仍并发。

---

## 3. 解锁后 G1→G2→G3 裁审（沿用 S3 门规格，含 P2）

### 3.1 门判据（规格已定，重述）

| 门 | 判据 | 失败处置 |
|---|---|---|
| **G1** | 2HOP 4 rank × {1K,16K,64K,256K} ok=True + sum_check + 无 hang | 终止 |
| **G2** | 2HOP 下 Test A（B=1/8/16/32/64）+ Test C（64/64）+ 重放正确 | **NO-GO** |
| **G3** | `ratio_real(p50) @16K ≤ 0.80`（=2hop/ring 同库同环境） | **NO-GO**（>0.88）；0.80-0.88 → 降级 ≤16K 路由 |
| **P2** | δ_hw@16K ≤1.3（双边步无严重争用） | 争用 → 单边主导变体重评/终止 |

### 3.2 G3 期望修正（Step2 设计形态影响）

- 理想 1.5S、proto 1.75S、temp/carry 后体积 V：**ratio 期望 ∝ V/1.5 × 4/6 步比**。
  - V=1.5S：理论地板 ≈ 0.67（纯步数比）。
  - V=1.75S（proto 现状）：期望 ≈ 0.78。
  - V=2.0S（temp/carry 净增）：期望 ≈ 0.89 → **G3 大概率踩线/超线**，需在裁审中显式标注"设计体积修正"，与 2-4 同处理。
- **裁审原则**：若 ratio 超标但体积修正可解释（如 V≥1.9S），判定为"**设计体积问题而非 2-hop 机制无效**"→ 降级/建议 full 阶段 1.5S 优化（P4 折叠）后再评；不直接 NO-GO。

### 3.3 δ_hw@16K（P2）与 G3 同窗

- 判据沿用 P0：`δ_hw(p50) @16K ≤1.3`；≥1.7 → 真实争用 → 重评/终止。

---

## 4. 结构性确认 → A vs D 决策建议框架

> A/D 为**业务属性决策，需 team-lead + 人类拍板**；此处给技术依据 + 建议方向，供呈报。

### 4.1 选项参数（team-lead 已定版）

| 维度 | A（spike 新原语/sendrecv kernel） | D（INCONCLUSIVE 收尾） |
|---|---|---|
| 投入 | 5-10 人日 | ≈0 |
| 成功率 | 40-60% | 100%（收尾） |
| 期望 ratio | 0.67-0.77 | 维持 RING（ratio=1.0） |
| TPOT 收益 | 3-8% | 0 |
| 结果性质 | 真实 kernel 定论（G1-G3 重跑） | 结构性结论 + INCONCLUSIVE |

### 4.2 技术依据（结构性确认场景下）

1. **机制证据已充分**：三调度同垃圾值 + RING 单 Primitive 正确 + temp 不解决（2-3）→ 可定性为 **NCCL ring Primitives/direct 原语框架无法表达"同步内双口发 X 收 Y + in-place 归约"**。此为结构性，非调度可绕。
2. **A 的本质**：脱离 Form A-minimal，新增 `sendrecv` 类设备原语（发 X 收 Y 分离、direct 语义修正）——触及 NCCL 设备层，正是 5-10 人日 + 40-60% 成功率的来源。
3. **前置有效性**：A 是否值得启动，**先决于 Step1**（G3 可测性）。若 4.5ms 异常未解，A 建好也测不了收益 → 应先解决测量有效性或直接 D。

### 4.3 建议方向（待用户拍板）

- **建议 A（若 Step1 ✅ 且用户愿押 3-8% TPOT）**：5-10 人日是可控 spike 预算，40-60% 成功率下期望收益为正（0.5×3-8% vs 5-10 天）；且 A 会产出真实 kernel 定论（无论成败），消除 INCONCLUSIVE 遗留。
- **建议 D（若 Step1 ❌ 或预算紧张）**：结构性确认已是有价值产出（防止未来重复踩坑）；RING 基线（2be94172）维持生产；预算转投 P2 交换机/0.27 升级。
- **折中（若用户犹豫）**：**A-lite**——仅修 `sendrecv` direct 语义 + LL-only 验证（≤4 人日），以最低成本确认"机制是否可通"；可通再决定 full A。

---

## 5. 裁审流程与文档

1. Rex 回传 Step1/Step2 数据（JSON + rank0 日志 + 生产隔离记录 + 新 lib md5）。
2. QA（testing-expert）独立复核（DQ + 复算）。
3. Archi 依据本框架填结论 → G1-G3 或 A/D 建议。
4. 落盘：`nccl-2hop-s3-step12-adjudication-result-architect-2026-08-17.md`（本框架的结论版）。
5. team-lead + 人类批准。

---

## 7. 补充裁定（2026-08-17 · 对照实验后——根因修正 + A' 方向）

### 7.1 对照实验（Rex，决定性证据）

```
同一份 kernel 代码（run2Hop = 无条件调用 runRing，纯 fallback）
NCCL_ALGO=RING  + runRing → ok=True  [6.0, 6.0, 6.0]  （正确，40µs）
NCCL_ALGO=2HOP  + run2Hop（=runRing 本体） → ok=False  [783.875, 3.015686, 783.875]（同垃圾值）
setup 顶层一致（Algo 不同但 count/ring 连接/协议相同）；垃圾值跨协议/通道数/新旧 lib 稳定
```

### 7.2 裁定（Archi）

1. **对照实验成立**：唯一变量 = algo 入口（RING vs 2HOP），kernel 逐字节相同 → 垃圾值必然来自 **2HOP algo 路径的 plumbing**（cost table / ncclTaskColl 参数 / proxy op / graph 支持），**与 kernel 逻辑无关**。此为高质诊断。
2. **修正此前根因结论**：此前"双 Primitives + direct 原语机制 = 结构性"的裁定**基于被污染观测**——三轮失败（原实现/direct/Archi B/C）全部经 2HOP 入口，被同一 plumbing 缺陷污染，**kernel 机制从未被干净测试**。carry/temp-buffer 假设（§2）确实无法解释此现象。**此前的 carry 假设与"kernel 结构性"结论一并收窄/撤销**。
3. **术语澄清**：这是**集成层结构性缺陷（可修复）**——2HOP 入口的任务构建/代理/cost 配置错误，是 defect 而非 impossibility。
4. **方向切换**：修复面从"发明新设备原语（旧 A，5-10 天）"**收窄为"对齐 algo 集成配置（A'，2-5 天）"**；成功路径 = 修 plumbing → 2HOP+runRing fallback 回 6.0 → 重验真实 run2Hop kernel → G1-G3。
5. **A' 决策门**：plumbing 修复后，若真实 run2Hop kernel 仍失败（此时为干净测试）→ 才算真·kernel 机制问题 → 届时在旧 A（新 sendrecv 原语）/ D 间再裁；A' 预算上限 ≤5 人日止损。
6. **与 Step1 的关系**：A' 解锁 G1/G2（正确性/capture）；G3（ratio）仍需 Step1（tuner）使 RING 回 µs 级——两线并行。

### 7.3 呈报用户建议（A'，需 team-lead + 人类批准）

- **建议**：批准 A'（2-5 人日 algo 集成排查修复 + kernel 重验），与 Step1（tuner）并行。
- **技术依据**：① 控制实验证明问题在集成路径非 kernel → 修复成本减半、成功率上升（plumbing 修复 70-80%；完整解锁 40-60%）；② 2-hop 收益假设未被证伪（ratio 0.67-0.77 / TPOT 3-8%），此前被 plumbing bug 挡住；③ A' 是最小充分路径——2-5 天换取"2-hop 是否有真实收益"的决定性答案，失败亦得干净 kernel 裁决，消除 INCONCLUSIVE 遗留。
- **对冲**：保留两条退出分支（plumbing 后真实 kernel 仍失败 → 旧 A 5-10 天 / D）；预算上限 ≤5 人日。
- **不建议直接 D**：D 会让"2-hop kernel 不可能"的已证伪根因被固化；A' 成本低于旧 A 且信息价值高。

### 7.4 A' 排查清单（转 Rex）

1. algo-ID 索引数组未扩到 a=7（nsteps / chunkSteps / threadThresholds / maxThreads / nChannels 默认值）。
2. ncclTaskColl 字段（sendMem / recvMem / redOp / protocol）在 2HOP 路径是否正确赋值。
3. proxy op 构建（ncclProxySaveColl / computeColl）是否覆盖 2HOP。
4. graph/pattern 支持（ncclPattern*）是否识别 2HOP。
5. 快速定位手段：2HOP 与 RING 各打一份 ncclTaskColl 全文 diff，差异即嫌疑。

### 7.5 根因确认 + A' 继续裁定（2026-08-17 二轮）

#### 根因（Rex NCCL_DEBUG=TUNING 直接证据）
```
ncclTunerConstantsDefaults（tuning.cc:148）未初始化 2HOP(index 7) 的 baseLatencies/hwLatencies
→ 2HOP 成本模型 latency 全 0（RING LL=36.6 / PAT LL=5.0 / 2HOP 三协议=0.0）
→ topoGetAlgoInfo 退化 → 任务参数（nChannels/nsteps）异常 → 同一 runRing 也产生垃圾
carry/temp-buffer（c47b4637）真机 LL 同垃圾/Simple 死锁 → in-place 竞态假设证伪
Step1 ✅：tuner 移植后 RING 4.5ms → 42.8-244µs（µs 级回恢，sum_check 全 ok）
```

#### Archi 裁定
1. **根因成立（Q1）**：与现象完全一致，且**正是 A' 排查清单第 1 类"algo-ID 索引数组未扩到 a=7"（最高嫌疑）命中**。直接证据（TUNING 输出 2HOP latency=0 vs RING/PAT 非零）只影响 2HOP 入口 → 解释"同 kernel 经 2HOP 失败"。链：未初始化 latency → 退化成本 → 任务参数错 → kernel 读错 chunk 布局 → 确定性垃圾值。carry 证伪与之一致（carry 改 kernel 层缓冲，根因在 host 侧成本模型，治不了）。**最终确认 = 决策门 ①**。
2. **批准 A' 继续（Q2）**：补 tuning.cc 2HOP 常量（镜像 RING）+ 核查 bandwidths[7]/graphs[7]/proxy op/连接。预算约 0.5-1 人日（远低于 5 人日上限）。验收门：
   - **前置**：NCCL_DEBUG=TUNING 显示 2HOP 三协议 latency 非零（镜像 RING）。
   - **① fallback 对照**：2HOP+runRing → ok=True 6.0/6.0/6.0（根因闭环）。
   - **② 干净 kernel 测试（按序）**：②a 原始 run2Hop（双 Primitive）→ ②b 若失败再测 carry 变体。逐协议报（LL/SIMPLE/LL128——SIMPLE 此前从未被干净测过）。
   - **③** ② 通过后跑 G1 四尺寸 {1K,16K,64K,256K} + 无 hang。
3. **决策树修正（Q3）**：
   - **① 修复后仍失败** → 剩余 plumbing 差异（**非 kernel 裁决**）→ 继续有界排查（diff ncclTaskColl 全文 + 其余 a=7 数组）；A' 总预算 ≤5 人日，超支则转 D（记录剩余 plumbing 根因）或升级。
   - **① 过、② 失败** → **干净 kernel 裁决**（真·双 Primitive 问题）→ 旧 A（新 sendrecv 原语 5-10 天）/ D 再裁（此时有真实证据）。
   - **① 过、② 过** → 进 G1-G3（G3 已因 Step1 ✅ 具备可测性）。
4. **Step1 确认**：tuner 移植后 RING 回 µs 级（42.8-244µs）→ G3 测量前提成立。此为其独立价值（即使 2-hop 最终走 D，tuner 移植也对齐了测试库与生产库行为）。

---

## 6. 数据来源
- S3 门规格：`nccl-2hop-s3-phase1-gate-spec-architect-2026-08-16.md`
- S3 执行报告：`nccl-2hop-s3-phase1-window-execution-sre-2026-08-16.md`（2HOP 机制阻塞）
- S3 构建状态：`nccl-2hop-s3-phase1-build-status-sre-2026-08-16.md`
- 本地数据：`nccl-2hop-s3-data/s3-g1-ring.json`、`s3-g3-ring-baseline.json`
- S2 终审：`nccl-2hop-s2-adjudication-architect-2026-08-16.md`
- 历史：`.workbuddy/memory/2026-08-15.md`、`2026-08-16` 系列

---

*文档生成：2026-08-17（S3 Step1/Step2 裁审框架待命版，数据到后填充结论）*
