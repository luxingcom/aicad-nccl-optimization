# NCCL 2-hop Allreduce · S3 第一阶段原型门规格（P1/P3/P5 硬门 + P2 强制）

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**上游:** `nccl-2hop-s2-adjudication-architect-2026-08-16.md`（终审裁定）/ `nccl-2hop-p0-diagnosis-result-architect-2026-08-16.md`（P0 分叉裁定：前进 P1/P3/P5）/ QA P0 复核（testing-expert，通过）
**状态:** 规格定稿，待 team-lead 批资源与窗口
**性质:** S3 原型门设计（只读，不执行测试）

---

## 0. 总览

P0 分叉通过后，S3 第一阶段原型门启动。本规格定义三硬门（G1 正确性 / G2 capture / G3 收益）的**验收判据 + 判读框架**，供 Rex 执行、QA 复核、Archi 裁审。

| 门 | 内容 | 判据 | 失败处置 |
|---|---|---|---|
| **G1（P1）** | 真实 kernel 正确性/无死锁 | 4 rank × 4 尺寸 ok 全 True + 无 hang | 终止 |
| **G2（P3）** | 真实 kernel capture（生产模式） | 2HOP 下 Test A（B=1..64）+ Test C（64/64）+ 重放正确 | **NO-GO** |
| **G3（P5）** | 真实 kernel 小消息收益锚定 | `ratio_real(p50) ≤ 0.80` @16K（主） | **NO-GO**（>0.88）；0.80-0.88 → 降级 ≤16K 路由 |
| **P2** | per-edge channel 调度（强制） | ≤64K 双边步无严重争用 | 若争用 → 单边主导变体重评/终止 |

---

## 1. P1 原型规格（G1）

- **实现形态**：Form A-minimal——测试库变体 `libnccl-2hop-proto.so`（与 ring-only 库同源构建）新增最小 2hop 算法条目；复用 ring kernel 设备结构，步循环 RS(3)+AG(3)→RS(2)+AG(2)；双边步 2 channel 并发（**per-edge channel**：edge e / edge e-1 各一 channel，与 P0-2 edge-parity 双 PG 同构）。
- **选择**：`NCCL_ALGO=2HOP` 显式选择；默认 ring 完全不动；不接 tuner、不进生产库/容器。回滚风险为零（仅测试容器 LD_PRELOAD）。
- **数据分块**：1.5S 理想（RS 每 rank 收发 S/2、AG 对称）——P4 修正项折叠进原型，P5 测目标设计。
- **验收（G1）**：4 rank × {1K, 16K, 64K, 256K} 输出 = sum(ranks) 全 ok + 无 hang（watchdog/心跳同 S2 规范）；**先单机 4 进程 dry-run 再四机**。
  - 1K=参考、16K=P5 目标、64K=路由上限、256K=路由外确认无回归（正确性）。

## 2. P3 capture 规格（G2）

- **测试形态（比 S2 简化）**：原 Test B 双 PG 模式被"真实 2hop 算法单 all_reduce 捕获"取代——2hop kernel 双边并发在 kernel 内部，不需要双 PG 建模。**P3 = 对 `NCCL_ALGO=2HOP` 跑 Test A（B=1/8/16/32/64 顺序单 all_reduce graph）+ Test C（64 档池）+ 重放正确性**。直接测 vLLM 生产捕获模式（每 op 单 all_reduce）。
- **验收（G2）**：Test A 全 ok + Test C captured=64/64 + 重放正确。尖峰为告警非否决（rep_max/rep_avg≤2.5）。
- **失败 = NO-GO**（capture 是生产硬前提，不可绕过）。

## 3. P5 真实 kernel A/B 判读框架（G3）

### 3.1 测量设置

| 项 | 规格 |
|---|---|
| 被测 | 同一测试库 `libnccl-2hop-proto.so`：ring = `NCCL_ALGO=RING`（生产路径）、2hop = `NCCL_ALGO=2HOP` |
| 尺寸 | **16K（主判据）+ 1K（参考）**；可选 4K（延迟区）/ 64K（路由上限）描形 |
| 协议 | auto（生产默认）；LL/Simple 可选定标 |
| 采样 | warmup=15、iters≥200（小尺寸，快）；**avg + p50 必报**（重尾防线），p99 作尾部参考（decode 步同步 = 尾部也相关） |
| 正确性 | 每次运行 ok=True |
| 环境 | DQ 检查：lib md5、NCCL_ALGO 正确、block_timeouts 空、生产隔离（precheck/postcheck） |
| 环境变量 | 与 S2 相同（NCCL_ALGO/RING、NET=IB、MAX_NCH=16、PEER_HCA v4）——仅算法条目切换 |

### 3.2 指标与判据

```
ratio_real = 2hop 延迟 / ring 延迟（同库同环境）
主判据：ratio_real(p50) @16K ≤ 0.80
参考：ratio_real(p50) @1K（≤0.80 理想；1K 噪声大，作次级参考）
重尾防线：avg/p50 > 1.5 → 以 p50 为准并标注尾部；p99 供 decode 尾部评估
```

| 区间（@16K p50） | 判定 |
|---|---|
| **≤ 0.80** | **G3 通过** → 启动 full implementation |
| 0.80 - 0.88 | G3 边界 → 降级：full 范围收敛 ≤16K 路由（8-12 人日值不值 <12-20% 收益需 team-lead 定） |
| **> 0.88** | **G3 失败 = NO-GO**（真实 kernel 也 <12% 收益 → 终止） |

### 3.3 数据质量注（采纳 QA 建议）

- **bilateral_micro 常态化输出 p50**（口径 p50 优先）——δ_hw@16K 补测（并入 P5 窗口）以 p50 为判据。
- 与生产基线衔接：若 G3 通过，full 阶段 A/B 需对回 BenchV2 基线（32K PR 2425 / 131K PR 2200 / DE 全档）做 e2e 验证（P6 范围）。

---

## 4. 窗口需求

- 四机测试容器（2hop-s1-rank0..3）+ 单机 dry-run 先行；预计 **0.5-1 天**（构建测试库 + G1 + G2 + G3 + δ_hw@16K）。
- 生产无变更（md5 2be94172），precheck/postcheck 记录同 P0 规范。
- 排期建议：P1 → P3（早死早止损）→ P5 →（可选）δ_hw@16K 同窗。

---

## 5. 裁审流程

1. Rex 执行并回传数据（JSON + rank0 日志 + 生产隔离记录）。
2. QA（testing-expert）独立复核（DQ + 复算 + 时序交叉）。
3. Archi 裁审 G1/G2/G3 + P2 结论 → S3 full / 降级 / NO-GO 决策建议。
4. team-lead + 人类批准。

---

## 6. 数据来源
- 终审裁定：`nccl-2hop-s2-adjudication-architect-2026-08-16.md`
- P0 裁定：`nccl-2hop-p0-diagnosis-result-architect-2026-08-16.md`
- QA P0 复核：`nccl-2hop-s2-report-qa-2026-08-16.md`（§9 P0 复核）
- 基线：BenchV2 QA 报告（32K PR 2425 / 131K PR 2200 / DE 全档）

---

*文档生成：2026-08-16（S3 第一阶段原型门规格定稿，待批）*
