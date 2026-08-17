# ADR-015: ring-only P2 netDev 覆盖重构——硬编码 per-peer 映射替代 PEER_HCA env 解析（R14 复验阻断后决策）

**状态:** Accepted
**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**输入:** nccl-tuner-s1-report-sre-2026-08-16（S1 插件阻断）/ 服务器 /tmp/nccl-r14-test/ 证据链 / 生产 v3 反汇编结论

---

## 背景

R14 复验失败（backup 源码 + enqueue.cc 双带补丁 + v3 升级，md5 676c9198）：
- 编译成功、override 函数与调用点均存在（sendSetup 0x161a74 / recvSetup 0x162144），但**运行时 0 条 RING-ONLY 日志**、连接失败（`ibv_modify_qp 110` 非直连对）。
- 对照组生产 v3 二进制在同样环境**完全正常**：32 条 RING-ONLY v3 日志，chan0/2/4→dev0、chan1/3/5→dev2 双 dev 轮换完美。
- 反汇编生产 v3 的 override 函数体（getenv→strncpy→strtok_r→strchr→atoi→strcmp→轮换）与 Rex 实现结构一致，但**函数体的"调用点条件"只在二进制里，v2 源码快照里不一定存在**。

**根因定性：源码漂移（source drift）。** `backup/tp4-20260812/src` 是 v2 快照；生产 v3 二进制的 net.cc 存在结构性差异（override 调用点/门控条件/旋转语义仅存在于二进制）。"从 v2 源码 + 逆向重建 v3 机制"无法可靠复现 v3 行为——R14 的 0 日志即为证据。**生产 v3 二进制是唯一已知可用的行为真相，但它的确切源码没有被保留。**

---

## 选项分析

### A. 继续逆向生产 v3 的确切调用条件
反汇编 v3 sendSetup 调用点上下文，定位 hostHash 门控差异/调用位置。
- 工作量：中（逆向 + 重建 + 验证循环，每轮半天+）；风险：**中高**——即便精确复现，新二进制仍非 v3 位等价，验证负担与 B 相同，且继续依赖 env 解析机制（脆弱点未消除）。

### B. 硬编码 per-peer netDev（推荐）
在 transport.cc（v1 环邻过滤路径）用**静态 (myRank, peerRank)→(devA, devB) 表**替代 env 解析，对环邻 peer **无条件**覆盖 netDev，保留 channel 双 dev 轮换。
- 工作量：中（表 + 旋转 + 重建 + S1 矩阵验证）；风险：**低-中**——映射表完全已知（物理拓扑 + v3 日志佐证）；**消除 hostHash 门控 + env 解析两个脆弱点**；源码受控，直接解决漂移。
- 可持续性：0.27 重编时静态表移植远易于 env 解析机制。

### C. 二进制 patch 生产 v3 加 enqueue 补丁
不可行（无符号重定位）。**排除。**

---

## 决策

**采用 B：硬编码 per-peer netDev 映射替代 PEER_HCA env 解析。** 前置一步"a-lite"逆向：反汇编 v3 sendSetup 调用点，抽取 ① 精确旋转语义（channel→dev 对）、② override 是否被门控（hostHash != 是否存在于 v3），用于保证硬编码表与 v3 已验证行为逐位一致。

理由：
1. R14 失败的根因是**机制脆弱**（env 解析 + hostHash 门控 + 调用点漂移），不是 tuner 补丁。硬编码把整个脆弱机制删掉，问题面归零。
2. 映射表已知且确定：物理环 01-02-04-03、每边端口分配由 v3 日志证实——低错误概率。
3. 部署固定为 4 节点环网（ring-only 库本就硬编码 RING），在库内硬编码拓扑与该库的定制哲学一致。
4. 源码受控后，**行为真相从"二进制"迁回"源码"**，解决漂移；未来任何 build 都以此为准。
5. enqueue.cc 双带 tuner 补丁正交，不受影响。

---

## 影响

- **变容易**：net 连接确定性；无需逐机 env 差异（NCCL_IB_PEER_HCA 从 start 脚本移除）；调试/回滚路径清晰；0.27 移植简单。
- **变困难**：拓扑表硬编码于库内——换拓扑（如 P2 交换机结构项）需同步改表（该结构项本就要重写 net.cc，影响可忽略）。
- **过程教训（必须执行）**：**保留可用源码**。本次落定后，build 树中的 transport.cc + enqueue.cc 补丁即为行为真相，提交/留档；此后**禁止**再以"backup 快照 + 逆向重建"方式出生产库。backup/tp4-20260812 标记为"历史 v2 快照，不可用于重建生产"。

---

## 实现要点（实施单）

1. **静态表**：`(myRank, peerRank) → (devA, devB)`，仅环邻对有效（v1 过滤已限定 peers 集合），非环邻不建连接。
   - rank0(01): peer1→(dev1,dev3), peer3→(dev0,dev2)
   - rank1(02): peer0→(dev1,dev3), peer2→(dev0,dev2)
   - rank2(04): peer1→(dev0,dev2), peer3→(dev1,dev3)
   - rank3(03): peer0→(dev0,dev2), peer2→(dev1,dev3)
   - （dev 编号对应 NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 的 0..3；以 a-lite 逆向确认后定稿）
2. **旋转**：even channel→devA、odd channel→devB（对齐 v3 日志 chan0/2/4→dev0、chan1/3/5→dev2）。
3. **无条件覆盖**（无 hostHash 门控）：环邻 peers 由 v1 过滤决定，无需再判断跨节点。
4. **enqueue.cc 双带补丁不动**（正交，保留当前实现）。
5. **env 清理**：start 脚本移除 `NCCL_IB_PEER_HCA`（库忽略之）；回滚脚本恢复。
6. **验证**：S1 矩阵全尺寸 + 正确性 ok + 旋转日志与 v3 的 32 条模式一致；通过后进 S2（CUDA graph + LL proxy 负载）。
7. **升级路径（兜底）**：若硬编码后 S1 仍失败 → 说明 v2→v3 存在 PEER_HCA **之外**的 net.cc 结构性差异（如 v1 环邻过滤也漂移），升级为**全量 v3 源码重建专项**（对 v3 二进制做系统化反汇编，逐函数重建 net.cc），更大工程量，届时重新评估。

---

## S1.5 复验进展（R14v4/v5，2026-08-16 追加）

**新证据**：
1. 库中已确认包含全部补丁代码（strings 见 UNCOND-DEBUG / RING-ONLY v4 / INLINE-HARDCODE，count=1）——代码确实编译进库。
2. 但运行时 0 条日志，包括放在 sendSetup 的 ncclTopoGetNetDev 之后的**无条件 WARN（INLINE-HARDCODE）**也不出现。
3. `Channel 00/0 : 3[0] -> 0[0] [receive] via NET/IB/0` 日志正常——recvSetup 路径执行了，但我们加在其中的代码未执行。
4. 连接间歇：R14v4 一次成功（仅 6 Channel，异常——正常 MAX_CH16 应为 16），一次失败（110 非直连）；R14v5 失败。

**架构判断（两层模型）**：
- NCCL net 连接是**两层**：核心层 `src/transport/net.cc` 的 `ncclNetSendSetup/ncclNetRecvSetup`（proxy 通过 transport->sendSetup/recvSetup 调用，**设备选择 ncclTopoGetNetDev → conn->netDev 在这里**）→ 插件层 `net_ib*.cc`（`ncclIbConnectImpl` 用已选设备建 QP，到此改设备已太晚）。
- `Channel ... via NET/IB/%d` 日志由**核心层**在 recvSetup 返回后打出（`%d`=conn->netDev）。日志出现 ⇒ **核心层 net transport 的 recvSetup 确实执行且设置了 netDev**。
- 因此"连接不走 sendSetup/recvSetup"的判断**不成立**；真正的问题是**运行时执行的 sendSetup/recvSetup 不是我们修改的那个副本**（build 重复符号 / 源码树多副本 / 漂移）。我们的函数编译进库（strings 可见）但不是 transport 结构体实际调用的那个。

**决策（追加）**：先做 **read-only 符号级 triage**（1-2 小时，不重编）定位"运行时真正执行的 net transport 函数"，再决定补丁落点；不做无依据的继续逆向。triage 命令见发给 team-lead 的消息。若 triage 显示运行时函数在另一文件/副本 → 把硬编码 override 移到该函数（~5 行）；若显示 v1 环邻过滤也漂移（6 Channel 异常佐证）→ 进入全量 v3 源码重建专项。

---

## S1.6 双副本实锤（2026-08-16 追加，最终判断）

**证据**（R14v5，md5 e7f942e3）：
1. netTransport 结构体（0x230be88）sendSetup=0x161d80 / recvSetup=0x1616c0——指向我们改的副本（含 override 调用，bl 0x15fb20，override 开头无条件 WARN）。
2. 运行时 UNCOND-DEBUG 0 条 + 连接 110（非直连对）。
3. 库中有第二组 sendSetup/recvSetup：0x156480/0x155f50（更小、无补丁）。
4. Channel 日志 `via NET/IB/0` 正常出现。

**最终判断（两层模型 + 双副本 = build 级漂移，不是代码放错位置）**：
- `ncclTransportP2pConnect`（transport.cc）按 path 逐 channel 选 transport：`path==PATH_NET ? ncclTransportNet : ncclTransportP2p`，Channel 日志在此路径打出（"%d"=conn->netDev，由 net transport recvSetup 设置）。日志出现 ⇒ **运行时确实走了某个 net transport 的 recvSetup 且设置了 netDev**。
- **生产 v3 运行时用"带补丁的那组"（RING-ONLY v3 日志出现）；R14v5 运行时用"无补丁的那组"（0x155f50）。** 同一库内有两个 net transport 源副本，R14v5 build 把运行时接到了无补丁副本 → 这就是备份树"源码漂移"的最终形态：**build 编译/链接了错误的那份 net transport 源**。
- 0x155f50/0x156480 **不是** net_ib 插件（插件接口是 listen/connect/accept，无 sendSetup/recvSetup 签名）；是第二份 net transport 源（疑似重构副本，如 net_common.cc，或备份树中另一路径的 net.cc）。

**决策（定稿）**：
1. **主路径：找到两份 net transport 源（E-step），把同一份自包含硬编码 override（per-peer dev 对 + channel 轮换）打进 BOTH 份**。override 自包含（入参 rank/peerRank/channel->id，静态表，不改签名），打多份安全且幂等。**无论 build 把运行时接哪份，都生效**。同时检查 Makefile：确认两份都编译、符号不冲突；若 R14v5 build 因 Makefile 选择了错误副本，修正 Makefile 到与 v3 build 一致的源集。
2. **否决 `ncclTopoGetNetDev` 作为主改点**：签名无 peerRank（无法按 peer 做映射）；核心函数被 collnet/nvls/pxn 等多路径共用，动它风险大；加参数会与"未知来源的预编译对象"产生签名错配。仅当两份源都找不到时再考虑。
3. **否决 LD_PRELOAD hook**：`ncclTopoGetNetDev` 是内部符号，同 .so 内调用是直接 PC 相对跳转（不走 PLT/GOT），LD_PRELOAD 插桩不会触发；即便导出也不可靠。
4. **对照检查**：生产 v3 二进制是否有同样的两组？若 v3 只有一组（带补丁），则 R14v5 build 引入了第二份源（备份树多出的重构副本），进一步坐实 build 级漂移；据此修正 build 输入。
5. **最终兜底**：若两份源都不可得/不可修 → 从官方 NCCL 2.30.7 源码干净重建（v1 RING-only + v3 设备映射 + enqueue.cc 双带作为一个干净 diff），以 v3 二进制运行时行为为验收基准。

---

## S1.7 最终决策：官方源码干净重建（2026-08-16 定稿）

**E-step triage 结果**：
1. 双副本 = `src/transport/coll_net.cc`（CollNet transport）的 sendSetup/recvSetup，**与 net.o 是不同 transport（CollNet vs NET），属正常结构，不是重复的 net transport**。R14v5 中 0x155f50=net 之外的另一 transport，0x1616c0（大、含补丁）=net.o。
2. net.o 补丁确认编译进库（含 UNCOND-DEBUG + INLINE-HARDCODE）。
3. Channel 日志 `via NET/IB/0` 的宿主**不在任何 recvSetup**（两副本均无该字符串引用），在更高层 transport.cc 连接建立。
4. 结论收敛：**patched recvSetup（net.o, 0x1616c0）在运行时未被执行**——尽管 netTransport 结构体指向它。排除了"coll_net 重复定义"后，唯一合理解释：**NCCL 2.30.7 的 net 连接设备分配发生在更早/另一层（graph/channel 构建期），backup 树的 sendSetup/recvSetup 不是运行时路径**（或该路径在 sendSetup/recvSetup 之前即失败）。这正是 v2 源码与 v3 二进制结构性差异的最终形态。

**决策（定稿）：从官方 NCCL 2.30.7 源码干净重建。** 团队长止损判断成立：备份树漂移已确认、运行时路径不明，继续在备份树上逆向性价比极低。

**重建方案（两阶段）**：
- **Stage A（恢复可用基线）**：官方 2.30.7 + v1 RING-only + 硬编码 per-peer 设备映射（ADR-015 核心，映射表按 v3 日志定稿）。**先不带 tuner 补丁**。验收 = 与生产 v3 二进制运行时行为逐项对比：GID 配对（01-f1↔02-f1 等）、32 条 RING-ONLY 日志模式、channel 轮换（chan0/2/4→dev0、chan1/3/5→dev2）、**channel 数（确认 16，排查 R14v4 的 6-channel 异常）**、368KB ~170µs、聚合 23.86 GB/s、正确性。
- **Stage B（tuner 补丁）**：在 Stage A 通过的干净树上加 enqueue.cc 双带，单独验证 S1（per-size LL/Simple）+ S2（CUDA graph）。**两阶段隔离**——连接层问题与 tuner 补丁问题不混判。
- **前置一步（廉价）**：全机一次搜索实际 v3 源码（git 历史/build 目录/归档）。若找到 → 直接在真 v3 源上打补丁（比重建便宜）；找不到 → 走重建。
- **Governance**：重建成功后，新源树即为权威源（git tag/提交）；备份树标记废弃；禁止"快照+逆向重建"出库。

---

## S1.8 Step 0 零补丁基线通过（2026-08-16，Stage A 开工确认）

**Step 0 数据**（官方 2.30.7 零补丁，md5 ee767433，四机测试）：
1. **Channel 建立无 110 崩溃**：官方库走 recvSetup 路径成功建立 Channel 日志（`3[0]->0[0] via NET/IB/0/1/2/3` 自由轮换，17 条），无 ibv_modify_qp 110——与备份树 R14 失败直接对照，**坐实备份树漂移是 R14 根因**。
2. 连接未真正可用（rank1 无 receive 日志、扫描 timeout）——预期：官方库无环邻过滤 + 无设备映射，v1/v3 补丁必需。
3. `ibv_query_port_speed errno 93` 为全版本既有警告，非新问题。
4. v1 diff 已提取：**仅 transport.cc 环邻过滤（46-80 行）**，与官方源唯一差异，层干净。

**结论**：官方源 recvSetup（L358）/sendSetup（L310）确为运行时路径，补丁点可行。**Stage A 开工条件满足**：官方 2.30.7 + v1（transport.cc 环邻过滤，diff 提取）+ v3 硬编码映射（net.cc L310/L358 后，S1.7 批准映射表），不带 tuner 补丁，四机验收对照 v3 二进制。

---

## S1.11（2026-08-16 16:30）：Stage B 生产上线 + 全量测试放行

**决策**：Stage B（per-size tuner，3d9cf539）上线生产，**保留运行**（Tessa 全量判读放行）。

**部署执行**：四机备份（.bak-stageB-prod-20260816）→ 部署 3d9cf539 → 移除 NCCL_PROTO=Simple（唯一 env 变更）→ worker-first 重启 → 四机 healthy + /v1/models 200 + 无 110 + 容器加载库 md5=3d9cf539 ✅

**全量测试（FULLTEST 4 档，0 错误，纯净窗口）**：
- 32K：PR 2425.04（+1.18% vs MAX_CH16）/ DE 98.57（-1.41%）/ TTFT 11.93s（-1.12%）
- 131K：PR 2199.96（-0.12%）/ DE 94.47（-5.39% 边缘，合并样本 -3.29% 未破线，判定样本方差）/ TTFT 52.58s（+0.48%）
- vs T1aM4（直接前任）：32K 三项全面改善（PR +6.73%/DE +5.03%/TTFT -5.06%）；131K PR +9.23%/DE +2.69%/TTFT -8.40%
- vs A0 原始：32K PR +14.93%/TTFT -12.32%；131K PR +21.61%/TTFT -16.80%

**结论**：🟢 放行，不触发回滚。小消息 LL 收益在 decode 侧兑现（32K DE vs T1aM4 +5.03%）。

**遗留项**：① 131K decode 低噪复测（长 completion）② 并发场景（c>1）LL 收益放大验证 ③ 双分支加固（防 NET_PLUGIN 变更静默失效）④ nccltune 遗留容器清理（已执行）

---

## S1.12（2026-08-16 17:20）：双分支加固上生产 + 遗留项闭环

**决策**：PerSizeTuner 双分支加固库 **2be94172 上生产替换 3d9cf539**（Rex 四机复验通过后批准）。

**SPCX 三场景复验**（4 机 allreduce，阈值 40960B）：
- A 基线（2be94172 无 SPCX）：PerSizeTuner 生效，368KB 174.6µs（与 3d9cf539 一致，无回归）
- B SPCX 劫持（2be94172 + stub tuner）：if 分支确认，PerSizeTuner **仍强制 LL/Simple**，368KB 227.2µs
- C 对照（3d9cf539 + stub）：PerSizeTuner **静默失效**，被带偏 LL128，368KB 619.4µs（劣化 2.7×）、1MB 872.9µs（2.8×）

**静默失效风险实证**：旧库在 SPCX tuner 存在时 per-size 控制完全失效（与 NCCL_PROTO=Simple 同类隐患）——加固消除该风险。三场景均无 110。

**生产部署**：四机备份 .bak-hardened-20260816（=3d9cf539）→ 部署 2be94172 → env 不变 → worker-first 重启 → 四机 healthy + 容器内加载库 md5=2be94172 + /health 200 + 0×110。

**遗留项闭环**：① 131K 无回归（长窗口 mean 102.17，+8.15%）② 并发放大成立（c4 agg DE +96.4%）③ 加固已上生产 ④ Tree 关闭（转 P1 2-hop）。

**后续建议**：P1 2-hop kernel（GDAKI/NVSHMEM）立项；P2 交换机拓扑；0.27 升级直接移植本基线补丁。

---

## S1.13（2026-08-17）：2-hop kernel 项目 D 收尾（归档定稿）

**决策**：**2-hop bilateral 在当前 NCCL ring 原语框架内不可行（干净证据）；项目 D 归档收尾（用户已批准），预算转投 P2 交换机 / 0.27 升级等 ROI 更清晰项。**

**依据文档**：`nccl-2hop-s3-final-adjudication-architect-2026-08-17.md`（终审裁定，技术层面）/ `nccl-2hop-s3-step12-adjudication-framework-architect-2026-08-17.md`（§7.5 A' 裁定）/ Rex A' 执行数据（lib d3fc78a4 / cfa8c14c / 9176e156）。

### 根因链完整记录（三层，由外到内）

| 层 | 根因 | 证据 | 状态 |
|---|---|---|---|
| **主根因（内层）** | **2HOP 算法未注册进 device kernel table**：`generate.py` AllReduce 算法清单缺 `"2HOP"` + `ncclDevFuncId` 的 `nAlgos=6` 直接 `row += ... * nAlgos + algo` 溢出 → 2HOP(algo=7) 索引错误 → **一直 launch 到 Reduce kernel → 垃圾值 [783.875]** | worktree 未提交 diff（generate.py + "2HOP"、device.h nAlgos 6→7 + algo1 映射）；**根因闭环证据：lib d3fc78a4（constants+device table+algo1 映射）→ 2HOP+runRing → ok=True [6.0]** | ✅ 已修复/已证 |
| 外层 | `ncclTunerConstantsDefaults`（tuning.cc:148）缺 2HOP 常量 → latency=0 → cost 退化 → 任务参数错 | NCCL_DEBUG=TUNING 表：2HOP 三协议 latency=0.0 vs RING 36.6 / PAT 5.0 | ✅ 已修（A' 阶段） |
| 结论 | **主根因 = device kernel table 未注册，比 tuning.cc 常量更内层**——常量缺失解释 cost 退化，table 未注册直接解释"launch 错 kernel"。根因闭环（6.0）证明两层修复后 plumbing 干净。 | | |

### 机制级否定（干净证据，非调度可解）

1. **form C pairwise（cfa8c14c）与 carry 变体（9176e156）两套独立 kernel 设计，在 SIMPLE 下以完全相同方式 `illegal memory access` 崩溃** → carry/temp-buffer 假设最终证伪（非 in-place send 源覆写竞态）。
2. **RING 单 Primitive 正确对照**：同环境 `NCCL_ALGO=RING` + runRing → ok=True 40.2µs；2HOP 走同一份 kernel（fallback runRing）→ 垃圾值——对照实验唯一变量 = algo 入口，证明问题在 algo 集成路径非 kernel 逻辑（后经根因链收敛为 device table）。
3. **裁定**：SIMPLE 协议下"单 thread block 双 Primitives 并发"在当前 NCCL ring 原语框架内不可行（SIMPLE FIFO/proxy 底层对齐问题，kernel 层不可解）。

### 价值区不可触及（业务/架构层面）

- 生产 tuner（stageB）：**≤32KB 路由 LL，≥48KB 路由 Simple**；G3 主判据 @16K 目标协议 = **LL**。
- 而 **LL/LL128 的 2-hop kernel 从未实例化**（`directRecvReduceCopy` 仅 SIMPLE 支持，编译期隔离）→ 当前原型**无法在目标协议上运行 2-hop**。
- **A-2（修 SIMPLE FIFO/proxy）不构成通往价值的路径**：即使修复成功，2-hop-SIMPLE 在 16K 被 auto 路由（LL）挤出 → ratio_real≈1.0，G3 不可能通过；强制 Simple 测比值则基准失真（非生产基线）。

### 选项与 EV（决策记录）

| 选项 | 内容 | 成本 | 成功率 | 到价值区？ |
|---|---|---|---|---|
| **D（采纳）** | 归档 + RING 基线 G1-G3 定版收尾 | ≈0 | 100% | 否（干净否定已成立） |
| A-2 | 修 SIMPLE FIFO/proxy | 2-5 人日 | 40-60% | **否**（SIMPLE≠16K 目标协议）——不建议独立走 |
| **旧 A（唯一续接点，条件触发）** | 新 sendrecv 原语（发 X 收 Y），覆盖 LL/LL128+SIMPLE | 5-10 人日 | 40-60% | **是**（唯一可达） |

**遗留决策点**：旧 A 为唯一续接点，业务属性决策——若用户后续愿押 3-8% TPOT 收益，可立项（硬门：LL 16K 正确性首要验收 + 预算上限 ≤10 人日 + 退出分支失败→立即 D）；否则永久关闭。本裁定为其技术基线。

### 附带生产问题记录（同期确认，非 2-hop 范围）

1. **bench_v2 60s 读超时工具 bug 已修复**：`/opt/aicad-prod/bench_v2.py` md5 `f72e9e84...`（`min(timeout,60)` → `timeout` + ReadTimeout 分类），备份 `.bak-60s-fix-20260816`；FIX 补跑 6 档 72/72 ok → v2 基线 v1.0 定版（32/32 档）。
2. **4.5ms 平坦 = proto 库缺 tuner，非生产问题**：tuner 移植后 proto RING 1K-64K 回 42.8-244µs（µs 级）；生产 2be94172 未受影响（md5 未变）。
3. **测试容器 LD_PRELOAD 兼容性限制**：测试库必须带 `libnccl.so.2` 符号链接，否则 fallback 系统库导致全部测试无效（已写入操作规范）；LD_PRELOAD 仅在测试容器生效，不进生产。

### 影响

- **变容易**：2-hop 线彻底归档（防未来重复踩坑）；RING 基线（生产 2be94172）定版收尾；预算转投 P2 交换机 / 0.27 升级。
- **变困难**：2-hop 结构性结论记录为 INCONCLUSIVE-with-negative-evidence（非 impossibility），旧 A 续接需重新评估业务价值。
- **归档执行**：源码分支/补丁/失败复现（2hop-failures）/全部报告/终审裁定/本 ADR 入 `nccl-2hop-proto-archive-20260817/`；生产隔离记录 + 回滚确认（生产库 md5 2be94172 未变）。

---

## S1.14（2026-08-17）：B1 通道数固化（MAX_NCHANNELS 16→4）

**决策**：**NCCL_MAX_NCHANNELS 16→4 固化生产（B1 窗口 A/B 胜出，2026-08-17 18:5x 生效）。** 四机启动脚本 head L116 + worker L121 已改，集群以 B1 配置运行 healthy。

**背景**：R13/Stage B 基线为 MAX_CH16（368KB 173µs 依赖 16 通道大带宽）；B1 假设「368KB/16ch=23KB 分片 Simple 延迟不友好」→ 降低通道数换取更大分片、更优延迟。A/B 窗口（B0-B4）在 4-rank 环网 nccl-tests 与端到端双档验证。

### 数据（nccl-tests 4-rank 环网，avg µs，in-place）

| 消息 | B0 (16ch) | **B1 (4ch)** | B2 (8ch) | B3 (LL128) | B4 (4ch+QPS) |
|---|---|---|---|---|---|
| 14KB (decode 主) | 41.3 | **43.2** | 41.7 | 51.9 ❌ | 41.0 |
| 28KB | 47.5 | **47.3** | 49.3 | 56.2 ❌ | 47.6 |
| 56KB | 66.4 | **69.6** | 65.5 | 65.2 | 67.7 |
| 112KB | 126.3 | **83.2** ✅ | 129.6 | 86.0 | 95.8 |
| 224KB | 160.0 | **86.1** ✅ | 92.3 | 140.5 ❌ | 94.1 |

**收益**：112KB **-34%**（126→83µs）、224KB **-46%**（160→86µs）；14KB +2µs（噪声带，decode 侧不可见）。

### 端到端验证（生产镜像 + B1 重启后实测）

| 档 | B1 实测 | 基线对照（FINALBASE v1.0） | 判定 |
|---|---|---|---|
| c1@131072 coding | PR 2180.75 / DE 104.07 / TTFT 52.4s | PR ~2200 / DE ~100 / TTFT ~52s | ✅ DE +4%，PR/TTFT 持平 |
| c1@32768 coding | PR 2387.91 / DE 96.83 / TTFT 11.93s | PR ~2420 / DE ~99 / TTFT ~12s | ✅ 噪声带内 |

**14KB 微劣化不可见的原因**：decode 每 step 61 次串行小 allreduce，4ch 下单次延迟增量被通道竞争减少抵消（DE 反而 +4%@131K）。

### 机制

- **368KB/16ch=23KB 分片 Simple 延迟不友好**（分片小 → 传输步数多 → 端到端延迟高）；**4ch 分片更大（92KB）→ 每片传输效率更高、延迟更优**。
- **14KB LL 不受影响**：≤40KB 由 per-size tuner 强制 LL（与通道数无关）；B1 下 14KB 仍走 LL 路由。
- 库 2be94172 未变（ring-only + v4 硬编码映射 + Stage B tuner + hardened 双分支），**唯一变更 = NCCL_MAX_NCHANNELS env**。

### 关闭项（窗口结论）

- **B3（LL128）**：14KB 比 LL 差 26%、224KB 比 Simple/B1 差 63% → 该区间 LL128 无适用点，**P2 关闭**。
- **B4（QPS=2+SPLIT）**：14KB 边际 ~2µs 不抵 112/224KB 劣化（+10/+8µs）→ 大消息场景 **P4 关闭**。
- **B2（8ch）**：112KB 129µs 异常不稳定 → 淘汰。
- **B5（tuner 阈值 96K）未跑**：B1 已达判定门槛（<150µs 目标超额完成：224KB 86µs），无需叠加。

### 兼容性

与既有基线全兼容（库未变，仅 env 变更）：
- v1 环邻过滤 / v4 硬编码 per-peer 映射 / Stage B per-size tuner / hardened 双分支 / libncclpin shim 均不受影响。
- **待实测确认后补录**：tuner 路由 14KB→LL、112KB→Simple+4ch、368KB 外推 120-130µs、healthcheck/四机收敛、端到端。

### 回滚

还原 `.bak-ncclB1`（start_tp4_head.sh.bak-ncclB1 @01 + start_tp4_worker.sh.bak-ncclB1 @02/03/04）+ `start_tp4_cluster.sh`（~8min）即回 MAX_CH16。集群 B1 配置启动收敛 ~6min、health 200、四机容器 healthy。

### 影响

- **变容易**：大消息（prefill 通信段 112-224KB）延迟显著下降（-34%/-46%）；decode 侧通道竞争减少；B3/B4 决策一次性关闭，未来不再重跑。
- **变困难**：14KB 小消息微劣化（+2µs，端到端不可见，需在后续实验中继续观察）；Grafana 面板若有 16ch 注释需同步为 4ch。
