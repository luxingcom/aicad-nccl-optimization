# 遗留问题详表 — 目标 / 背景 / 验收标准

> 每项含：为什么做（目标）、现在是什么状态（背景）、怎么算完成（验收）。
>
> **命名约定（2026-09-04 起，避免混淆）**：
> - **baked-v6 测试镜像** = registry `...TP4-Ring-baked-v6`（原镜像+st 库 8d6d2de8+SKIP_TREE），已裁决不晋升
> - **NCCL ringonly V5 模块** = 按尺寸路由的 NCCL 定制模块（小消息→ar2，大消息→NCCL ring），本轮正式创建
> - 严禁裸用 "V5/V6" 指代
> 优先级：P0=V5 主线必做；P1=质量/收益加固；P2=观察项。

---

## #1 [P0] V5：ar2 按尺寸路由接入 NCCL tuner —— ✅ 已完成（2026-09-04 E2E 窗口，见 E2E-REPORT-20260904.md）

**结案形态**：不采用 tuner plugin，改为 `ncclAllReduce` 入口 hook 分发（libnccl `ac2525a0` + libar2 `7c59b387`）。
交付：条件①~⑧分发（bf16/就地/nRanks=4/16≤B≤crossover/对齐/group/捕获守卫/**fence-arm 锁存**）+ 优雅降级。
E2E 验证：四端 armed、health=200、双臂 A/B 持平（PR -0.11% / DE +0.78% 中位）——持平的根因是
**结构性可达人口 ≈ 0**（decode 通信在 graph 重放内不经 hook），非 ar2 性能问题；后续路线见 #10。
crossover 实测定界 8192B（≤8KB ar2 领先 9~43%，微基准表见 E2E 报告 §5）。

**目标**：让生产 vLLM 的 allreduce 在 ≤交叉点尺寸自动走 ar2（1KB 档实测 -25%），大消息继续走 NCCL ring。
这是整个 2HOP 复活项目的最终交付形态：ar2 不再是独立探针，而是生产通信路径的一部分。

**背景**：
- S1/SIRCL（窗口 2）证明收益区 ≤16-32KB：4KB p50 21.2µs vs NCCL 31.4µs（+33%）；
  ar2 M1 复现并稳定：1KB 21.1µs（-25%）、4KB 26.0µs（-17%）、16KB 持平、≥64KB 反而被 ring 反超
  （单 QP 串行带宽塌陷——2 轮全交换每 rank 流量 2S vs ring 的 2S(N-1)/N，且我们单 QP 无多通道）。
- 现役 NCCL 的按尺寸选择机制 = hardened 树内置 `ncclPersizeTunerOverride`
  （`NCCL_TUNER_THRESHOLD=40960`：≤40KB→LL、>→Simple）；SPCX 敌对 tuner 已验证 per-size 覆盖加固生效（窗口 2 C 臂）。
- `ar2_recommended(bytes)`（include/ar2.h）已预留路由接口：crossover 默认 32768，env `AR2_CROSSOVER_B` 可调。
- **未做**：tuner plugin 侧调用 ar2 的胶水（NCCL communicator 生命周期 ↔ ar2_comm 生命周期映射、
  rank/设备几何注入、错误冒泡到 vLLM）、新镜像烘焙（v7）、E2E 基准。

**涉及**：`src/`（ar2 侧无需大改）、hardened NCCL 树（`/opt/aicad-prod/backup/nccl-official-2307-hardened-20260816/`）
tuner 路径、baked 镜像构建链（W2 报告有完整流程与三个坑）。

**验收标准**：
0. **交叉点须实测修正**：默认 32768 偏高——W3 实测 16KB ar2 45.5µs vs NCCL 38.8µs（落后 17%），4KB 领先 17%；V5 应在 1K-16K 间扫描定界（初判 8-12KB），再定 AR2_CROSSOVER_B
1. tuner 在交叉点两侧实测路由正确（NCCL_DEBUG 日志可见 per-size 决策）
2. 四机 PR/DE 整套基准全绿且 decode 档（小消息主导）TTFT/吞吐不劣于 baked-v6 测试镜像基线
3. kill 测试在生产形态通过（ar2 错误能终止推理循环而非挂死）
4. 回滚路径：镜像回退 + env 关 ar2 路由（`AR2_CROSSOVER_B=0`）双保险

**预估**：3-5 人日（胶水 1-2、镜像与四机验证 1-2、E2E 基准 1）。

---

## #2 [已裁决·关闭] baked-v6 测试镜像不纳入正式版本（2026-09-04 用户裁决）

**裁决**：baked-v6（全名=测试镜像 `192.0.2.187:5000/vllm/vllm-openai:LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring-baked-v6`，
digest 62670d69）现有状态**没有任何优势**（稳态 AR 回归中性），不纳入正式版本。
其验证资产（两轮 PR/DE 全绿、冷启动根因结论、镜像构建流程）保留作为 NCCL ringonly V5 的工艺输入。
SKIP_TREE_CONNECT 的收益由 V5 模块按需继承。

<details><summary>原始评估记录（留档）</summary>

**目标**：生产切到 baked-v6 测试镜像（st 库 8d6d2de8 默认化 + `NCCL_SKIP_TREE_CONNECT=1`），
获得"冷启动首跑直快"（消除 8989µs 慢速路径）与 netdev 加固，无性能回归。

**背景**：
- 窗口 2 定谳：冷启动慢速路径根因 = Tree/PAT 对非环邻居建连超时；SKIP_TREE 直接消除。
- baked-v6 测试镜像经两轮完整生产形态验证（W2 首轮 + W3 复跑）：health=200、四机 md5/env/autotune 落位、
  NCCL 零 ibv 超时、PR 20/20 + DE 12/12 全绿。
- 当前生产仍为原镜像（8c7a5df9，W3 收尾已按交接单恢复并验证）；该测试镜像在 registry 与四机本地均在位。
- 唯一未做：切换动作本身（四机 `docker tag baked-v6 <R5>` + 服务重启）与切换后一周生产观察
  （确认 NCCL init 慢/快交替现象消失）。

**验收标准**：切换后 health=200、连续 7 天无冷启动慢路径日志、PR/DE 抽测不劣于基线；
回滚 = 四机 retag 原镜像（内容级 md5 核对）。

---

## #3 [P1] layer(M2) 模式小尺寸复测与 enqueue 摊销量化

**目标**：量化 M2 graph 模式的真实收益区，为 V5 路由决策（单 op vs 整层）提供依据。

**背景**：
- W3 实测 12KB×8 op：graph 38.7µs/op ≈ 串行 36.1µs/op——**该尺寸 kernel 数据搬运占主导**，
  enqueue 摊销收益被掩盖（W2 SIRCL graph submit 实测 3.6µs/次，说明 host 侧确有可摊销空间）。
- 解码期实际几何更小（TP4 广播/归约常在 1-8KB 段），该段 layer 尚未系统测过。
- 当前 probe 层模式固定尺寸列表，需要 1K/2K/4K × NOPS=8 的矩阵 + NO_GRAPH 对照。

**验收标准**：1-4KB 段 graph 相对串行有可重复的 ≥10% per-op 收益，或出结论"该平台 enqueue
不构成瓶颈、V5 只需单 op 路由"——两者任一都收口此问题。

**预估**：0.5 天（probe 已具备全部开关，纯实验）。

---

## #4 [P1] 生产集成形态设计与错误冒泡

**目标**：定义 ar2 在 vLLM 进程内的失败语义（与 ERROR-MODEL 对齐），确保通信故障表现为
"快速失败 + 可观测"，而非挂死或静默损坏。

**背景**：
- ar2 现行两层错误语义（可恢复 / poison 后必须 finalize）在探针环境已验证（kill 测试 6s 干净回收）。
- 但 vLLM 侧的对接未设计：NCCL tuner 插件调用 ar2 返回 TIMEOUT/PROTOCOL 后，如何映射到
  vLLM 的 engine abort/重启链路；日志与 AR2_DUMP 取证如何接入 vllm-logdump 取证链。
- FATAL(-9, 保留码; 当前库无产生路径, 见 ERROR-MODEL §1) 的进程终止路径在生产容器里由谁执行（vLLM 的 crash handler vs 直接 abort）。

**验收标准**：设计文档一份（并入 V5 工作）；生产形态 kill 测试（杀 1 worker）表现为
head 探活失败 → 服务层重启，全程无 >timeout 的挂死。

**预估**：1 人日（随 V5 胶水一起做）。

---

## #5 [P1] 代码卫生小项（审计已识别，见 AUDIT-REPORT）

**目标**：消除审计发现的低危不一致。

清单：
以下各项**已在审计修复轮处理**（详见 AUDIT-REPORT 修复清单）：kernel 发布前缺 __syncthreads（F1）、
CPU 后端 arena 泄漏、门铃 u32 回绕比较、fill_peer_info gid 硬编码、capture 失败 graph.valid 残留、
poisoned 写序、EINTR/设备表释放/accept 超时/对齐校验/probe 守卫/selftest RSS、dev_err obs 打印清理、
sent_seq 注明诊断遗留。**遗留待办**：审计修复后的四机 GPU 复跑（下个停机窗口，先本机 selftest 已过）。

**验收标准**：逐项修复或注明保留理由；四机回归 m1+layer 各一轮全绿。

---

## #6 [P2] nslots>2 深流水线探索

**目标**：评估 4 槽能否进一步隐藏引擎 posting 延迟（更大重叠窗口）。

**背景**：nslots=2 的槽复用安全性已完整论证（ARCHITECTURE §7）；4 槽会把"覆盖 vs DMA 读"的
因果链放松一档（m 与 m+4 同槽），安全论证需重做但难度不高；收益未知——若 enqueue 不是瓶颈
（#3 若得出该结论）则不必做。

**验收标准**：#3 结论为"enqueue 有收益"时再做；4 槽 12KB/1KB 对照 2 槽有 ≥5% 收益才保留。

---

## #7 [P2] 单 comm / 单流 / 单线程假设的生产化约束确认

**目标**：确认 vLLM 集成场景不违反 ar2 的三个隐含假设。

**背景**：ar2 假设 ①每进程一个 ar2_comm（一个 collective 组）②数据面单线程调用
③自有非阻塞 CUDA stream。vLLM TP4 每 worker 恰好一个 rank、vLLM 的 NCCL 调用在 worker
主循环线程——假设成立；但若未来 EP/DP 引入多通信域（窗口 2 A2A 结论的后续），需要 comm 多实例化
（TCP 端口/QP/arena 均已参数化，理论可并行，未测试）。

**验收标准**：V5 集成时在真实进程里确认三点各有一条日志/断言证据；多实例化暂不做。

---

## #8 [P2] 基准空白：ar2 未进任何 vLLM E2E 数字 —— ✅ 已完成（2026-09-04）

**结案**：同窗配对 A/B 已补齐（V5 armed vs AR2_V5=0，PR 20 档 + DE 12 档全绿）：
PR prefill 中位 -0.11% / DE decode 中位 +0.78% = 持平。数据 `results/ab-summary-20260904.txt` +
`results/benchv2-v5on|v5off/`。持平机理定谳见 E2E-REPORT §6。

**目标**：V5 后补齐 ar2 生效态的 PR/DE 基线，与 baked-v6 测试镜像 基线（本包已含）对照出 E2E 收益。

**背景**：W3 的 PR/DE 全绿跑在 baked-v6 测试镜像上，而该镜像 **不含 ar2**——它验证的是 skip-tree+st 库栈。
ar2 的 E2E 收益（预期集中在 decode TTFT/吞吐）尚无数字；这是 V5 验收（#1）的一部分，
单独列出避免"已有全绿基准"被误读为"ar2 已有 E2E 验证"。

**验收标准**：NCCL ringonly V5 模块镜像上 PR/DE 与 baked-v6 测试镜像基线同参数对照，decode 档差异表格化落盘。

---

## #9 [P2] 文档与代码的同步维护纪律

**目标**：文档不过期。

**背景**：本套文档（ARCHITECTURE/PROTOCOL/ALGORITHMS 等）与 2026-09-03 W3 版代码逐条对齐
（行号、字段、数值均以当日代码/日志为准）。后续任何协议字/布局/默认值变更必须同步改
对应文档小节 + PITFALLS 增条目——W3 的教训（校验器与文档滞后会制造数天级调查成本）直接适用。

**验收标准**：每次合入改协议/布局的 PR 必须含对应 docs/ diff；无 docs diff 的此类 PR 拒收。

---

## #10 [P0] 捕获期集成：ar2 进 CUDA graph（V5 收益落地的唯一路线）

**目标**：把 ≤8KB 小 AR 的 ar2 加速（微基准 -9~-43%）真正吃到生产 decode 步上。

**背景**（2026-09-04 E2E 定谳，E2E-REPORT §6）：生产 decode 的 TP 通信全部在 CUDA graph
重放内执行，不经 `ncclAllReduce` C 入口（满载 2.5h 零 progress 报点，<65536 op vs 理论 ~5.8M）；
prefill AR 全为 >crossover 大尺寸。⇒ NCCL-hook 型集成在此形态收益 ≈ 0，与 ar2 性能无关。
ar2 已有 M2 `ar2_capture_layer`（图固化 + replay 时 CPU 补发 WR）——vLLM 需在 cudagraph
捕获处为每层小 AR 集合显式调用捕获 API，replay 路径替换原生 NCCL 节点。属 vLLM patch 级工程
（fork 的 speculator/目标图捕获点均在 `vllm/v1/worker/gpu/`），工作量≈一个独立窗口。

**可行性判定（2026-09-04 完成，全文见 INTEGRATION-ROADMAP.md）**：≤8KB 图内人群仅 164 op ≈ 4-5 op/步
→ 单独实施收益 <0.3%（低于 ±2% 噪声带）——**暂缓实施（NO-GO for now）**。
改为三步走：R1 小 op 按图归属细分取证（半天）→ R2 Route D dspark-only 原型（仅当 R1 归属 dspark，
验收 = WR 补发时序证明 + DE ≥2%）→ R3 ar2 多 QP 大尺寸带宽工程（独立线，128-512KB 人群 1702 op 才是数量级杠杆）。
**验收（最终）**：捕获期集成 decode 步小 AR 走 ar2 replay + DE 基准收益 ≥ 噪声带（≥2%）。

## #11 [P2] ar2 运行态可观测接口

**目标**：长跑精确计数（dispatched/failed/armed 状态）无需进程退出可读。

**背景**：atexit 计数在 vLLM worker 被 SIGKILL 时不打印（E2E 实测）；每 65536 op 的
progress 报点粒度太粗（本窗口只能给出 <65k 上界）。

**验收**：信号（如 SIGUSR1）或 /proc/sysfs 风格接口 dump 计数器；wtest 与 E2E 各一次验证。
