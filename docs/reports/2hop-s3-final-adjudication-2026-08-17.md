# NCCL 2-hop Allreduce · S3 终审裁定（Archi / 架构）

**日期:** 2026-08-17
**作者:** Archi（系统架构师）
**上游:** `nccl-2hop-s3-step12-adjudication-framework-architect-2026-08-17.md`（§7.5 A' 裁定）/ Rex A' 执行数据（lib d3fc78a4 / cfa8c14c / 9176e156）/ team-lead 转达
**状态:** 终审裁定（技术层面）——待 team-lead + 人类批准
**性质:** 只读架构裁定，不执行测试、不碰生产

---

## 0. 裁定摘要（TL;DR）

1. **① 根因闭环 ✅**：2HOP 垃圾值真根因 = **device kernel table 未注册 2HOP**（generate.py 缺 "2HOP" + ncclDevFuncId nAlgos=6 溢出 → 一直 launch Reduce kernel）。tuning.cc 常量缺失是外层症状；两者均已修复（lib d3fc78a4）→ 2HOP+runRing fallback 回 `ok=True [6.0]`。
2. **② 干净 kernel 首测 = 机制级否定**：唯一实际运行的 2-hop kernel（SIMPLE + 双 Primitives）在 form C pairwise 与 carry 变体**以完全相同的方式 illegal memory access 崩溃** → **SIMPLE 协议下"单 thread block 双 Primitives 并发"在当前 NCCL ring 原语框架内不可行**（无竞态可解，非 kernel 层）。
3. **价值区不可触及**：LL/LL128 未实例化 2-hop kernel（directRecvReduceCopy 仅 SIMPLE，编译期隔离）——而生产 tuner 将 ≤32KB 路由 LL，**16K 目标协议正是 LL**。当前原型无法在目标协议上运行 2-hop。
4. **A-2（修 SIMPLE FIFO/proxy）不构成通往价值的路径**：即使成功修复 SIMPLE，2-hop-SIMPLE 在 16K 被 auto 路由（LL）挤出 → ratio_real≈1.0，**G3 不可能通过**。
5. **最终裁定**：**技术层面推荐 D（收尾）**——2-hop bilateral 在当前原型框架内已获干净否定；继续的唯一合理路径是旧 A（新 sendrecv 原语），但需业务价值（3-8% TPOT）支撑 5-10 人日 / 40-60% 投入。**A/D 为业务决策，呈报用户拍板。**

---

## 1. ① 根因闭环与"两层根因"澄清

| 层 | 根因 | 状态 |
|---|---|---|
| 外层 | `ncclTunerConstantsDefaults` 缺 2HOP 常量 → cost 退化 | ✅ 已修（A' 阶段） |
| 内层 | **device kernel table 未注册 2HOP** → 一直 launch 到 Reduce kernel → 垃圾值 | ✅ 已修（d3fc78a4，constants + device table + algo1 映射） |

**裁定**：两层均属"algo-ID 索引/注册未覆盖 a=7"同一类缺陷；内层解释垃圾值更直接（launch 错 kernel）。**① fallback 对照通过 = 根因闭环**。

---

## 2. ② 干净 kernel 首测——机制级否定

```
首次在 plumbing 修复后的干净环境运行真实 2-hop kernel：

②a form C pairwise（cfa8c14c）  LL: fallback→OK    LL128: fallback→OK    SIMPLE: CRASH(illegal memory access)
②b carry 变体（9176e156）       LL: fallback→OK    LL128: fallback→OK    SIMPLE: CRASH(与 form C 完全相同)
```

**裁定**：
1. **carry/temp-buffer 假设最终证伪**：②a 与 ②b 崩溃方式完全相同 → 非 in-place send 源覆写竞态。
2. **SIMPLE 双 Primitives = 机制级问题**：两套独立 kernel 设计在 SIMPLE 下同点崩溃 → 问题在 SIMPLE FIFO/proxy 与"单 thread block 双 Primitives"的底层对齐，非 kernel 调度/竞态可解。此为干净证据。
3. **LL/LL128 从未真正运行 2-hop kernel**（编译期缺失，走 ring fallback）→ 无 2-hop 在 LL/LL128 上的正/反证据——只有"未实现"。

---

## 3. 价值区分析与 A-2 判定（关键架构推理）

### 3.1 2-hop 收益所在协议 = LL/LL128，不是 SIMPLE

- 生产 tuner（stageB）：**≤32KB 路由 LL，≥48KB 路由 Simple**（历史实证 -21~31% 小消息 LL 收益）。
- G3 主判据 @16K → 生产协议 = **LL**。
- 因此 2-hop 必须在 LL/LL128 上正确运行，才能与 ring-LL（生产基线）比出 ratio<1。

### 3.2 当前原型在价值区的状态

| 协议 | 2-hop kernel | 状态 | 能否过 G3 |
|---|---|---|---|
| SIMPLE | 已实现 | **崩溃（机制否定）** | — |
| LL/LL128 | **未实例化**（编译期隔离） | 走 ring fallback（正确但非 2-hop） | **否**（无 2-hop 可测） |

### 3.3 A-2（修 SIMPLE proxy/FIFO）判定：**不构成通往价值的路径**

- 即使 A-2 修复 SIMPLE 崩溃（成本 2-5 人日，成功率 40-60%，不确定性高——FIFO 语义冲突可能是深层结构问题）：
  - 2-hop 在 16K 被 auto 路由到 LL → SIMPLE-only 2-hop **不会被选中** → fallback ring → ratio≈1.0；
  - 若强制 NCCL_PROTO=Simple 测 ratio，比较基准是 ring-SIMPLE 而非生产基线 ring-LL → **测得比值失真、不可采信**（违背 G3"同库同环境 auto"口径）。
- **结论：A-2 单独走不能到达收益区，不建议作为独立选项**。

---

## 4. 选项评估与 EV

| 选项 | 内容 | 成本 | 成功率 | 到价值区？ | 备注 |
|---|---|---|---|---|---|
| **D** | 归档 + RING 基线 G1-G3 定版收尾 | ≈0 | 100% | 否 | 干净否定结论已成立 |
| **A-2** | 修 SIMPLE FIFO/proxy | 2-5 人日 | 40-60% | **否**（SIMPLE≠16K 目标协议） | 不建议单独走 |
| **旧 A** | 新 sendrecv 原语（发 X 收 Y），覆盖 LL/LL128+SIMPLE | 5-10 人日 | 40-60% | **是**（唯一可达） | 需业务价值支撑 |

**EV 参考**：
- 旧 A 期望 ≈ 0.5 × 3-8% TPOT（永久性收益）− 5-10 人日（一次性）+ 门验证成本。若服务长期运行，EV 可能为正——**业务属性，需用户按 TPOT 价值定价**。
- D 期望 = 0（省预算，转投 P2 交换机 / 0.27 升级等 ROI 更清晰项）。

---

## 5. 裁定与呈报建议

### 5.1 技术裁定

> **在当前 NCCL ring 原语框架内，2-hop bilateral（双 Primitives 单 thread block 并发）已被干净证据否定（SIMPLE 崩溃）；LL/LL128 价值区未实现且无法用现有原语低成本补齐。修复 SIMPLE（A-2）不构成通往 2-hop 价值的路径。继续的唯一合理路径 = 新设备原语（旧 A），但需业务价值支撑。**

### 5.2 呈报用户建议（主推 D）

- **主推 D**：2-hop 在当前框架不可行（干净证据）；价值上限 3-8% TPOT 与累计投入/剩余风险（旧 A 5-10 人日 × 40-60%）相比，期望不足；RING 基线（生产 2be94172 + proto 库 tuner 对齐后 µs 级）已绿，可定版收尾；预算转投更高 ROI 项。
- **若用户坚持**：唯一合理路径是**旧 A（新 sendrecv 原语）**，须同时覆盖 LL/LL128+SIMPLE（单一 SIMPLE 修复无法过 G3）；设硬门（**LL 16K 正确性为首要验收**）+ 预算上限 ≤10 人日 + 退出分支（失败 → 立即 D）。
- **不建议 A-2 作为独立项目**。

---

## 6. D 收尾范围（若批准）

1. RING 基线终验（tuner 对齐后 proto 库）：G1 四尺寸 ok + G3 RING p50@16K µs 级 + 无 hang → 与生产 2be94172 基线归档。
2. 2-hop 线归档：源码分支/补丁/失败复现（2hop-failures）全部留档，结论写入 ADR（**2-hop 在当前 NCCL 框架 INCONCLUSIVE-with-negative-evidence；新原语为唯一续接点**）。
3. 生产隔离记录 + 回滚确认（生产库 md5 2be94172 未变）。
4. 若走旧 A：新 task 立项，本裁定作为其技术基线。

---

## 7. 数据来源
- A' 裁定：`nccl-2hop-s3-step12-adjudication-framework-architect-2026-08-17.md`（§7.5）
- Rex A' 执行数据：① d3fc78a4（2HOP+runRing→6.0）；② cfa8c14c（form C）/ 9176e156（carry）——LL/LL128 fallback OK、SIMPLE CRASH
- 生产基线：2be94172（Stage B hardened）
- 历史：S2 终审 / S3 门规格 / 构建与窗口执行报告（均在前序文档）

---

*文档生成：2026-08-17（S3 终审裁定——2-hop 项目最终裁决点，待 team-lead + 人类批准）*
