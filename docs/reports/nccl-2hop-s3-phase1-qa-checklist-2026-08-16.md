# NCCL 2-hop Allreduce · S3 第一阶段 QA 数据复核 Checklist（G1/G2/G3/P2）

**日期**：2026-08-16
**编制**：Tessa（QA / Testing Expert，工程保障团队）
**上游**：`nccl-2hop-s3-phase1-gate-spec-architect-2026-08-16.md`（门规格，Archi）/ QA §11 复核意见（`nccl-2hop-s2-report-qa-2026-08-16.md` §11，已被规格 §3.3 采纳）
**用途**：
1. **供 Rex 对照落盘**——测试执行时按本 checklist 收集/输出数据，避免缺项；
2. **供 QA 复核**——Rex 回传后，QA 按 §6 协议独立复核 G1/G2/G3/P2 判读。
**性质**：只读数据要求，不触发测试执行；判读权在 QA，裁审权在 Archi，放行权在 team-lead + 人类。

---

## 0. 复核总览（一屏速览）

| 门 | 判据（规格） | QA 复核要点 | 失败处置 |
|---|---|---|---|
| **G1** | 4 rank × {1K,16K,64K,256K} ok 全 True + 无 hang | ok 之外**核对输出=sum(ranks)**；watchdog/BLOCK_TIMEOUT 空；单机 dry-run 先行；per-rank 日志齐全 | 终止 |
| **G2** | 2HOP capture：Test A B=1..64 全 ok + Test C 64/64 + 重放正确 | captured=64/64；rep_max/rep_avg≤2.5（尖峰=告警非否决）；重放结果与捕获一致 | **NO-GO** |
| **G3** | `ratio_real(p50)@16K ≤ 0.80`（主） | **≥2-3 轮独立 A/B 取中位数**（§11.1 重复性防线）；1K 参考不失败；4K/64K 描形必测；p99 升级规则；δ_hw 联动 | >0.88 **NO-GO**；0.80-0.88 降级 ≤16K 路由 |
| **P2** | ≤64K 双边步无严重争用 | δ_hw(p50)@16K：≥1.7 自动降级/重评；1.3-1.7 → P2 成为 full 显式前置；≤1.3 理想 | 争用 → 单边主导变体重评/终止 |

> 数据标准（§11.5，规格已采纳）：每尺寸报 **N / avg / p50 / p95 / p99 / ok / block_timeouts**；同时给 **ring 与 2hop 原始分布**（不只 ratio）；**priming 确认 + warmup 计数 + DQ（lib md5 / NCCL_ALGO / env）+ 生产隔离 pre/post**；ring 与 2hop **同容器/同 env/同 lib，仅 NCCL_ALGO 不同**。

---

## 1. 数据交付清单（Rex 落盘必备）

### 1.1 必须交付的文件（缺一 QA 视为数据不完整，不进入判读）

| # | 文件/产物 | 说明 | 对应门 |
|---|---|---|---|
| D1 | `s3-g1-result.json` | G1 各尺寸结果（ok / 输出校验 / 用时 / per-rank） | G1 |
| D2 | `s3-g1-rank{0..3}.log` | 四 rank 原始日志（含 watchdog / BLOCK_TIMEOUT / 心跳） | G1 |
| D3 | `s3-g2-capture.json` | Test A（B=1..64）+ Test C（64 档池）capture 结果 | G2 |
| D4 | `s3-g2-replay.json` | 重放正确性（与捕获结果逐字节/逐值比对） | G2 |
| D5 | `s3-g3-ab.json` | G3 A/B 原始数据（**ring 与 2hop 各自的分布**，非仅 ratio） | G3 |
| D6 | `s3-dhw-16k.json` | δ_hw@16K 数据（p50 判据） | P2 |
| D7 | `s3-dq.json` | 环境/DQ 快照（lib md5、NCCL_ALGO、env、容器 ID） | 全门 |
| D8 | `s3-isolation-pre.json` / `s3-isolation-post.json` | 生产隔离 pre/post 检查（生产进程/端口/负载） | 全门 |

### 1.2 每文件必含字段（对照 §5 数据标准）

- 所有 json：`tier/size`、`algo`（ring|2hop）、`N`（样本数）、`avg/p50/p95/p99`、`ok`、`block_timeouts`、`warmup_iters`、`primed`（bool）、`raw`（原始样本数组或分布直方图）。
- 缺失任一字段 → 该行标注 `DQ_INCOMPLETE`，QA 不采信该行。

### 1.3 元信息

- 执行窗口（起止 UTC）、四机窗口 id、测试容器名（2hop-s1-rank0..3）、被测 lib 版本/md5、生产 md5（须仍为 2be94172，无变更）。

---

## 2. G1 正确性复核 checklist

### 2.1 前置（dry-run 先行）
- [ ] **单机 4 进程 dry-run 已通过**（记录于 D1 或单独 dry-run 日志）——未过单机则四机结果 QA 不采信。
- [ ] 四机容器就绪：2hop-s1-rank0..3，rank 间网络可达（IB/NET=IB），PEER_HCA v4。

### 2.2 尺寸与 ok
- [ ] 4 尺寸齐全：**1K / 16K / 64K / 256K**（1K=参考、16K=P5 目标、64K=路由上限、256K=路由外无回归）。
- [ ] 每尺寸 4 rank 全部 `ok=True`；任何 ok=False → **G1 失败 = 终止**。
- [ ] **输出 = sum(ranks) 校验**（不只 ok 标志）：allreduce 结果逐元素核对 = 各 rank 输入之和；每尺寸至少抽验一次全量（小尺寸可全量、大尺寸抽验首尾/中段）。记录校验方式与通过/失败。
  - QA 注：ok=True 仅表示 kernel 未报错；**正确性必须由 sum 校验独立证实**（防"跑通但算错"）。

### 2.3 无 hang / 死锁
- [ ] watchdog 日志空（无超时告警）；
- [ ] `BLOCK_TIMEOUT` 计数 = 0（D2 日志 grep `BLOCK_TIMEOUT` 应为空）；
- [ ] 心跳/进度打印持续至完成；每档 elapsed 在预期范围内（无卡死）。

### 2.4 判读输出
```
G1 = PASS  ⟺  4×4 ok 全 True ∧ sum 校验通过 ∧ 无 hang ∧ dry-run 已过
G1 = FAIL  → 终止（不进入 G2）
```

---

## 3. G2 capture 复核 checklist

### 3.1 Test A（B=1..64 顺序单 all_reduce graph）
- [ ] B=1,2,4,8,16,32,64（规格为 B=1..64，逐档或覆盖代表档均可，**但必须包含 B=1 与 B=64**）全部 `ok=True`。
- [ ] 每 B 档 captured=True（graph capture 成功，非回退 eager）。
- [ ] 记录每档 capture 用时 / 重放用时。

### 3.2 Test C（64 档池）
- [ ] `captured=64/64`——任何 1 档失败 → **G2 = NO-GO**（capture 是生产硬前提，不可绕过）。
- [ ] 尖峰检查：`rep_max/rep_avg ≤ 2.5`（告警非否决）；>2.5 记录档位，QA 标注，不直接否决。

### 3.3 重放正确性
- [ ] 捕获后重放结果与捕获时一致（逐值比对，记录一致率；应 100%）。
- [ ] 重放无新 capture（命中缓存），无重复编译。

### 3.4 判读输出
```
G2 = NO-GO  ⟺  Test A 任一 B 失败 ∨ Test C <64/64 ∨ 重放不一致
G2 = PASS   ⟺  全部满足（尖峰仅告警）
```

---

## 4. G3 收益判读 checklist（含 §11 重复性防线）

### 4.1 测量设置（必须逐项满足）
- [ ] **同容器/同 env/同 lib**：ring = `NCCL_ALGO=RING`（生产路径）、2hop = `NCCL_ALGO=2HOP`，仅算法条目切换（DQ 核对）。
- [ ] 协议 auto（生产默认）；LL/Simple 可选定标（记录）。
- [ ] warmup=15、**iters≥200**（小尺寸可更多）。
- [ ] 每轮运行 `ok=True`。
- [ ] 环境变量与 S2 相同：NCCL_ALGO、NET=IB、MAX_NCH=16、PEER_HCA v4。

### 4.2 尺寸组合（§11.2 已采纳为必测）
- [ ] **16K（主判据）**：ratio_real(p50)@16K ≤ 0.80。
- [ ] **1K（参考）**：**1K 参考不失败**——若 1K >0.88（或 2hop 反超 ring），说明尺寸相关异常 → 先查原因再放行（即使 16K 过）。
- [ ] **4K 描形（必测）**：确认延迟区（4K）ratio_real ≤0.88。
- [ ] **64K 描形（必测）**：确认路由上限（64K）ratio_real ≤0.88 —— **"降级 ≤16K 路由"前提（仅 16K 好）必须由 4K/64K 全线 ≤0.88 支撑**，否则降级前提不成立。

### 4.3 重复性防线（§11.1，最重要）
- [ ] **@16K 至少 2-3 轮独立 A/B**，取 `ratio_real(p50)` 的**中位数**。
- [ ] 各轮须落在同一侧（或 ≥2/3 同侧）；否则视为不稳定 → 加跑。
- [ ] **边界带 0.78-0.82 → 强制加跑一轮**。
- [ ] **禁止单轮定 G3**（S2 已多次证明单轮/单尺寸可被重尾与噪声带偏）。

### 4.4 p99 尾部（§11.3 升级规则，非 G3 否决项）
- [ ] 报告 2hop/ring 各自 p50/p95/p99 + `ratio_real(p99)`。
- [ ] `ratio_real(p99) > 1.2` → **P6 e2e decode 尾部验证升为必做**（full 阶段看护项）。
- [ ] `ratio_real(p99) > 1.5` → **P2 per-edge 调度复查**。
- [ ] avg/p50 > 1.5 → 以 p50 为准并标注尾部。

### 4.5 判读输出（@16K p50）
```
ratio_real ≤ 0.80                 → G3 PASS → 启动 full implementation
0.80 < ratio_real ≤ 0.88          → G3 边界 → 降级 ≤16K 路由（team-lead 定值不值）
ratio_real > 0.88                 → G3 FAIL = NO-GO → 终止
（叠加：1K/4K/64K 任一 >0.88 或 1K 反超 → 先查原因；重复性未达标 → 加跑；禁止单轮定论）
```

---

## 5. P2 per-edge 调度复核 checklist

- [ ] δ_hw@16K（p50 判据）数据齐全（D6）。
- [ ] **δ_hw(p50)@16K ≥ 1.7** → 双边争用串行化，收益前提动摇 → **G3 自动降级/重评**。
- [ ] **1.3 ≤ δ_hw < 1.7** → G3 仍按 ratio_real 判，但 **P2 per-edge channel 调度成为 full 放行的显式前置**。
- [ ] **δ_hw < 1.3** → 理想，正常推进。
- [ ] ≤64K 双边步无严重争用（per-edge channel 并发生效）；若争用 → 单边主导变体重评/终止。

---

## 6. QA 独立复核协议（Rex 回传后执行）

1. **DQ 复核**：lib md5 与 D7 一致；NCCL_ALGO 与档位匹配；env 与 S2 一致；容器为测试容器；生产 md5=2be94172 无变更。
2. **复算 ratio_real**：由 D5 中 ring/2hop 原始分布独立计算 ratio_real(p50/p95/p99)，与 Rex 上报比对（≤1% 容差）。
3. **重尾核对**：avg/p50>1.5 → p50 为准并标注；p99 升级规则复核。
4. **重复性核对**：2-3 轮 A/B 中位数、同侧性、边界带加跑是否执行。
5. **时序交叉**：S3 窗口与生产 BenchV2/其他操作无重叠（参考 S2 §8.2 方法）。
6. **隔离核对**：pre/post 生产负载/进程/端口无异常波动；测试前后生产指标回落。
7. **输出复核报告**：G1/G2/G3/P2 判定 + 数据缺口 + 风险标注 → 回传 team-lead / Archi。

---

## 7. Rex 落盘对照表（Checklist 汇总，执行后逐项勾选）

| 项 | 要求 | Rex 勾选 | QA 复核 |
|---|---|---|---|
| G1 dry-run | 单机 4 进程先过 | ☐ | ☐ |
| G1 4×4 ok | 4 rank × 4 尺寸全 True | ☐ | ☐ |
| G1 sum 校验 | 输出 = sum(ranks) 抽验通过 | ☐ | ☐ |
| G1 无 hang | watchdog/BLOCK_TIMEOUT 空 | ☐ | ☐ |
| G2 Test A | B=1..64 全 ok（含 B=1、B=64） | ☐ | ☐ |
| G2 Test C | captured=64/64 | ☐ | ☐ |
| G2 重放 | 重放一致 100% | ☐ | ☐ |
| G3 重复性 | @16K ≥2-3 轮 A/B，取中位数 | ☐ | ☐ |
| G3 1K 参考 | 1K ratio ≤0.88 且不反超 | ☐ | ☐ |
| G3 4K/64K 描形 | 全线 ≤0.88（必测） | ☐ | ☐ |
| G3 主判据 | ratio_real(p50)@16K ≤0.80 | ☐ | ☐ |
| G3 p99 | p50/p95/p99 + ratio_real(p99) 上报；升级规则触发项记录 | ☐ | ☐ |
| P2 δ_hw | δ_hw@16K p50 上报；联动处置记录 | ☐ | ☐ |
| 数据标准 | N/avg/p50/p95/p99/ok/block_timeouts/warmup/primed/raw 齐全 | ☐ | ☐ |
| DQ | lib md5 / NCCL_ALGO / env 快照 | ☐ | ☐ |
| 隔离 | pre/post 生产检查 | ☐ | ☐ |

---

## 8. 参考文档

- 门规格：`nccl-2hop-s3-phase1-gate-spec-architect-2026-08-16.md`
- QA §11 加固项：`nccl-2hop-s2-report-qa-2026-08-16.md` §11
- 终审裁定：`nccl-2hop-s2-adjudication-architect-2026-08-16.md`
- 基线衔接：`nccl-benchmark-v2-report-qa-2026-08-16.md`（32K PR 2425 / 131K PR 2200 / DE 全档）

---

*本 checklist 由工程保障团队 QA 成员编制；Rex 执行测试后按 §1 落盘、§7 勾选，QA 按 §6 独立复核，Archi 裁审，team-lead + 人类放行。*
