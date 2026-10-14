# 四机无交换机环网上的大模型推理集合通信优化
## ——pynccl RoCEnante + b12x comm 树 + ring-only NCCL + mesh 数据面：技术研究分析报告

**报告日期**：2026-10-02
**覆盖窗口**：2026-09-02（2HOP 资产盘点）～ 2026-10-01（新基座 C1 全路由终谳）
**产线归宿**：DeepSeek-V4.1-Flash @ 4×DGX Spark（GB10/SM121）TP4，0.2.9 线终态 = `dsv41-sglang-optimized:0.2.9-ep1q2-fin2` + env `c4f13f93`（开源发布包 `~/release/0.2.9-ep1q2-fin2`，tag `v0.2.9-fin2@342e1ebd`）
**性质**：全量只读梳理。全部数字带一手出处（doc 编号 / window 产物 / 记忆锚），勘误后的口径优先（见 §0.3）。

---

# 0. 摘要

## 0.1 一句话结论

在一套**没有任何交换机、纯 8 条 DAC 直连构成物理环**的 4×GB10 集群上，我们把 DeepSeek-V4.1-Flash TP4 解码步墙从 **52.87ms 压到 42.3–42.6ms**，其中集合通信面贡献了最大单项：通过「**mesh 数据面（邻居 CX7 硬件里合成对角路径）→ ring-only NCCL 2.30.7（环序硬编码+按秩锁口）→ RoCEnante 用户态单边核（pynccl 直挂、≤2MiB 选择性路由）→ b12x comm 树（双变体单键切换）**」四层体系，通信桶从 **10.77ms/步（占步墙 20%、与计算零重叠）** 降到 **5.2–5.9ms/步（在役口径；census 桶 6.732ms 中 73% 由用户态核承担）**，GPU busy 率从 116% 抬到 121–123%——通信首次获得了与计算的重叠。单点收益锚：E1 切换日 census 步墙 **−13.2%**、DE① 吞吐 **+13~15%**（prose 55.14→63.2 t/s）。

## 0.2 六条可迁移的研究结论

1. **零重叠是可以被"证明"而不只是被怀疑的**——`NCCL 并集时间 = 全部 busy − 非 NCCL busy`（658.8ms = 658.8ms，逐位相等）加上 AR 核 `grid=[2,1,1]/block=288` 仅 2 个 CTA 的形状证据，把"换通信栈"从直觉变成定案（doc35 §3.1）。
2. **无交换机环上也能跑"写全员"的单边集合通信**——one-shot AR/AG 需要全连接，而物理环没有对角线；用邻居 ConnectX-7 的硬件 hairpin（RDMA-TX marker 打标 + tc flower 0x88b5 `skip_sw` 改向）合成对角路径，无 CPU/内核转发。代价：对角比直连贵 ~1.5µs（9.99–10.18µs vs 8.47µs），且 hairpin 队列深度成为硬顶（1024 丢包 → 8192 后 480KB 内零丢包）。
3. **按尺寸选择性路由是甜点，全路由是陷阱**——≤2MiB 交给 RoCEnante、大消息回落残余 NCCL ring，是收益峰（cap 1M 判负 C8、gather 1M 判负 C29、AR 2M 转正 c16 +4.5%）；而把**所有** AR 都路由给 RoCEnante（新基座 A2d/C1 实验）则全面判负：c1 −43%、PR −54%、投机接受长度 3.25→2.7 崩塌，损伤双通道 = 自旋等等待烧 CPU/宿主串行 + bf16 归约序漂移在精确接受阈值下翻边缘 token（102 任务书 C1 终谳）。
4. **CUDA 图重放会绕过 API 层钩子，也会给库内核加税**——2HOP/ar2 三代 E2E 全负的根因不是协议慢（微基准最快 20.5µs@1KB），而是生产解码通信**全部**活在图重放里（2.5h 满载经 ncclAllReduce 入口的分发 <65536 次 vs 理论 ~5.8M）；且图内 NCCL AR 比 eager 慢 1.3–2.2×（"图税"）。任何想在这类引擎上换通信路径的人，必须走**捕获期集成**（RoCEnante 的 `roce_capture` 正是这么做的），而不是入口 hook。
5. **宿主态引擎永远打不过内核级重叠**——GI-A 三代（host 驱动层链 → 异步引擎 → 算子感知折叠）微基准一路赢（P4 融合层 33.72µs/op，比图内 NCCL 快 69%），E2E 一路负（最好 −2.96%、最差 −81%）。结构性原因：融合内核的内核内流水在"算子与 AR 交错"的真实图里天然拿不到。
6. **fabric 的"运行态"不会自己活过重启**——断电 GID 洞（modify_qp errno 61）、hairpin `devlink reload` 重置 trust 导致 tc 拒装、marker 规则被 reinit 抹掉而 `systemctl start` 对运行单元 no-op、QoS trust pcp/dscp 交错静默降级 prio0、镜像缺库时 LD_PRELOAD fail-open 静默回退 2.28.3——这五类全部真实发生过，最终以 `fabricctl` F00–F10 22 项断言 + 幂等 heal + 判别力自检收编为治理套件（doc85）。

## 0.3 口径与勘误声明（引用数字前必读）

- **步墙锚**：fin2 实际步墙 **42.3–42.6ms**（勘误记忆 dsv41-errata-batch 第 5 条；"41–42"是 doc77 预期值）。
- **AR cap**：cap512→**2M 已转正**（9ead2582，c16 聚合 +4.5%）；引用"cap512 判负"须带此勘误。
- **per=tok/s 不是 ms/tok**（DE 口径历史勘误）。
- **单机靴 NCCL 桶 = 0**：绝对步墙严禁与四机 fin2 对账（差额下界 6.7ms ≈ 16%，A10 §3.3）。
- **census 引数必须带世代**：桶构成从 ep1h（10.77ms 全 NCCL）→ ep1j（RoCEnante ~5.2ms）→ fin2（6.732ms 三分量）演化了三代。
- 社区 qeval / sparkDash / 我方 sd_bench / de_aligned 是**不同量具**，跨量具数字不可直比。
- **tag 哈希勘误**：`v0.2.9-fin2` 指向 commit `342e1ebd`（部署仓口径；发布 bundle 内重写史 tag = `a0edbf59`、HEAD/4dgx-ring = `598616c3`）。头部早先写 `4e1ace8` 是 tag 父提交（pre-W1 snapshot），已勘误。
- **家族账占比分母**：§1.2 占比（19.5%/17.7%/15.0%/9.2%）的分母为 kernel 墙口径（反推 ≈60.3ms），非表题步墙 52.87ms（`9.04/52.87=17.1%` ≠ 表内 15.0%）。
- **通信桶双口径**：census 桶（W25a 三分量）6.732ms 与「在役口径」5.2–5.9ms（doc72 §102）并存；**73% 用户态核 = (3.127+1.834)/6.732，仅对 census 桶成立**，勿挂到在役口径。

---

# 1. 背景与问题定义

## 1.1 平台与负载

| 项 | 值 |
|---|---|
| 机器 | 4 × NVIDIA DGX Spark（GB10 SoC，Grace CPU + Blackwell GPU 统一内存 121–128G，SM121/120 系，无 tcgen05） |
| 网卡 | 每机 4 × ConnectX-7 200G RoCE（rocep1s0f0/f1、roceP2p1s0f0/f1），共 16 口 |
| 布线 | **无交换机**。8 条 DAC 直连构成物理环 `01—02—04—03—01`，每邻对 2×200G、独立 /30 或 /24 子网 |
| 模型 | DeepSeek-V4.1-Flash（H=5120，40 层，384 专家 TP 均分，**无 EP 无 alltoall**，dspark k=5+nextn3，Engram 磁盘映射 2 层） |
| 并行 | TP4 跨四机，每层 2 次 AR（wo_b + fused MoE down_proj）= **80 AR/解码步**；draft 5tk≈50KB、verify 6tk≈60KB 消息 |
| 关键平台事实 | UMA 设备内存不进 RSS/cgroup；**peermem 永久不可用**（GB10 一致性内存平台 EINVAL 拒插，gpu-direct 判死）；单机整模型装不下 ⇒ 四机是硬形态 |

## 1.2 通信为什么成为主瓶颈：一次 Amdahl 翻转

早期（v7 时代，c8 206–232 t/s）判决"LL128 判负 / 8ch 无效应 / 通信占比 <4% 不可判"。当计算面被 MoE b12x 化、dense mxfp8 化逐项压掉之后，这个判决**过期**了：

- 外部交换机对照（2026-09-19，doc：V41-RING-NETWORK-INVESTIGATION-20260919）：同一 v18 镜像在星型交换机拓扑上 PR-v3 = 中位 **1.548×** 本地基线（长档 ≥8192 中位 **2.01×**）；外部 C1 边际完美线性 146→171µs/tok，我方 8192 处超线性 166→356µs/tok。
- 归因排除：外部跑的是**同一个** ring-only 2.30.7（start.sh 无条件 LD_PRELOAD）⇒ 内核无罪；布线满配（GID3 实测 8 线全 200G，每跳 50GB/s raw，环 algbw 天花板 33GB/s 与交换机同级）⇒ "交换机多带宽"假说死。
- 我方实测有效 algbw **14.3GB/s** = 名义天花板 43%，但 = 修正天花板（每方向 1×200G ⇒ 16.7GB/s）的 **~86%**——**接近物理极限，天花板比 2:1 ↔ 外部 2.011 吻合**。
- 提炼为纪律：**"占比<X% 不可判"类判决，在对立面性能变化 >1.5× 时自动过期**（主计划 §5.6 判决过期条款）。

到 ep1h 世代（2026-09-25 检查点），census 步墙 52.87ms 的家族账里通信已是第三大族（占比分母为 kernel 墙口径 ≈60.3ms，非步墙，见 §0.3）：

| 族 | ms/步 | 占比 |
|---|---:|---:|
| MoE（b12x_next 两相+silu） | 11.80 | 19.5% |
| dense b12x 族 | 10.66 | 17.7% |
| **nccl.AR（AllReduce_Sum_bf16_RING_LL）** | **9.04** | **15.0%** |
| elementwise(tiny)（3151 次） | 5.55 | 9.2% |
| 第二 MoE 族 | 5.45 | — |
| l2pf | 2.29 | — |
| wo_a | 1.89 | — |
| **nccl.AG（AllGather_RING_LL）** | **1.73** | — |
| lm_head / hc | 1.57 / 1.50 | — |

## 1.3 零重叠的实测证明（换栈的合法性依据）

不是推断，是两条独立证据：

1. **时间恒等式**：trace 里 `NCCL 并集 = 658.8ms` 与 `全部 busy − 非 NCCL busy = 658.8ms` **精确相等** ⇒ 每个 NCCL 窗口里 SM 与 DRAM 全部空转（doc35 §3.1；adapter/l2_prefetch.py:11 同注）。
2. **形状证据**：AR 核 `grid=[2,1,1]/block=288`——**只有 2 个 CTA**，在 114 SM 的 GPU 上占用率可忽略。

通信桶 10.77ms/步是"纯墙钟"，不与任何计算重叠。这既是换通信栈的理由，也是 L2 预取（§3.5）的立足点：那 ~9–12ms 的 AR 窗口（ep1h 世代 9.04ms；更早世代实测 88 次 × 139.6µs = 12.28ms，占步墙 18.6%）本来就是白送的旁路流窗口。

## 1.4 物理约束：为什么"环"是唯一形态

交换机与 mesh **物理互斥**（同一批 DAC 口）——要么全直连环，要么拆线接交换机，只能时序先后。四机环没有对角链路：rank0 与 rank2（对角）之间的任何报文都必须经 rank1 或 rank3 的网卡转发。这对两类协议是两种命运：

- **环算法（NCCL RING）**：本来就只跟邻居说话，无对角需求——但它做 AR 要 2(N−1) 步流水，小消息延迟被协议拍数支配；
- **one-shot 单边核（RoCEnante"写全员"）**：每个 rank 直接 RDMA WRITE 到所有 3 个 peer——**需要全连接**，环上原本跑不通。

整个 mesh 数据面（§2.3）就是为了把第二条路在物理环上变成可能。

---

# 2. 硬件拓扑与数据面基座

## 2.1 物理环与编址（黄金态 topology.json，四机 md5 161118bf）

```
        10.100.136/137 段                10.100.140/141 段
   01 (head,.186) ═════════ 02 (.187)      01 ═════════ 03 (.188)
   rank0                rank1              rank0          rank3
     ║                    ║                  ║              ║
   10.20.0.8/30 ┐        ┌ 10.100.138/139 段
   10.20.0.12/30┘        └───────┐
   04 (.189) ════════════════════┘
   rank2 ══════ 03（10.100.138/139 段）
```

- 精确邻对：01↔02 = 10.100.136/137、01↔03 = 10.100.140/141、03↔04 = 10.100.138/139、02↔04 = 10.20.0.8 + 10.20.0.12（/30 直连双链）。
- **rank 序 = 01(r0)→02(r1)→04(r2)→03(r3)**，即 NCCL 环序与物理环序一致（环上两跳即可对角）。
- **GID 表四机不对称 = 设计态**：02/04 的部分口走 /30 直连段，与 topology.json 逐条互证（doc92:54 勘误早有定谳）。
- MTU 9000（F07）、每口 200000Mb/s Link yes（16 口全绿）、RoCE GID index=3 硬钉（`NCCL_IB_GID_INDEX_FORCE=3`）。
- NFS：01→03、02→04 导出模型权重（03/04 的 dsv41-net 挂载是四机窗 P0 前置，§8.2）。

## 2.2 fabric 的"三层身份"

1. **内核可见层**：/32 对角路由 + ip_forward + 邻居表（对角 L2 可达性靠 ARP，不是靠交换机）。
2. **NIC 硬件层**：hairpin 队列深度（`devlink param hairpin_queue_size=8192`，driverinit 级，重启回 1024 ⇒ 必须服务化回填）、QoS trust 模式（pcp vs dscp）。
3. **CX7 转发层**：tc flower 硬件流表（`protocol 0x88B5`，`in_hw` 卸载，pref 49159/49165）+ RDMA-TX marker 规则。

## 2.3 mesh 数据面：在邻居的 CX7 里合成对角路径

**机制**（源自 FujitsuPolycom/sparkring `cx7_hairpin_diagonal`，社区提交 0f211a5，我方四机部署为 `dsv41-mesh.service`）：

1. 每机两条 **RDMA-TX marker** 规则给"对角节点"的 QP 包重新打标（0x88b5）；
2. 邻居口上一条 **`skip_sw` tc flower 规则**（硬件卸载）把包还原并改向到对角口；
3. **无 CPU 转发、无内核转发**（`IpForwDatagrams` 不变为证）。

**配套**：`scripts/ring_mesh/`（inventory → 读布线 → planner → 写 per-node 路由/规则/marker + boot unit）。planner 内嵌防呆：`plan.py:72-84` 断言"一子网恰两口"（在交换机拓扑上误跑 mesh 计划会 SystemExit）；`:87-137` 从布线推导环序物理图；`_path_config.py:20-25,145-164` 固化对角 4 条 canonical 路径。

**实测代价**：对角路径延迟 9.99–10.18µs（4 条路径）vs 直连邻居 8.47µs（社区同机实测，图内 AR 100 次 replay 口径；降级标注：社区转录非我方工件，doc88 §G）。

**服务化**（四机 `/etc/systemd/system/dsv41-mesh.service` + `dsv41-mesh-marker@.service`×2/机）：`ExecStartPre = hairpin.sh → qos.sh → mesh-up.sh`（**次序是 9-27 修复后的正确序**，见 §5.3）。marker 设备对按节点路由差异化 = 设计态，与 topology.json `markers` 字段四机逐机吻合。

**能力边界**：hairpin 只转 0x88b5 ⇒ **ping 跨 mesh 不通是正常的**（诊断口诀：对角 RTR 超时先查 `tc in_hw`+marker+GID+路由四件套，不要先猜网络不通，doc85 §四）。

## 2.4 治理套件：fabricctl（F00–F10）

十类 2026-09 真实事故 → 22 项断言的映射（doc85）：

| 检查 | 断言内容 | 对应事故 |
|---|---|---|
| F00/F01 | fabricctl 在位、黄金拓扑可加载 | 外部交付缺件 |
| F03 | marker 本靴 journalctl `attached:true` | **marker 幽灵失挂**（§5.4） |
| F04 | tc flower `in_hw` + 0x88b5 在位 | mesh 竞态（§5.3） |
| F05 | 每口 gid3 = 期望 IPv4 | 断电 GID 洞（§5.2） |
| F06/F08 | /32 路由逐条、ip_forward | 路由部分丢失 |
| F07 | 四口 MTU9000 + carrier | 链路态回退 |
| F09 | 邻居 lladdr 非 FAILED/INCOMPLETE | 对角 L2 黑洞 |
| F10 | 03/04 权重 NFS findmnt | NFS 重启即空 |

三层接线：`start.sh serve` fabric 门（红 → `fabricctl heal` → 复验仍红**拒起**）；`deploy_preflight.py` F01 系远程跑 `check --json`；`fabricctl selftest` 五类坏输入必因正确理由红（判别力自检，防"检查器不红"与"抓不住"同形）。验收记录：2026-09-28 四机 check 全 PASS、selftest 零 MISSED。

---

# 3. 四层通讯栈架构

## 3.1 总览

```
┌────────────────────────────────────────────────────────────────┐
│ 应用层：SGLang fork (0.2.9-ep1q2-fin2)                          │
│   pynccl.py (490行) ── SGLANG_ROCE_ALLREDUCE=1                 │
│     ├─ DSV41_ROCE_RING=1 ⇒ import b12x.comm.roce_ring          │
│     │   (环形态: 经 mesh 对角路径)          ┐                    │
│     │   (交换机形态: b12x.comm.roce, 全HCA条带)├─ 单键切换       │
│     ├─ AllReduce.from_exchange_group(...) → RoceOneshotLaunch  │
│     ├─ roce_gather.py → RoceAllGatherLaunch (≤512K)            │
│     └─ roce_capture: CUDA 图捕获期集成（RoCEnante 进图）          │
│   l2_prefetch.py: 骑在 AR/AG 窗口上的旁路预取流                   │
├────────────────────────────────────────────────────────────────┤
│ 库层：/opt/nccl-ringonly/libnccl.so.2.30.7 (ring-only 补丁族)    │
│   v1-ring-only + v4-netdev-hardcode(环序硬编码) + stageB×2      │
│   tuner: ≤40KB(TUNER_THRESHOLD=40960)→LL, >40KB→Simple         │
│   NCCL_IB_PEER_HCA 按秩锁口; LD_PRELOAD=/opt/libncclpin.so      │
│   职责: >2MiB 大消息 AR、NCCL 探针、兜底路径                       │
├────────────────────────────────────────────────────────────────┤
│ 内核层：RoCE verbs (GID idx3, MTU9000, 单边 RDMA WRITE)          │
├────────────────────────────────────────────────────────────────┤
│ 数据面：dsv41-mesh.service                                      │
│   hairpin 8192 → qos(pcp) → tc flower 0x88b5 in_hw → marker    │
│   对角路径 = 邻居 CX7 硬件转发; /32 路由; GID 管理                 │
└────────────────────────────────────────────────────────────────┘
```

**职责划分的经济学**：小/中消息（≤2MiB，覆盖解码全部 AR 与 gather）走 RoCEnante 单边核（延迟低、可进图、可与计算重叠）；大消息（>2MiB，prefill 场景）回落 ring-only NCCL（带宽型、2(N−1) 流水摊薄）；mesh 只为前者提供全连接性。

## 3.2 Layer 1：ring-only NCCL 2.30.7 + ncclpin

- **血统**：`nccl-official-2307-hardened` 树（git 0dd44cd）+ 四补丁：v1-ring-only（P2P 层过滤环邻）、v4-netdev-hardcode（**本布线的精确编码**：环序 01—02—04—03、每秩 PEER_HCA 映射）、stageB×2（glibc 修复）。
- **载入**：`start.sh:943-944` 生产臂恒设 `LD_LIBRARY_PATH=/opt/nccl-ringonly` + `LD_PRELOAD=/opt/libncclpin.so /opt/nccl-ringonly/libnccl.so.2`；ncclpin shim 负责核绑/内存 pin。
- **三套 NCCL 并存**：2.28.3（系统）/ 2.29.7（torch 2.13.0+cu130 绑定）/ 2.30.7（ring-only 烘入）。版本断言 = boot banner `nccl==2.30.7` + deep_ep `check_nccl_so` 单一性（新基座上发现 libncclpin 文件名撞 `'libnccl'` 子串断言 ⇒ 改挂 `/opt/ncclpin.so`，doc92 v3′）。
- **tuner 活代码**：`topoGetAlgoInfo` 只扫表取 min ⇒ >40KB 走 Simple；vLLM 时代"RING_LL 大消息错配"是另一套栈旧账，不随迁（源码级定谳）。
- **为什么 stock NCCL 在本 fabric 不可用**：mesh tc 只为环拓扑路径放行 + 跨 HCA 任意配对无路 + stock 不认 `NCCL_IB_PEER_HCA`。新基座 U1 实测三连：v1 四 HCA 全串+stock → `ibv_modify_qp 110 RTR 超时`全落跨 HCA 配对；v2 单 HCA → 02 的 rocep1s0f0 GID 全在 10.20.0.x 段 ⇒ ncclCommInitRank 崩；**v3 全套复用 fabric 资产（ring-only+PEER_HCA+逐键 env）→ 立通**（nccl==2.30.7，Init parallel 7.69s）。结论：**mesh 上的任何引擎都必须整套复用 fabric 资产，"纯 stock NCCL 在本 fabric = 结构性 N/A"**（doc92 U1 迭代记录）。

## 3.3 Layer 2：RoCEnante 用户态核（pynccl 直挂）

**代码形态**（fork pynccl.py 490 行 vs main 423 行；差块 = `:153-190`，切点 `:164`）：

- `SGLANG_ROCE_ALLREDUCE=1` ⇒ `importlib.import_module("b12x.comm.roce_ring" if DSV41_ROCE_RING else "b12x.comm.roce")`；
- `self.roce = AllReduce.from_exchange_group(...)`（GID3 交换、QP 建立、memalign 缓冲池）；
- `_should_roce(bytes)` 尺寸路由：≤ `SGLANG_ROCE_MAX_SIZE` 走单边核，否则回落 pynccl/NCCL；
- `roce_capture`：**捕获期集成**——CUDA 图捕获时把 RoCEnante 核录进图（这是它与 2HOP 入口 hook 路线命运分岔的关键，§4.1/§5.8）。

**核族**（census 可见名）：`RoceOneshotLaunch`（单边 AR：本 rank 直接 RDMA WRITE 归约份到 3 个 peer 的接收槽，各 rank 自取合并）、`RoceAllGatherLaunch`（gather 同构）；底层即 `ri32gmemalign / i32gmemalign`（对齐拷贝核）。

**武装横幅**（四机起服必查）：
```
RoCEnante ready: world=4 hcas=×4 gid_index=3 max_size=262144   [E1 世代]
DSV41_L2_PREFETCH: RoCE collectives
```
（max_size 随世代上调至 2MiB，见 §4.5。）

## 3.4 Layer 3：b12x comm 树与单键切点

- 镜像内 `/opt/b12x/b12x/comm/`（b12x 1.3.0）**双变体并存**：`roce`（交换机形态：全 HCA 条带）与 `roce_ring`（环形态：读 `B12X_ROCE_HCA` / `B12X_ROCE_PEER_HCA_MAPS` per-rank peer map）；另有 `pcie` 与 `b12x_next`（MoE 主力算子树，兼 comm 载体）。
- **切点 = 单键** `DSV41_ROCE_RING=1`（pynccl.py:162-164 选包）。交换机切换 runbook（doc58）：①env 删 `DSV41_ROCE_RING=1` + 删 `B12X_ROCE_PEER_HCA_MAPS` / `B12X_ROCE_TWO_WAVE_THRESHOLD_BYTES`；②宿主撤 mesh 三件（/32 路由 + tc hairpin + marker，`dsv41-mesh.service` stop+disable）；③重编址后 GID 洞审计。**数据面零开发**——两种形态的 .so 都已在镜像。
- 验收线（交换机形态）：busbw **≥14.3GB/s** 且对 mesh **≥1.5×**（旧判决兑现线）；物理互斥（同批 DAC 口）。
- 两波调度（TWO_WAVE）键在册但 **=0 未开**（doc91）；社区测过"不丢包后无用"。

## 3.5 骑乘件：L2 预取（把通信窗口变成预取窗口）

- **机制**：解码侧在每次 RoCE AR/AG 期间用旁路流把**后续权重的前 6MB** 预取进 L2（`DSV41_L2_PREFETCH`，默认关、import 期读门=重启臂、构造性 bit-identical）。
- **移植史（值得记录的工程教训）**：社区把钩子挂在他们 RoCE one-shot 上；我方 09-25 先把钩子**重定向到 NCCL 集合通信入口**（"This stack runs NCCL, not RoCE"），随后 E1 切 RoCE 后钩子自然回到 RoCE 面。两个落点机制事实：①`communicator.py:24-28` 的 from-import 别名 ⇒ 必须**同时打 communication_op 与 communicator 两个模块**（否则热路径完全无效）；②sitecustomize finder 白名单的隐式 `else` 兜底会被新模块撞出 AttributeError 起服即崩（改显式 elif）。
- **量化**：社区 c1 步 −1ms / prose +3.7%；我方 E1 后 l2pf busy 2.29→3.48ms（预取窗口随通信面变化**变宽**——通信重叠加深后可藏的预取更多），fin2 世代 3.300ms/步。新基座上落点漂移（communicator 包化）⇒ 必须 install 计数断言防静默丢钩（§8.2 R-F）。

## 3.6 生产 env 卡（fin2，`.env.tp4` md5 c4f13f93，:49-87）

| 键群 | 键 | 消费者 |
|---|---|---|
| NCCL 通用（:49-67） | `NCCL_SOCKET_IFNAME` / `NCCL_IB_HCA`(4口) / `NCCL_NET`(none 插件禁用) / `NCCL_P2P_DISABLE=1` / `NCCL_SHM_DISABLE=1` / `NCCL_BUFFSIZE`(8M) / `NCCL_MAX_NCHANNELS=4` / `NCCL_CROSS_NIC` / `NCCL_IB_MERGE_NICS` / `NCCL_SUBNET_AWARE_ROUTING` / `NCCL_IB_GID_INDEX_FORCE=3` / `NCCL_IB_TOS=46` | NCCL 进程 env（前提=ring-only 库在） |
| EXTRA_DOCKER_ENV（:87） | `NCCL_ALGO=RING`、`NCCL_PROTO=LL,LL128,Simple`、`NCCL_TUNER_THRESHOLD=40960` | 同上 |
| RoCE 面（:87） | `DSV41_ROCE_RING=1` / `SGLANG_ROCE_ALLREDUCE=1` / `SGLANG_ROCE_MAX_SIZE=2097152` / `DSV41_ROCE_GATHER=524288` / `B12X_ROCE_HCA` / `B12X_ROCE_PEER_HCA_MAPS` / `B12X_ROCE_TWO_WAVE_THRESHOLD_BYTES` | fork pynccl.py:164 + /opt/b12x |
| 挂载臂（:61） | `NCCL_HOST_DIR=/opt/nccl-ringonly` | start.sh（宿主件四机在位） |
| 死信 | `PEER_HCA_RANK0-3`（:74-77） | 已被 ring-only 2.30.7 库内硬编码映射取代（env:71 勘误自认，清理项） |

---

# 4. 优化全过程与定量结果

## 4.0 时间线总览

| 阶段 | 日期 | 事件 | 产线归宿 |
|---|---|---|---|
| ① 前史：2HOP/ar2 三代 | 09-02~09-06 | SIRCL→ar2→V5→GI-A/GIA2/GIA3；微基准屡胜、E2E 三代全负，封存 | 负结果遗产（§5.8） |
| ② 环效率定谳 | 09-19~09-20 | 外部交换机 1.548× 对照、14.3GB/s=修正天花板 86%、Amdahl 翻转 | 判决过期条款 |
| ③ l2pf 移植 | 09-25 | 零重叠证明 → 钩子重定向 NCCL → 烘制事故 → ep1g Part 2 落地 | 在役 |
| ④ **E1 RoCEnante 切换** | 09-26 | 步墙 −13.2%、t/s +13~15%、busy 116→121-123% | 在役 |
| ⑤ 调参与上限定界 | 09-26~09-29 | cap/gather/AR 上限三臂、E3 b12x_next 升级 −2.6% | AR 2M 转正 |
| ⑥ fin2 终态切产 | 09-29 | tp4 双键+hc_fused+split 并入，桶 6.732ms，切产+开源发布 | **生产终态** |
| ⑦ 治理收编 | 09-27~09-28 | mesh 竞态修复、fabricctl 套件、topology.json 黄金态 | 在役 |
| ⑧ 新基座边界实验 | 10-01 | C1/A2d 全路由 RoCE AR 终谳判负 | 技术边界定谳 |

## 4.1 前史：2HOP/ar2 三代（2026-09-02 ~ 09-06，负结果遗产）

**目标**：自研两轮邻居全交换协议（ar2：SparkRing rank^1→rank^3 两轮、每轮单边、两轮换 NIC），替换小消息 NCCL AR。

**微基准战绩**（全部四机实测）：

- M1：1KB **20.5µs**（vs NCCL 28.3，−28%）/ 4KB 24.9（−21%）/ 16K 持平 / 64K 落后——胜带 ≤16KB；
- SIRCL（2 轮 GPU 真实内存语义）：4KB p50 21.2µs vs NCCL 31.4（**+33%**）；≥64K 单 QP 串行带宽塌陷（256KB 慢 4.5×）；
- P1 大消息改造后：1M 1439→**362µs**（3.98×），胜带 ≤8KB 扩到 ~40-48KB；
- P4 融合层内核（split@4 双轨 + nblk=4）：生产尺寸 114688B **33.72µs/op** vs 图内 NCCL 109.54（−69%）vs eager 72.41（−53%），含 262144 反超——"≥256K 还 NCCL"旧结论被推翻。

**E2E 三连败**（同窗配对 A/B）：

| 代 | 形态 | E2E 结果 | 结构性根因 |
|---|---|---|---|
| V5 hook | ncclAllReduce 入口分发（crossover 8192） | PR −0.11% / DE +0.78% **持平** | 生产 decode 通信**全在 CUDA graph 重放内**，不经入口（2.5h 分发 <65536 op vs 理论 5.8M）；prefill AR 全 >crossover |
| GIA2 | ar2 图内录制 + host 异步驱动 | DE **+13.73% 回归** | 逐 op nops=1 层链 vs 图内 NCCL 内核级重叠；host 串行 drive ~3.5ms/重放 |
| GIA3 | 算子感知折叠（MHC post 折入 AR 终相） | DE **−81%**（post 开）/ −31%（底座） | post 折叠使 dspark 接受率 0.9 vs 3.7 tok/draft；内核头静态字段在真实图被逐出成冷读 |

**遗产**（比收益更值钱的部分）：

1. **图税发现**：图内 NCCL AR 比 eager 慢 1.3–2.2×（4KB 73.8 vs 32.1µs）——图重放本身给库内核加税；
2. **捕获期集成是唯一可达路径**：RoCEnante 的 `roce_capture` 正是吸取此教训的实现；
3. 协议工程知识（P0-P4 全谱：单在飞串行 vs 流水线、多 block 到达计数器、背压 K=nslots/8、~3ms 非确定停顿=轻载下 NIC/链路状态机退出延迟假说+CPU 未绑核实证、GB10 peermem 永久禁用、mapped 轮询协议共通暴露面）；
4. 三臂 E2E 编排范式（实验/同镜像关/同窗基线）——分离"折叠效果"与"底座回归"的关键设计。

## 4.2 环效率定谳与外部对照（09-19 ~ 09-20）

见 §1.2。三个数字定义了"环值不值得继续优化"：

- **1.548×**（外部交换机 vs 我方环，同镜像同库）——fabric 主导的差距上界；第三方 A 站复现 1.56-1.58、B 站（环+自编译 ring-only）≈ 我方 ×1.08，三角互证"代码不缺、fabric 是主变量"（doc：V41-THIRDPARTY-CROSS-ANALYSIS-20260920）；
- **14.3GB/s / 16.7GB/s = 86%**——环上 ring 算法已近物理极限，**纯调参无油水**，升级必须换数据通路；
- **35-51%**——v18 提速后长档"非计算项"占墙钟比例，通信治理的收益上界。

这条定谳直接孕育了两个后续：l2pf（把白送的窗口用掉）与 E1（换数据通路）。

## 4.3 l2pf：零重叠红利的第一次兑现（09-25）

前提=§1.3 的零重叠证明。社区数字（他们的栈）：c1 步 −1ms、prose +3.7%、varied +3%、c8 +2%、c16 flat。我方落地因一次**单变量纪律事故**延宕（ep1b 镜像 `COPY adapter` 覆盖脏树静默携带未提交移植 → 判违规 → ep1c 起逐文件 COPY+md5 钉死 → 被排除），最终经 `Dockerfile.epN` 通道（FROM 上一代 ep 镜像，绕开 bake-kit"派生底座不可叠烘"阻塞）在 ep1g Part 2 落地：patcher 哈希锚定接线 + gate 七项门含两条反向用例。自检 22 项全绿 + 3 组反向用例（改坏预算红 3 项、删护栏红 3 项、并集红 6 项无交互）。

## 4.4 E1：RoCEnante 切换（2026-09-26，核心战役，doc48）

**武装形态**：`0.2.9-ep1j v2`（content_id b9d159d4ef515231 四机对齐）+ `.env.tp4-ep1j-roce-20260926`（md5 5e341117，六 RoCE 键尾插，定板键零触碰）+ mesh 四机 ACTIVE + trust=pcp×16 口 + hairpin 8192。锚 = ep1h-stack-20260925。

**判据与结果（全部 PASS）**：

| 判据 | 锚（ep1h） | E1（ep1j v2，多靴） | Δ |
|---|---|---|---|
| census 步墙 | 52.87ms | 45.21–46.58（W15b 均值 45.85） | **−13.2%** |
| DE② prose/code/structured（ms/步） | — | — | **−11.6~−12.6%** |
| DE① t/s（prose/code/structured） | 55.14 / 96.10 / 115.36 | 63.2 / 108.7 / 132.0 | **+13~15%** |
| nccl.AR + AG（榜上） | 9.04 + 1.73 = 10.77ms | **从榜上消失** | — |
| 接管者（用户态核） | — | ri32gmemalign 3.34 + i32gmemalign 1.86 ≈ 5.2ms | 通信面 **−52%** |
| GPU busy | 116% | **121–123%** | 重叠加深 |
| l2pf busy | 2.29ms | 3.48ms | 窗口变宽 |
| QA | — | code-gate 12/12 + needle/corruption/termination | 全绿 |

**质量火墙**：归约序变化 ⇒ 贪婪文本与 NCCL 态逐位不可比（RL 折叠判决同款语义，QA 通过即接受）。

**夜内三事故**（全部当夜定谳，E1 判词 §1 附卷）：①门 C 假 NO-GO（判据读到旧 env）；②锚 b2 污染 + **NCCL 环塌**（§5.1）；③ep1j v1 烘制陷阱（§5.5）。

**E3 顺带升级**（09-26 04:41，doc48 §7）：b12x_next 0102f5cb→e9ec61d（恰 4 件 diff），census 再 **−2.6%**（45.04 vs 同窗锚 46.23），DE 电池级持平，DETERMINISTIC 键解锁——同谱系超集，随 E1 一起转正（载体 ep1k，cid f8702b3f95287a4e，gate 79 项）。

## 4.5 调参与上限定界（09-26 ~ 09-29）

**消息上限三臂**（ring 上的"选择性路由"边界）：

| 参数 | 臂 | 判定 | 依据 |
|---|---|---|---|
| `SGLANG_ROCE_MAX_SIZE` | 512K / 1M / 2M | **2M 转正**（9ead2582）：cap512 +5.8% → 2M c16 聚合 **+4.5%**；1M 判负（C8） | 2MiB=G4 峰值，ring 上无再上调空间；hairpin 8192 硬顶下更大报文回落 NCCL（doc77） |
| `DSV41_ROCE_GATHER` | 512K / 1M | **512K 在役**；1M 判负（C29） | 1M 臂出现 AR 总量 4760→6466ms 事件，回 512K 即愈（doc90:37） |
| hairpin queue | 1024 / 8192 | **8192**（服务化自动回填） | 1024 时 >100KB 消息丢包（100K 档 163 次 `rx_out_of_buffer`）；8192 下 480KB 内零丢包 ⇒ 消息 cap 提到 256KB |

（hairpin/IDLE_SPINS 两项为社区同代实测、我方同构采纳的硬件/模块参数；社区 `ROCE_IDLE_SPINS` 200000→20000000 使 c1 步 40.6→37.1ms——200000 时 27% 的 c1 decode 采样落在 `clock_nanosleep`。）

**图内 AR 延迟标尺**（社区量、4 rank 过 mesh、40 次/图、100 replay，hairpin 8192）：60K:24µs / 80K:30 / 120K:40 / 240K:60 / 360K:78 / 480K:95 / 720K:217 / 960K:274。⇒ 2M 以内 RoCEnante 延迟曲线平滑，720K 起 hairpin 对角代价显性化——与 cap 定界自洽。

## 4.6 fin2 终态与切产（09-29）

- **形态**：`0.2.9-ep1q2-fin2` + env `c4f13f93`（tp4 双键 + HC_FUSED=1 + chunk4096 并入；RoCE 六键全在）。回退链 `05b74b2a → 9798b5e9 → 20563e93`。
- **通信桶终态**（doc88 §F，W25a a1-b1，30 步、5381.3 发射/步、kernel 墙 56.36ms）：

| 分量 | 次/步 | ms/步 | 占桶 |
|---|---:|---:|---:|
| RoceOneshotLaunch（单边 AR） | 87.0 | **3.127** | 46% |
| RoceAllGatherLaunch（gather） | 47.4 | **1.834** | 27% |
| ncclDevKernel AR RING_LL（>2M 残余） | 2.8 | **1.570** | 23% |
| 散件 | ~1.4 | ~0.2 | 4% |
| **桶计** | **138.6** | **6.732** | = kernel 墙 11.9% |

  即：**桶的 73% 是 RoCEnante 用户态核，27% 才是"同库同 fabric 可 1.00 携带"的残余**。在役口径通信 5.2–5.9ms（doc72 §102）。
- **终锚**：PR rep 4k/32k/128k/256k = 3392/3637/3899/3809 t/s；PR 262k = 160.0s（T2/W-FIN 终局，129.3s 单靴彩票不入锚）；DE prose c1 ≈ 70.4–71.2 t/s（prose 55.14 → E1 63.2 → **70+** 的完整爬升线）；步墙 42.3–42.6ms。
- 2026-09-30 开源发布包：`~/release/0.2.9-ep1q2-fin2`（14G 镜像 tar + bundle + 四文档）。

## 4.7 新基座 C1/A2d：全路由的技术边界（10-01）

LuZ-0.3.0（main-79cafec0）新线上，A2d 实验把**全部** AR 路由给 RoCEnante（threshold=1.0），以 A0S′（当前栈 SPEC=1 锚，接受长度 3.25、prose 50.44/code 85.16）为对照：

- 五档 DE 深负：**c1 −43% / c8 −30% / c16 −22%**；
- **PR −42~−55%**（4k 档 1000 vs 2162 t/s）——大消息全路由 = 最强损伤证据；
- 接受长度 **3.25 → 2.7 崩塌**；质量全带内（GSM8K 0.965 / ds_gate 四 PASS）= 纯性能损。

**损伤双通道机理**（102 任务书 C1 终谳）：

1. **传输税通道**：census 内核账是绿的（AR 面 −2ms/步），但 E2E 红——首嫌 spin-wait 等待烧 CPU 与宿主串行（大消息全路由下最重）；
2. **归约序通道**：bf16 AR 归约序漂移在 threshold=1.0 精确接受下翻边缘 token ⇒ 拒收膨胀（KL 0.002 级带内但对精确接受致命）。

**复活三条件**（工程级，非键位可解）：事件驱动 spin（替代自旋等待）/ 大消息排除（保持选择性路由）/ 接受阈值 <1.0。⇒ 与 fin2 的选择性路由形态互为印证：**RoCEnante 的正确位置是"小中消息 + 进图 + 可重叠"，不是"全部通信"**。

## 4.8 收益总表（旧线全程）

| 指标 | ep1h 基线（09-25） | fin2 终态（09-29） | Δ |
|---|---:|---:|---:|
| census 步墙 | 52.87ms | 42.3–42.6ms | **≈ −20%** |
| 其中通信桶 | 10.77ms（全 NCCL，零重叠） | 5.2–5.9ms 在役口径（census 桶 6.732ms，73% 用户态核） | −45~−52% |
| GPU busy | 116% | 121–123% | 通信获得重叠 |
| DE prose c1 t/s | 55.14 | 70.4–71.2 | **+28%**（通信贡献 +13~15%，其余为 tp4/hc_fused/E3 等并链） |
| PR 262k | — | 160.0s（rep 3809 t/s） | 终锚 |
| 回退链 | — | 05b74b2a → 9798b5e9 → 20563e93 | 三级 |

---

# 5. 失败案例机理分析（研究价值密度最高的部分）

## 5.1 NCCL 环塌（W15 锚 b2 污染，09-26 夜）

**现象**：E1 当夜锚靴 b2 里 `nccl.AR` 飙到 **1246ms/步（占 76%）**、单次 15–28ms（正常 103µs）。若混入均值会把 E1 判词整个带歪。
**处置**：单靴隔离 + 以多靴中位定谳；b2 作废留档。
**教训**：换栈实验夜必须**逐靴核 census 族表形状**，不能只看均值；"锚被污染"与"技术回归"在均值上同形。

## 5.2 断电 GID 洞（09-21 定谳）

**机理**：整机断电/硬重启后接口初始化乱序 ⇒ rdma_cm GID 表出**索引洞**（v2-IPv4 落 idx4、idx3 空）。全集群硬钉 `NCCL_IB_GID_INDEX=3` ⇒ 洞口 `modify_qp RTR` 必挂 errno 61（`local GID ::`）。洞不一定全机一致（02 四口+03 两口，01/04 净）。
**修法**：IP 环回（`ip addr del` 后立刻 add 同地址 → GID 表紧凑重建）；兜底 = 四机**整体**切 GID=2，**勿单机改**（集群 index 必须一致）。
**防线**：`start.sh fabric_gid_preflight`（起栈前 5 秒断言四机每口 idx3）+ s4_bench 自审 + 修复 runbook。
**A10 复核（09-29）**：四机 16/16 无洞——历史未复发。

## 5.3 mesh 单元次序竞态（09-27 定谳，RoCE 全断的真身）

**链条**：开机口本为 pcp → `hairpin.sh` 的 `devlink reload driver_reinit`（1024→8192，每次 ~4s）**把 trust 重置回 dscp** → `mesh-up.sh` 装 tc 被拒（"only PCP trust state supported for hairpin"）→ 单元 failed ⇒ tc 全空 ⇒ `ibv_modify_qp(RTR) Connection timed out` 全 rank。**表象是"重启后 RoCE 全断"，ICMP 却通**——ping 通 ≠ fabric 活。
**修复**：qos.sh 移到 hairpin.sh 之后（单元 ExecStartPre 次序对调）；四机部署+daemon-reload。
**诊断要诀**：RoCE RTR 超时 + ping 通 ⇒ 先 `systemctl status dsv41-mesh`，再看 `tc filter show`（空=hairpin 没装）——不要先猜 GID/IP/qos（本次三者全正常，白查两轮）。

## 5.4 marker 幽灵失挂（09-28，doc85 事故 #2）

**机理**：devlink reinit 抹 HCA 流规则；`systemctl start` 对**运行中**单元 no-op 不重挂 ⇒ 单元显示 active 但规则已死 ⇒ 对角 QP RTR 超时、rank 单点死循环。
**修复**：mesh-up/plan.py `start→restart` 语义 + **F03 本靴 journalctl `attached:true` 断言**（"单元 active 但规则死"必红）。这是"检查器必须带判别力"的范本：没有 F03 之前，active 状态与真实挂载是同形绿灯。

## 5.5 烘制静默空转（ep1j v1，09-26 夜）

**机理**：RoCE overlay 只进了参考拷贝 `/opt/dsv41/overlay-roce/` 未进树；`CODE_MOUNTS=0` 下**静默空转**——容器起来了、横幅没亮、没人报错。
**修复**：v2 改实拷 + `content_id` 四机对齐 + 武装横幅作为 boot 必查断言（`RoCEnante ready: world=4 hcas=×4...`）。
**一般化**：**armed ≠ 有效果**。env 键设了不等于有读者，文件存在不等于进了树——每个武装动作都需要一个"正向横幅 + 负向拒红"的判别对（此判据后来在 A10 审计里抓出 main 镜像三处空转/惰性，§8.2）。

## 5.6 QoS trust 交错（交换机切换的最大静默坑，doc58）

ring 期 `qos.sh` 把口翻 **pcp**（hairpin 前置：CX7 hairpin 只支持 PCP trust）；NCCL 无损依赖 `NCCL_IB_TOS=46` + trust=**dscp**→prio5。交换机形态下必须回 dscp 且交换机配套 QoS——**不一致 = 静默降级 prio0**，无告警、只丢吞吐。同族：hairpin 只转 0x88b5 ⇒ 普通 ICMP 不通是设计态（§2.3）。

## 5.7 fail-open 家族（迁移面的隐形悬崖）

| 形态 | 后果 | 对策 |
|---|---|---|
| main 镜像无 `/opt/nccl-ringonly` + LD_PRELOAD | 动态加载器告警后**静默回退系统 2.28.3**，丢核绑 | 终烘盖写 pip 路径 + deep_ep `check_nccl_so` 单一性断言 + banner `nccl==2.30.7` |
| `DSV41_ROCE_RING=1` 在 main（pynccl 无读者、b12x 不在） | **结构性空转**（env 在、机制全无） | census 桶形状判据（§8.2 判据 4） |
| roce_gather 依赖 `self.roce`（main 永不设置） | 惰性无告警 | install 计数断言 |
| l2pf 双模块补丁在 communicator 包化后落点漂移 | 静默丢钩=预取窗缺失 | t 系 install 计数断言（两命名空间） |

**通则**：库缺失类故障的默认方向是 fail-open（降级继续跑），必须用**断言把它翻转成 fail-closed**（拒起/报红）。

## 5.8 2HOP 三代 E2E 全负的三条结构性定律

1. **图重放绕过 API 钩子**：入口 hook 类集成在图重放占比高的引擎上可达面 ≈ 0（<65536 vs 5.8M）。
2. **图税存在**：图内库内核比 eager 慢 1.3–2.2×——评估"进图"方案时须先量税再算赢面。
3. **宿主驱动打不过内核级重叠**：微基准冠军（P4 33.72µs/op）在真实图里拿不到，因为真实图算子与 AR 交错，融合内核的流水前提不成立。**通信优化的收益兑现位置必须在"图内 + 内核级"，host 侧驱动/折叠两代已证死。**

---

# 6. 社区与外部对照

## 6.1 knapcio（同硬件兄弟分支，RoCEnante 的先发者）

- 其环网 RoCE（`DSV41_ROCE_RING` + sparkring `cx7_hairpin_diagonal`）自标 **research-only、默认关**；我方经 A/B 判据转正为生产（这是两侧最重要的路线差）。
- 其实测（同日同环一次一变量）：NCCL→RoCEnante decode 步 **−5.2%**（51 个 ≥64 token 任务里 50 个更快）、qeval 中位 76.34→79.53；+v2 栈 81.81/84.74/85.93；`ROCE_IDLE_SPINS` 200000→20000000 使 c1 步 40.6→37.1ms（27% 采样在 `clock_nanosleep`）；hairpin 1024→8192（丢包证据同 §4.5）。
- 代码级对账（doc35 §2 逐文件 md5）：`moe_b12x_next.py` 等四件逐字节同版；其 l2_prefetch 挂 RoCE、我方 09-25 时挂 NCCL（同一机制两个挂点）；我方缺 `roce_gather`（后来补上）。
- 诚实边界：其 qeval 75 任务 c1 夹具与我方 gates_suite/needle 不同源，数字不可互换；其步内榜世代（c1 31.2–32.5ms）与我方 43.2 的差距主因在**步内开销工程与发射密度**（2700 vs 5381 发射/步），不在通信面（其 census NCCL 0 行 = 同样全 RoCEnante 化）。

## 6.2 mia（MiaAI-Lab，环网性能标杆）

- 同口径差距 **100% 在步墙**：43.2 vs 35.2/35.7ms（Δ≈7.5–8ms），接受长度我方 2.98 vs 其 2.87 反超（吞吐=接受÷墙闭合检验通过）。
- 其步内桶：MoE 14.7 / other 13.8 / bf16 10.0 / **NCCL 0** / hc 3.3 / attn 1.5——**通信面同样零 NCCL**（RoCEnante 化是本生态共同终态）。
- 唯一通信面参数差：`DSV41_ROCE_GATHER` 其 2M vs 我方 512K——M=16 时 draft vocab 分片 1.03MB>512K 我方 c16 回落 NCCL、其仍走 RDMA（c16 档其享有的边际优势；我方 1M 臂判负 C29 是 E2E 综合账，两账并不矛盾：其栈无我方的 AR 事件前科）。

## 6.3 ZackO2o（反架构对照）

其 SGLang 副线 = `SGLANG_ROCE_ALLREDUCE=0` + sparkring NCCL 2.30.7 overlay——**集合通信留在打补丁的 NCCL 里**，与我方（RoCEnante AR，census nccl 0 行）相反。E1 判我方快 13%，架构不换。其 818k 上下文 3222 t/s 无悬崖（1M ctx 实跑）。可借鉴三条运维课：健康采样 NIC **carrier**（非 ib port state）；重启/插拔后 **GID index 会漂**（3→4）须重探测；健康判据 artifacts 化。负结果：我方 ring-only NCCL build 在其栈 invalid usage——**第三方环网件互不搬**。

## 6.4 第三方 A/B 站（fabric 主导性的三角验证）

- A 站（星型交换机 2 口 + **标准** NCCL 2.30.7 自动调优）：PR-v3 中位 **1.548×** 我方 v18——与我方自测外部交换机比值 ±2% 吻合；
- B 站（环直连 + 站点自编译 ring-only + 锁频）：32K 稳态 ≈ 我方 ×1.08；
- 归因定谳：**fabric 主导**（"MoE 修复解释 1.548×"被三重反证否决：时间线、commit 同源镜像、B 站同修复不同 fabric）。七文件四方逐字节一致 ⇒ 我方不缺任何第三方代码。
- Amdahl 张力在案：collective 27.7% 下纯带宽 1.55× 只该兑 ~1.11-1.17×，实测 1.58 超界 ⇒ 指向停顿带也受 fabric/NCCL 栈影响——环→交换机的收益不只是带宽，还有**长档停顿的消除**（同靴内 chunk 墙钟 2.47-4.46s 波动 vs 外部完美线性）。

## 6.5 对照总结

四个外部锚把结论钉成三角：**代码同源（knapcio md5）、fabric 是主变量（A/B 站 1.548× vs 1.08×）、RoCEnante 化是共同终态（knapcio/mia census NCCL 0 行）、全路由是共同陷阱（我方 C1 终谳 = 社区 research-only 默认关的独立佐证）**。

---

# 7. 方法论沉淀

1. **零重叠/归因证明技术**：时间恒等式（NCCL union == all-busy − non-NCCL-busy）+ 核形状（CTA 数）——把"怀疑"升级为"定案"，先证瓶颈再动刀。
2. **census 族表 + 世代标签**：所有引数带世代（ep1h/ep1j/44步/W25a/fin2）；族表形状（谁从榜上消失、谁接管）比均值先说话——W15 b2 污染与 NCCL 环塌都是族表先红。
3. **同窗配对 A/B + 三臂编排**（实验/同镜像关/同窗基线）：分离"技术效果"与"底座回归"（GIA3 底座 −31% 就是第三臂抓的）。
4. **判决过期条款**：占比类判决在对立面性能变化 >1.5× 时自动过期（v7"通信不可判"→v18 Amdahl 翻转）。
5. **armed ≠ 有效果** 判别对：每个武装动作配正向横幅 + 负向拒红；检查器配"喂坏输入必因正确理由变红"的反向用例（fabricctl selftest、l2pf 三组反向用例、F03 journal 断言同宗）。
6. **fail-closed 翻转**：库/钩子缺失的默认方向是静默降级，用断言（单一性/计数/横幅）把开放故障翻成拒起故障。
7. **量具纪律**：跨量具不直比；单靴不可判；单机 vs 四机口径差先行声明（桶=0 的单机靴严禁与四机步墙对账）。
8. **窗口纪律**：换栈夜逐靴核形状；跨机二进制 rsync+md5 内容级核对；`&` 后台化不吞验证输出；实验收尾 pkill 清场（nohup 反射器不自灭）。

---

# 8. 迁移启示与资产清单（I14）

## 8.1 为什么通讯面回移是新基座四机窗的硬前置

新基座（main-79cafec0）镜像实测（A10 §2，容器内实读）：

| 差件 | fin2 价值 | main 现状 | 回移动作 |
|---|---|---|---|
| **D1** RoCEnante pynccl 构造块（~60-70 行，fork :153-190） | E1 全部收益的载体 | pynccl 423 行**零 ROCE 读者** | 整块移植，缝合 main 新版 pynccl（新增 cuda_wrapper/symm_mem 路径）；`roce_capture` 图捕获序须重验 |
| **D2** /opt/b12x 树 | comm 双变体 + MoE 主力（18.6+5.6ms/步） | **无 /opt/b12x**（find 全盘证） | bind-mount 或烘入 |
| **D3** ring-only NCCL 2.30.7 + ncclpin | fabric 稳定性 + Init 7.69s | **无**（fail-open 静默回退 2.28.3） | 终烘盖写 pip 路径 + LD_PRELOAD 同身份；ncclpin 改挂 `/opt/ncclpin.so`（deep_ep 子串断言） |
| **D4** roce_gather / l2pf 落点适配 | gather −200µs/op 级 / l2pf 3.3ms | 惰性 / 落点漂移（communicator 包化） | D1 复活 gather；l2pf 补双命名空间 install 计数断言 |
| **D5** mesh 宿主三件 | 数据面 | **零回移**（四机在位 enabled） | 只受重启事件扰动（F09/F10 窗前必查） |

**不回移的定量后果**（A10 §3/C2）：桶从 6.732ms 回升到 pre-E1 形态 **10.8ms**（ep1h 世代实测），且 **busy 121%→116%、重叠红利同步清零**——保守 +3~5ms/步、悲观 +5~7ms（E1 总收益 7.02ms 全回吐口径）= **+7~+16% 步墙**，3-8 倍于 ±2% 迁移判据带。

## 8.2 四机窗通讯面判据（A10 §4.2 定稿）

1. boot 前置门：四机 `fabricctl check` 22/22（F09 预热后、F10 挂载后）；banner `RoCEnante ready: world=4 hcas=×4 gid_index=3`（D1 回移后在 main 复现）或显式 `nccl==2.30.7` 断言。
2. nccl-tests 只读基准：busbw ≥14.3GB/s 历史验收线 + **per-link 带宽抽查**（防"mesh 残留 TX 跌 13-14Gb/s"型静默劣化——拆卸/kill 后必须 per-link 验收）。
3. 跨机延迟探针（RDMA 口径，非 ICMP）：对角 10.0-10.2µs vs 直连 8.47µs 锚。
4. **census 桶形状（主判据）**：NCCL/RoCE 桶对 fin2 6.732ms ±0.3ms、calls/步 138.6±5%；RoceOneshot/RoceAG/nccl.AR 三分量各自在带；**无 RoCEnante 路径 = 桶回 9-10.8ms 形状即红**。
5. 单机窗边界：L10 单机靴（桶=0）只做单机对单机或剔桶对账，四机窗才启用全桶对 fin2。

## 8.3 资产清单

| 类 | 资产 | 位置 |
|---|---|---|
| 镜像 | `dsv41-sglang-optimized:0.2.9-ep1q2-fin2`（+发布 tar 14G） | 四机 + `~/release/0.2.9-ep1q2-fin2` |
| env | `.env.tp4`（c4f13f93，四机 md5 一致）+ 历代臂档（9ead2582=AR2M 转正件…） | `~/dsv41-flash-dgxsparks/` |
| fabric | `fabricctl` + `topology.json`（161118bf）+ dsv41-mesh.service + marker 单元 | 仓库 `scripts/ring_mesh/` + 四机 `/opt/dsv41-mesh/` |
| 库 | ring-only libnccl 2.30.7 + ncclpin | 镜像 `/opt/nccl-ringonly` + 宿主 `/opt/aicad-prod/lib/`（四机） |
| comm 树 | /opt/b12x（comm/roce + roce_ring + b12x_next） | 镜像内；宿主副本 `/tmp/u1-assets/b12x`（25MB，四机） |
| adapter | roce_gather.py / l2_prefetch.py / l2pf.cu / sitecustomize | `~/migrate-assets/dsv41/adapter/` |
| 2HOP 封存 | sparkring-kit 全树（ringonlyV5/GIA 系，tag gia3-final）+ 归档 bundle | `~/sparkring-kit/` + `/opt/aicad-prod/backup/` |
| 判例文书 | doc48/58/35/67/77/85/86/88/92 + A10 + 本报告 | `~/LuZ-0.3.0-ARCHIVE-20260930/` |
| 交换机 runbook | doc58（切点/撤除面/QoS 陷阱/验收线） | 同上 |

## 8.4 结项后的重启条件（备档）

- **交换机形态**：数据面零开发（双变体已在镜像），单键切换；验收 busbw ≥14.3 且 ≥1.5×mesh；最大静默坑 = QoS trust 交错（§5.6）；`SGLANG_ROCE_MAX_SIZE`/`DSV41_ROCE_GATHER` 届时可重开 A/B（hairpin cap 约束消失）。
- **全路由 RoCE AR 复活**：三条件（事件驱动 spin / 大消息排除 / 接受阈值 <1.0）任一成熟再议（§4.7）。
- **2HOP 方向**：须 device 侧 doorbell / GI-B 类结构（host 侧与算子折叠两代已证不可行），重启前必读 CLOSURE §1。

---

# 9. 参考文献（一手出处索引）

- **doc48** `48-W15-W15B-E1-ROCE-VERDICT-20260926.md`——E1 全套判据与数值、E3 升级、夜内三事故
- **doc58** `58-SWITCH-FABRIC-PREP-20260927.md`——交换机切点/撤除面/QoS 陷阱/验收线/mesh 假设编码位
- **doc35** `35-COMMUNITY-RING-V2-RECONCILE-20260925.md`——knapcio RoCEnante 机制与数字、步内榜 44 步世代、零重叠证明、l2pf 定谳
- **doc77** `77-WRAPUP-RING-FINAL-MERGE-PLAN-20260928.md`——环网形态冻结、AR cap 2M=峰、busbw 14.3 验收线
- **doc85** `85-FABRIC-GOVERNANCE-KIT-20260928.md`——十事故→22 断言映射、fabricctl 三层接线
- **doc86** `86-MIA-RING-PR-DE-LATENCY-DECOMPOSITION-20260928.md`——同口径差距分解、gather 512K vs 2M
- **doc88** `88-KERNEL-LEVEL-LATENCY-DIFF-20260928.md`（W25a census）——fin2 桶三分量 6.732ms、对角/直连延迟标尺（§G）
- **doc92** `92-BASE-UPGRADE-DESIGN-CARD-20260929.md`——U1 stock NCCL 三连败与 v3 全套复用立通
- **A10** `98-L10-PREAUDIT/A10-cluster-comm.md`——四机只读盘点、fork/main 通讯差 D1-D5、桶世代演化、四机窗判据
- **102 任务书**（`~/luz030-opt-campaign`）——C1/A2d 全路由终谳、A0S′ 锚、复活三条件
- 早期：`V41-RING-NETWORK-INVESTIGATION-20260919.md`（1.548×）、`V41-PR-TOPOLOGY-RING-VS-STAR-PAPER-20260920.md`（字节模型/天花板比）、`V41-THIRDPARTY-CROSS-ANALYSIS-20260920.md`（三角验证）、`~/sparkring-kit/`（2HOP 全档，含 GIA3-PROJECT-CLOSURE-20260906）
- 记忆锚：`nccl-2hop-revival-assets`、`fabric-gid-powerloss-repair`、`dsv41-reboot-roce-mesh-unit-race-20260927`、`dsv41-l2pf-nccl-port-20260925`、`dsv41-switch-fabric-prep-20260927`、`dsv41-zacko2o-ring-lane-and-cachegib-drift-20260927`、`dsv41-ring-network-verdict`、`dsv41-thirdparty-cross-verdict`、`dsv41-errata-batch-20260929`、`dsv41-luz030-102-taskbook-20260930`

---

*报告完。数据截至 2026-10-01（C1 终谳）；若与后续新基座窗口数据冲突，以窗口判词为准。*

---

> **勘误注（2026-10-02 午后，P 代理深查 ebc2ec7）**：§4.5「512K 次优(+5.8
---

> **勘误注（2026-10-02 午后，P 代理深查 ebc2ec7）**：§4.5「512K 次优(+5.8%)」与「2M：c16 聚合 +4.5%」**不同梯级/不同格/不同量具世代，不可直比**——前者=cap512 对 cap256 @sd prose c1（W18，pre-DETERMINISTIC ±5% 噪声世代，census 同窗反向 −1.4%；det 后干净复验=+4.0%），后者=cap2M 对 cap512 @c16 聚合（G4，post-det）。另：社区 cap=262144 真身=hairpin 8192 零丢包包络（480KB 实测）安全覆盖点，防丢包工程决策非调优；256K 单键、与 GATHER 零代码耦合（C29 gather=512K 铁律不随 cap 联动）。详见 ~/luz030-opt-campaign/docs/audits/RING-CAP256K-BUNDLE-DEEPDIVE-20261002.md。
