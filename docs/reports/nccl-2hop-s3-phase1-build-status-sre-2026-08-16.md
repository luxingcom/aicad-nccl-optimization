# NCCL 2-hop S3 第一阶段 · SRE 执行状态报告（Rex）

**日期**: 2026-08-16
**作者**: Rex（SRE 工程师，工程保障团队）
**收件**: team-lead（工程总监）→ Archi 裁审 / QA（testing-expert）复核
**上游**: `nccl-2hop-s3-phase1-gate-spec-architect-2026-08-16.md`（门规格）/ `nccl-2hop-s3-phase1-qa-checklist-2026-08-16.md`（QA checklist）
**状态**: ① bench_v2 修复链已完成并补跑 72/72 ok；② 2-hop proto 库已构建（md5 4646d82b）通过 md5/GLIBC/加载/选择路径验证；③ 四机 G1/G2/G3 待窗口执行

---

## 0. TL;DR

| 交付 | 状态 | 说明 |
|---|---|---|
| bench_v2.py 读超时修复 | ✅ 已生效 | md5 `6ed8ce93 → f72e9e84`；原 4 失败档全恢复，72/72 ok |
| v2 补跑（6 档） | ✅ 完成 | 131K/32K × C2/C4/C6，全 72/72 ok，acceptance 1.0 |
| 长前缀阈值建议 | ✅ 已定稿 | 见 §5 / `nccl-benchv2-long-prefix-threshold-recommendation-sre-2026-08-16.md` |
| **libnccl-2hop-proto.so** | ✅ 已构建 | md5 `4646d82b21b6a607d775732ef7635d00`，NCCL 2.30.7+cuda13.0，GLIBC≤2.34，生产镜像内构建 |
| run2Hop kernel | ✅ 已实现 | 4 步调度（RS2+AG2），双边步双连接并发，复用 ring 连接 |
| 单机 dry-run | ✅ 已过 | mock 调度全尺寸 = sum(ranks)；lib 加载 + NCCL_ALGO=2HOP 识别 |
| G1/G2/G3/dhw 脚本 | ✅ 就绪 | 按 QA checklist D1-D8 落盘 |
| 四机 G1/G2/G3 | ⏸ **待窗口** | 需生产 quiesce（S3 规格 + QA §6.5）；请求 team-lead 排期 |

---

## 1. 任务 1：bench_v2 修复链

### 1.1 修复内容（已落盘 /opt/aicad-prod/bench_v2.py）

| 项 | 修复前 | 修复后 |
|---|---|---|
| run_one 读超时 | `timeout=(connect_timeout, min(timeout,60))` | `timeout=(connect_timeout, timeout)`（放开至 request wall-clock 1800s） |
| stream 层超时分类 | ReadTimeout 落 `Exception` → `other` | 显式 `(requests.Timeout, requests.ReadTimeout)` → `timeout` |

- 备份：`/opt/aicad-prod/backup/bench_v2.py.bak-60s-fix-20260816`（md5 6ed8ce93）
- 新 md5：`f72e9e84397ebd8cb6ffbcc8825535bf`；`python3 -m py_compile` OK
- 与 QA §6.4 建议 1/2 完全一致

### 1.2 补跑结果（BENCHV2_FIX_20260816T165051Z，monitor 纯净窗口，全 72/72 ok）

| 档 | 修复前 | 修复后 | TTFT p50 (s) | TTFT p95 (s) | prefill p50 (tps) | wall-agg (tps) |
|---|---|---|---|---|---|---|
| PR_C2_L131076 | 0/6（全 Read timed out） | **6/6 ok** | 100.6 | 101.6 | 1145.1 | 2263.9 |
| PR_C2_L32768 | 6/6 有效 | 6/6 ok | 22.1 | 23.5 | 1299.7 | 2457.0 |
| PR_C4_L131076 | 0/12 | **12/12 ok** | 187.8 | 190.7 | 614.4 | 2419.2 |
| PR_C4_L32768 | 12/12 有效 | 12/12 ok | 42.4 | 43.4 | 678.5 | 2687.1 |
| PR_C6_L131076 | 0/18 | **18/18 ok** | 199.5 | 305.2 | 578.2 | 2270.0 |
| PR_C6_L32768 | 12/18 | **18/18 ok** | 43.6 | 64.8 | 660.2 | 2638.4 |

**结论**：QA 判定的「客户端 60s 读超时工具 bug」已修复并实证——原 4 档全部恢复为接受率 1.0；131K 并发曲线补齐（C1 2142 → C2-C6 2260-2420 wall-agg 持平），32K@C6 干净值 2638（原 1910 为失败稀释）。v2 全 32 档基线可定版（QA §7.2.2）。

### 1.3 关键观测（长前缀并发特征）

- 131K TTFT 随并发超线性增长：C1≈53.7s → C2=100.6 → C4=187.8（约 3.5x 于 C1）。
- 131K prefill p50 随并发下降：C1≈2147 → C2=1145 → C4=614（约 0.29x），TP4 ring prefill 饱和。
- 该曲线是 2-hop full 阶段（≤64K 路由）之外的 ring 基线参考；131K 不在 2-hop 路由范围。

---

## 2. 任务 2：libnccl-2hop-proto.so 构建（Form A-minimal）

### 2.1 产物

| 项 | 值 |
|---|---|
| 库 | `/opt/2hop-s1/proto-lib/libnccl.so.2.30.7`（+ `libnccl.so.2` 符号链接） |
| **md5** | `4646d82b21b6a607d775732ef7635d00` |
| 版本串 | `NCCL version 2.30.7+cuda13.0` |
| **GLIBC 需求** | ≤ GLIBC_2.34（objdump 验证）；生产镜像 GLIBC 2.35 → 可加载（已 smoke test LD_PRELOAD + ncclGetVersion=23007） |
| 构建容器 | `<LAN-IP>:5000/anemll/dspark-vllm-gx10:0.2.1-v026.0`（与生产同镜像，规避 host GLIBC 2.39 历史教训） |
| 源码分支 | `/opt/2hop-s1/src/nccl-2hop-proto`，`2hop-proto` 分支：clean v2.30.7 + v1/v4 ring-only patch（**不含 tuner**）+ 2HOP 算法 |
| 生产库 | 未触碰：md5 仍 `2be94172c1172734d00dee9ff7d788bd` |

### 2.2 实现（run2Hop kernel）

- **算法**：4 rank allreduce RS(2)+AG(2)（vs ring RS(3)+AG(3)），4 网络步。
- **双边并发**：单个 channel/thread block 内两个 Primitives 对象（group 0 / group MaxGroupWidth）驱动**不相交连接**：
  - primsFwd: send→ring.next, recv←ring.prev
  - primsBwd: send→ring.prev, recv←ring.next
  - 每步先 post 双侧 send、后 recv，SIMPL FIFO 协议下两边缘网络在飞重叠。
- **in-place 语义**：recvReduceCopy 累加依赖 input==output；out-of-place 或 nranks≠4 自动回退 runRing（安全）。
- **数据量**：每 rank 7 chunk = 1.75S（proto，含 P4 修正；P5 理想 1.5S 为 full 目标）。
- **调度**：与 `twohop_algo.py` mock（S1 已验）逐 op 对齐；连接级 send/recv 计数与对端匹配（已在实现前手工核对）。

### 2.3 门规格对照

| 规格项 | 实现 | 状态 |
|---|---|---|
| 复用 ring kernel 设备结构 | ✅ run2Hop 复用 ring prev/next + Primitives | ✅ |
| 步循环 RS(3)+AG(3)→RS(2)+AG(2) | ✅ 4 步调度 | ✅ |
| 双边步 per-edge channel 并发 | ✅ primsFwd/primsBwd 双连接并发 | ✅（kernel 内双 Primitives，非双 NCCL channel——见 §4 说明） |
| NCCL_ALGO=2HOP 显式选择 | ✅ env→parseList→algoEnable；tuner cost 走 ring graph（ring 被禁用时唯一可选） | ✅ |
| 默认 ring 不动 | ✅ NCCL_ALGO 未设时 ring 为默认（2HOP 不在 auto 候选） | ✅ |
| 1.5S 理想分块 | ⚠️ proto 用 1.75S（P4 修正折叠）；1.5S 为 P5 目标 | ⚠️ 记录 |
| 不接 tuner / 不进生产库 | ✅ 分支从 clean v2.30.7 + v1/v4（无 stageB tuner）；仅测试容器 LD_PRELOAD | ✅ |

### 2.4 已验证 / 待验证

- ✅ mock_pure.py：twohop 与 ring 在 16/64/256/4096/65536 元素输出 = sum(ranks)。
- ✅ lib 加载 + ncclGetVersion + 2HOP symbol 存在。
- ✅ **运行时选择路径（代码级验证）**：`NCCL_ALGO=2HOP` → parseList 仅 enable 2HOP → `updateCollCostTable` 对 a=7 调 `ncclTopoGetAlgoTime`（bandwidths[7]=ringGraph 模型值，非 0）→ cost 有效非 IGNORE → `topoGetAlgoInfo` 唯一选中 2HOP；channel/thread 走 Ring/Tree 分支；`maxThreads[2HOP]`/`threadThresholds[2HOP]` 已初始化。
- ⏳ 真 kernel G1 正确性/无 hang —— **需四机窗口**（watchdog 兜底）。

---

## 3. 单机 dry-run（不占 GPU）

1. mock 调度逻辑（CPU）通过（§2.4）。
2. proto lib LD_PRELOAD 加载 OK（build 容器内 smoke test）。
3. NCCL_ALGO=2HOP 识别 OK（strings/parseList 路径）。

> 四机 GPU 真 kernel dry-run 需在窗口内一并执行（单机单 GPU 无法模拟 4 节点环网步调）。

---

## 4. 对 Archi 的一个实现说明（非阻塞，供裁审参考）

规格写「双边步 2 channel 并发（per-edge channel）」。经实现分析，NCCL 的 channel 是 4-rank 全环（thread block），跨 channel 无法合并 reduce（chunk c_r 的归约同时需要 next 与 prev 两侧数据）。因此 **per-edge 并发在单 channel 内用两个 Primitives 对象（fwd/bwd，group 0/MaxGroupWidth）实现**，物理上即「edge e / edge e-1 两连接并发」，与 P0-2 edge-parity 双 PG 同构。此为实现细节差异，功能等价；P2 调度判据（δ_hw@16K）不受影响。如需 Archi 确认此形态符合规格意图，请在裁审时一并给出。

---

## 5. 长前缀并发独立阈值建议（已定稿）

- 文档：`nccl-benchv2-long-prefix-threshold-recommendation-sre-2026-08-16.md`
- 核心：保持全局 --request-timeout 1800s；131K@C≥2 档专用 ≥1200s（推荐 1800s，实测 C6 max=305.4s）；
  131K PR 档拆独立 invocation；max-num-seqs=6 维持（无下调理由）；131K 不在 2-hop 路由范围（≤64K），
  该曲线为 ring 基线，不作为 2-hop 收益判据。

---

## 6. 窗口需求与风险

### 6.1 四机窗口需求

- 按门规格 §4：四机测试容器（2hop-s1-rank0..3，**生产镜像 anemll 挂载 proto 库**）+ 单机 dry-run；预计 **0.5-1 天**（G1+G2+G3+δ_hw@16K）。
- **生产隔离**：G3 延迟定标需生产 vLLM 停机或最低限 quiesce 网络（S1 prep §3）；pre/post 检查脚本已就绪（`s3_isolation.sh`）。
- 排期建议（规格 §4）：P1(G1) → P3(G2) 早死止损 → P5(G3) → δ_hw@16K 同窗。

### 6.2 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| run2Hop 首版 kernel 可能 hang/错算 | 中-高 | G1 在 watchdog+单机 dry-run 后跑；四机每档 BLOCK_TIMEOUT 兜底；QA checklist §2 逐项 |
| 双 Primitives 连接同步（FIFO 步计数）首测不确定 | 中 | 已按 mock 逐 op 核对连接计数；G1 即验证 |
| 生产窗口与 2-hop 测试并发 → RDMA 干扰 | 中 | pre/post 隔离 + 生产 quiesce 才跑 G3 |
| GLIBC/ABI | 低 | 生产镜像内构建，已验证 ≤2.34 可加载 |

---

## 7. 待办（本会话后）

1. ✅ 补跑完成 → 汇总 6 档数据（72/72 ok）→ v2 基线定版建议（QA 复核）。
2. ✅ 阈值建议文档定稿（§5）。
3. ⏳ team-lead 排四机窗口 → Rex 执行 `bash /opt/2hop-s1/s3/run_s3.sh all` → 回传 D1-D8 → QA 复核 → Archi 裁审。

---

## 8. 产物索引

| 产物 | 位置 |
|---|---|
| proto 库 | `<node1>:/opt/2hop-s1/proto-lib/` |
| 源码分支 | `<node1>:/opt/2hop-s1/src/nccl-2hop-proto`（`2hop-proto`） |
| S3 脚本 | `<node1>:/opt/2hop-s1/s3/`（run_s3.sh / s3_g1.py / s3_g2.py / s3_g3_ab.py / merge_g3.py / s3_isolation.sh） |
| bench 修复 | `<node1>:/opt/aicad-prod/bench_v2.py` + backup |
| 补跑数据 | `<node1>:/opt/aicad-prod/verification-logs/BENCHV2_FIX_20260816T165051Z/` |
| 本地数据副本 | `deliverables/engineering-assurance/nccl-2hop-s3-data/` |

---

*文档生成：2026-08-16（S3 第一阶段构建+修复链状态；四机执行待窗口）*
