# RING-FACE-3REF-COMPARISON-20261002 — 环网通讯面三参考对照 + 比选优化空间终判

> **性质**：纯文档对照（零 boot/零 docker exec/零流量/8899 未触）。唯一写产物=本文件。
> **任务**：对照 knapcio、MiaAI/mia、我方旧基座 0.2.9-ep1q2-fin2 三参考，核实环网通讯面
> 还有什么值得吸收的多点位组合式优化路径，以及"比选优化空间"剩多少。
> **输入**：~/RING-NETWORK-RESEARCH-REPORT-20261002.md（542 行，下称"环研报"）；本仓
> docs/audits/{KNAPCIO,MIA}-COMPUTE-PATH-DIFF、COMBO-PATHS-ROUND2、COMBO-DEPENDENCY-SURVEY、
> SPARKPREFILLSPLIT-PORT、PREFILLSP-STAGE1-DEV、ASSET-RECON-OLD-TO-NEW；MASTER-GAP-CLOSURE-PLAN；
> verdicts/{A14T,A2d,A1S-D1,A2S-D4,A3S-U31,A0S6,A0S7,S1PRIME-THETA-CLOSURE}；~/knapcio-v41-audit-20260925/
> （v2.3 全树）；/tmp/mia-fresh/（cad252b 全树，switchless-ring.md 本次**全文实读**——一轮
> MIA 报告未挖透的 fabric 参数段本次补齐）；~/release/0.2.9-ep1q2-fin2/（env/.env.tp4.fin2-c4f13f93
> 实读）；~/migrate-assets/{bin/r3-boot-arm.sh,b12x/b12x/comm/,dsv41/adapter/}（源码级核实）；
> /tmp/our-adapters.txt vs /tmp/k-adapters.txt；~/luz030-opt-campaign/arms/A23-DELTA-spec1.env +
> logs/A23-DELTA/{chain,container-head}.log（δ 重试链现场，只读）。
> **今日新证据锚（δ A23 链，任务书口径）**：TP_SPLIT+PREFILL_SP(shard/EXACT)+LOGITS_BUDGET
> 512MiB 组合臂 battery 六格全平 vs γ1（c1 66.39 vs 66.28，PR 32k 4067.8 vs 4069），GSM8K
> 0.985 过线；needle 131072 被一次 mesh 竞态 boot 崩中断、engram 2GiB 证据未取（重试链在跑）。

---

## 〇、总裁决（三句话）

1. **环网通讯面的"参考项目独有未吸收项"逐件判完后：真开放候选=空。** 三个参考的环网件
   全部落入 已吸收（含等价实现）/ 判负禁重开（引判例）/ 冻结随 B11（γ 关账因果链）/
   无意义（双证负）四桶；本轮对照**没有找到任何可借"对照"复活判负项的结构性新前提**。
2. **逐参数 diff 只剩一行实质差**：社区环配方 `SGLANG_ROCE_MAX_SIZE=262144`（knapcio/mia
   两家生产环配方同值，mia .env.tp4.example:72）vs 我方 fin2 形态 2097152——该差属于
   B11/A22 冻结线（A2d 三靴判负 + γ/S1′ 关账 ⇒ 复活条件 (a) 永不满足），**不是调参开放项**；
   且本审计纠出既有 B11 复活配方的**一处记录错误**（应保持 TWO_WAVE=0，§2 注 3）。
3. **比选优化空间四类终判**：纯环调参=封顶论成立空间≈0；换数据通路=唯一大边际剩余
   （1.548×，硬件决策）；重叠加深=L2PF 判负后直接杠杆≈0（ε 臂**不是**通信窗加宽器，§4-3）；
   参考独有未吸收项=空。剩余优化空间全部在环网面之外（ε/ζ/η/δ 阶梯/θ半——master plan
   §六既有序列维持不动）。**唯一新增行动项是治理件非性能件：fabricctl boot 门未接进
   新基座 r3 靴链（§3-新发现 1），今日 mesh 竞态崩打断 needle 证据恰是该门的设计对象类。**

---

## 一、三参考项目环网技术清单表

裁定四类：**已吸收**（含"等价实现"——机制不同、目标同、已在役）/ **结构性 N/A** /
**判负禁重开**（引判例，14 项登记=master plan §C 负墙 + COMBO-PATHS-ROUND2 §五）/
**真开放候选**（须过三关：不撞 86% 天花板封顶论、不撞四条硬定律=图重放绕钩/图税/
宿主打不过内核/全路由陷阱、不撞 14 项禁重开）。

| # | 技术 | 他们状态（出处） | 我方新基座状态 | 裁定 |
|---|---|---|---|---|
| K1 | sparkring `cx7_hairpin_diagonal` mesh 数据面（marker 0x88b5 + tc flower skip_sw in_hw + /32 路由，邻居 CX7 硬件转发对角） | knapcio/mia 自标 research-only 默认关；mia switchless-ring.md:426-447 机制段 | dsv41-mesh.service 四机在役 enabled（环研报 §2.3；宿主 /opt/dsv41-mesh 实存在位） | **已吸收**（且比他们激进：我方经 E1 A/B 转正生产） |
| K2 | `hairpin_queue_size` 8192（1024 时 >100KB 消息丢包、120KB AR 慢于 NCCL 3-4×） | 两家 service 化回填（mia :597-601、:613-620 丢包表） | 同值 8192，driverinit+服务化（环研报 §4.5） | **已吸收** |
| K3 | `ROCE_IDLE_SPINS` 200000→20000000（c1 步 40.6→37.1ms，200000 时 proxy 27% 采样沉睡） | knapcio switchless-ring.md:454；C 代理 `#define 20000000` | **源码级核实已吸收**：migrate-assets/b12x/b12x/comm/{roce,roce_ring}/roce_oneshot.py `DEFAULT_SPIN_LIMIT = 20_000_000` | **已吸收** |
| K4 | RoCEnante one-shot AR/AG ≤cap 用户态核（pynccl 直挂 + roce_capture 捕获期进图） | 两家产线在役（环配方 cap 256K） | adapter roce_ar.py/roce_gather.py 回移在位、双键门控（A23 靴横幅 `[roce_ar] gates=0/0 tp=4 max=(512K) gather=0`=inert 可证）；**生产关** | **判负禁重开谱系**：A2d-C1-final 三靴终谳（五档 DE −21~−55%、接受 3.25→2.7，双通道=spin 传输税+归约序翻边缘 token）；B11 复活条件 (a)=threshold<1.0 接受语义，随 S1PRIME-THETA-CLOSURE（θ≈0 ⇒ S1′ 关账）**永不满足 ⇒ 终局冻结** |
| K5 | two-wave 两波发包调度（先直连后转发，≥128KB 起用） | 两家实测不采纳、产线 =0（knapcio CHANGELOG "tested and not adopted"；mia :527 "two-wave off"） | fin2 =0；新基座无键（RoCE 关态） | **判负禁重开**（14 项登记；两岸双关） |
| K6 | 环专用 NCCL 2.30.7：switchless-cycle + dual-pci-domain（4 listener GID 发布 + 同 PCI 根内替换），四键 `NCCL_IB_EXTENDED_IPV4_GIDS/PRESERVE_PCI_DOMAIN/ROUTE_DIAGNOSTICS/QPS_PER_CONNECTION` + `NCCL_SWITCHLESS_RING_ONLY=1` | mia :300-338（含 provenance 钉 blob） | 等价实现：v1-ring-only + v4-netdev-hardcode（环序+每秩 PEER_HCA 库内硬编码）+ pip 路径盖写同身份 + `/opt/ncclpin.so`（r3-boot-arm.sh:118-147 实读；U1 v3 立通 Init 7.69s，环研报 §3.2） | **已吸收（不同实现）**——同为"4 HCA 全用+按秩锁口+只环"目标；ROUTE_DIAGNOSTICS 观测 nicety 无性能面（§2 行 13） |
| K7 | NCCL env 族：`BUFFSIZE=1M / LL128_BUFFSIZE=256K / PROTO=^LL128 / MAX_NCHANNELS=8`（GB10 pinned host RAM=显存，5.0→0.14GB/节点） | 两家在役（knapcio .env.tp4.example:26-29） | 8M / −2（禁）/ LL,LL128,Simple+TUNER_THRESHOLD=40960 / 4=MIN4 | **无意义**：doc74B 外部复证三臂全负+靴间 ±0.6% ⇒ NCCL env 面划去（MIA §1c）；我方 BUFFSIZE=8M 自有三臂判据在先，两侧同终态不同路径 |
| K8 | b12x `all_gather(columns=…)` 紧凑列 gather 内核（位精确束 −0.40/−0.45ms 的 compact 半） | knapcio v2.2 束在役（38e77e2） | 无（ι-compact 半；我 replicated_split.py 为旧版无 WINDOW/COMPACT 键） | **冻结随 B11**（compact 半依赖 RoCE gather 在役才吃满；COMBO-PATHS-ROUND2 §三-4 维持） |
| K9 | 第二平面编址（每机 4 RDMA 功能全用、每缆 /24、跨 PCI 域路由、MTU 9000、GID idx3） | mia :340-410 netplan 模板 | 已吸收：布线满配 8 线全 200G（GID3 实测）、GID 表四机不对称=设计态（环研报 §1.2/§2.1） | **已吸收** |
| K10 | NIC 资质档：`hairpin_num_queues=4 / flow_steering_mode=hmfs / eswitch=legacy / hw-tc-offload=on` | mia :487-492（不合格则拒/错） | 未逐参数登记；行为面等价证据=F04 tc `in_hw` 断言过 + mesh 在役多靴 | **已吸收（行为等价）**；逐参数登记=可核查项非优化项（无任何一侧报告过参数差收益） |
| K11 | `plan.py` cap 随最小 hairpin 队列自适应（1024→81920 / 8192→262144 防呆） | mia :601-604 | 无等价（cap=env 钉死，与队列态解耦） | **防呆差异**（无性能收益；若 B11 复活建议随配方补，见 §2 注 2） |
| K12 | marker UDP src-port 65535（flow label 16383）保留纪律 | mia Mesh pitfalls | 同设计（0x88b5 同族） | **已吸收** |
| K13 | "引擎运行期禁 re-init fabric 功能/停 mesh/marker"（re-init 掉全部 RDMA QP） | mia Mesh pitfalls 首条 | 同族知识在档（环研报 §5.4 marker 幽灵 + fabricctl F03） | **已吸收** |
| K14 | ZackO2o 三运维课：NIC **carrier** 采样（非 ib port state）/重启后 GID index 漂移重探/健康判据 artifacts 化 | 反架构对照（环研报 §6.3） | F07 含 carrier、F05 gid3 断言、fabricctl `check --json` | **已吸收（等价）** |
| K15 | CPU pinning 负判（调度器绑核 −5.5%、proxy 独核中性） | mia Mesh pitfalls 尾条 | —（无相反判据） | 知识项（强化"宿主打不过内核"定律，无动作） |
| K16 | `--sleep-on-idle`（空闲停忙轮询，head CPU 47%→14%） | 两家在役 | 无（G5 判中性：机队本就干净） | **不收件**（COMBO-PATHS-ROUND2 §五登记维持；非环网性能面） |
| M1 | 社区环配方整套：`MAX_SIZE=GATHER=262144 + TWO_WAVE=0 + hairpin 8192 + plan.py PEER_HCA_MAPS`（mia .env.tp4.example:72-73；"262144 needs hairpin 8192"） | 两家环产线配方 | **从未在任何一岸按我方栈测过**（C1B :84；A2 系测的是 2M 全路由形态） | **冻结随 B11**（同 K4 因果链）。**不是真开放候选**：过不了三关——不撞天花板（小消息延迟域确实绕开 algbw 封顶论，此关可过）但不撞判例关失败：A2d 通道②（oneshot 归约序≠NCCL 环序 ⇒ threshold=1.0 精确接受翻边缘 token）与消息尺寸无关，256K 选择性路由下 decode AR（50-60KB）全部迁 oneshot，通道②全额适用；唯一解=接受语义变更，已被 S1′ 关账封死。**无结构性新前提，不借对照复活** |
| M2 | `DSV41_ROCE_GATHER` 2M（其交换机形态）/262144（环）——c16 档 draft vocab 分片 1.03MB>512K 我方回落 NCCL、其仍走 RDMA 的半臂差 | mia 在役 | 524288（G-0 复审挂起=A2d-g0a moot） | **随 B11 冻结**（gather 依赖 oneshot 族在役；环研报 §6.2 已注两账不矛盾） |
| M3 | 交换机形态 cap 重开（`MAX_SIZE/GATHER` 届时可重 A/B，hairpin cap 约束消失） | 结项备档 | runbook 在档（环研报 §8.4） | **硬件决策域**（归 §4-2 类，非当前可开臂） |
| F1-F5 | 旧基座 fin2 五资产 D1-D5（pynccl 构造块 / /opt/b12x / ring-only NCCL+ncclpin / roce_gather+l2pf 落点 / mesh 宿主三件） | fin2 生产终态 | 回移完整性逐件裁定见 §3 | **全部回移在档（2 个治理性登记项除外，§3）** |

**三关检验记录（对唯一边缘项 M1）**：(a) 天花板关——256K 小消息延迟域确实不受 algbw 86%
封顶约束，**此关可过**（诚实记录）；(b) 四定律关——roce_capture 捕获期集成不撞图重放/
图税定律，**此关可过**；(c) 禁重开/判例关——A2d 损伤通道②与尺寸无关+复活条件 (a) 已随
S1′ 关账落空，**此关不过**。三关须全过 ⇒ 落选。其余各项均在第一二关即出局（K5/K7 撞判例、
K8/M2 依赖冻结线）。

---

## 二、逐参数 diff 表（knapcio/mia 环网定值 vs 我方）

我方值源：fin2 `.env.tp4.fin2-c4f13f93`（:62-87）+ 新基座 `r3-boot-arm.sh`（:125-147）。
社区值源：mia `.env.tp4.example`（:72 环配方、:401/:405 交换机配方）+ knapcio `.env.tp4.example`
（:12-31）+ 两家 switchless-ring.md。裁定三档：值得 A/B / 无意义 / 退步。

| # | 参数 | knapcio/mia 环网定值 | 我方（fin2 → 新基座在役值） | 判定 |
|---|---|---|---|---|
| 1 | hairpin_queue_size | 8192 | 8192（服务化回填） | 一致，已吸收 |
| 2 | RoCEv2 GID index | 3（preflight 校验/覆写验证） | 3（`NCCL_IB_GID_INDEX=3`/fin2 `_FORCE=3`） | 一致 |
| 3 | MTU | 9000 | 9000（F07 断言） | 一致 |
| 4 | QoS trust / TOS | 未登记 TOS（hairpin 强制 pcp trust 是共同前提） | `NCCL_IB_TOS=46` + trust=pcp（ring 期） | **无意义**：我方自有设计（ring-only NCCL 无损配套），社区无可比 delta、两侧无故障/收益差记录 |
| 5 | **SGLANG_ROCE_MAX_SIZE** | **环 262144 / 交换机 2097152** | fin2 2097152；新基座生产关（A2d）；adapter 缺省显示 512K | **唯一实质差**。随 B11 冻结非开放 A/B（§1-M1 三关记录）。注 1 |
| 6 | DSV41_ROCE_GATHER | 环 262144 / 交换机 2097152 | 524288 | c16 半臂差（其享）；随 B11 冻结（A2d-g0a moot） |
| 7 | B12X_ROCE_TWO_WAVE_THRESHOLD_BYTES | 0（显式关，两家一致） | fin2 0；新基座无键 | 一致（死键态） |
| 8 | ROCE_IDLE_SPINS | 20000000 | 20000000（源码级） | 一致，已吸收（K3） |
| 9 | NCCL_BUFFSIZE | 1M（GB10 显存经济学） | 8M | **无意义**（doc74B 三臂双证全负；两侧同终态不同值各有判据） |
| 10 | NCCL_LL128_BUFFSIZE / PROTO | 256K / `^LL128` | −2（禁）/ `LL,LL128,Simple`+TUNER_THRESHOLD=40960 | **无意义**（同效：ring-only tuner 实际只选 LL≤40KB/Simple，LL128 两边都不上桌） |
| 11 | NCCL_MAX_NCHANNELS | 8 | 4（MIN=4 锁定） | **无意义**（doc74B） |
| 12 | dual-pci 四键 + SWITCHLESS_RING_ONLY | 在役 | 不设（v4-hardcode+PEER_HCA 等价替代） | 已吸收（等价实现，K6） |
| 13 | NCCL_IB_ROUTE_DIAGNOSTICS | 1（每 QP 落卡记录） | 无等价 | 观测 nicety：无性能面；如需 per-QP 落卡诊断可借用（须 dual-pci 补丁栈，我方库不含 ⇒ 实际不可移植，仅记录） |
| 14 | B12X_ROCE_HCA / PEER_HCA_MAPS | plan.py 生成、随配方 | fin2 在役；新基座无键（RoCE 关态合理） | B11 若解冻需回加（C1B :129-151 宿主前置已登记） |
| 15 | fabric 起栈门 | doctor/preflight（靴前校验 GID/口态） | 旧 start.sh serve 门有（F00-F10 22 断言拒起）；**新基座 r3-boot-arm.sh 及链脚本零 fabricctl 接线**（全文 grep 证） | **值得补（治理回移，非 A/B）**——§3 新发现 1 |

**注 1（配方勘误，须回写 COMBO-DEPENDENCY-SURVEY B11-b）**：该档 B11 复活形态写作
"+删除 TWO_WAVE=0（回 128KiB 拆波）"——与两家生产环配方**相反**：mia .env.tp4.example:72
配方显式含 `B12X_ROCE_TWO_WAVE_THRESHOLD_BYTES=0`，knapcio CHANGELOG 明言测过不采纳，
其结果表（:527）即 two-wave off 口径。B11 若因任何未来前提解冻，正确社区形态=
`MAX_SIZE=262144 / GATHER=262144 / TWO_WAVE=0`（保持 =0）。
**注 2（防呆差异）**：社区 plan.py 按最小 hairpin 队列自适应 cap（8192→262144），我方
cap 与队列态解耦——纯防呆无收益，随 B11 一并考虑。
**注 3**：`max_size` 三值并存（社区环 256K / 我 fin2 2M / 我 adapter 缺省 512K）本身即
A2 系测形与社区配方从未同轨的又一佐证——C1B :84 判断经本次 mia 原文实读**成立**。

---

## 三、旧基座 fin2 → 新基座环网面回移完整性（文档层核对）

| 件 | 文档层状态 | 证据锚 | 结论 |
|---|---|---|---|
| **D1** pynccl RoCEnante 构造块（fork :153-190） | adapter `roce_ar.py` 回移在位，双键门控（`DSV41_ROCE_RING ∧ SGLANG_ROCE_ALLREDUCE`），惰性可证（A23 靴 `[roce_ar] gates=0/0 … inert` 横幅四靴齐） | /tmp/our-adapters.txt；A2S-D4 :16-19（worker 副本同步史）；ASSET-RECON #15 | ✅ 回移完成；生产未武装=**合法**（A2d 判负），非欠账 |
| **D2** /opt/b12x 树 | bind-mount `/opt/b12x-tree:ro` + PYTHONPATH 次位；**comm 子树含 roce 与 roce_ring 全套**（roce_oneshot.py/_proxy.py/_roce_proxy.c/_path_config.py 源码在位）+ `comm.bak-prerocenante-r2` 备份 | r3-boot-arm.sh:19/:122/:151；migrate-assets/b12x/b12x/comm/ 实列 | ✅ 回移完成（计算面在役=ASSET-RECON #1/#3/#4；通信面随 D1 待命） |
| **D3** ring-only NCCL 2.30.7 + ncclpin | `-v nccl-ringonly:/opt/nccl-ringonly` + **pip 路径盖写同身份**（堵 fail-open 回退 2.28.3）+ `LD_PRELOAD=/opt/ncclpin.so`（改名避 deep_ep 子串断言）+ NCCL 13+ 键（含 TOS=46/逐秩 PEER_HCA/GID3） | r3-boot-arm.sh:20-22/:103/:118-147/:266/:285；ASSET-RECON #14 ✅ | ✅ 回移完成（A10 期识别的三个 fail-open 崖在靴脚本层全部堵上） |
| **D4** roce_gather / l2pf 落点 | `roce_gather.py`/`l2_prefetch.py`/`l2pf_attn.py`/`l2pf.cu`/lib 在位；l2pf 生产关=A14T 判负（c8 −4.9% 双证）；gather=G-0 挂起 moot | /tmp/our-adapters.txt；A14T 卡；ASSET-RECON #17/:21 | ✅ 件在；未武装=判负/挂起合法，非欠账 |
| **D5** mesh 宿主三件（/32 路由+tc hairpin+marker） | 宿主未动、四机 enabled（/opt/dsv41-mesh 在位实列）；今日 needle 131072 被一次 **mesh 竞态 boot 崩**打断=已知竞态族（环研报 §5.3 单元次序/§5.4 marker 幽灵）复发，非迁移缺失 | 环研报 §8.1"零回移=设计态"；任务书今日证据 | ✅ 宿主面无未回移项；竞态复发=运维脆弱性（见下） |

**本审计新发现（文档层已知未回移/未接线项，共 2 项，均治理件非性能件）**：

1. **fabricctl boot 门未接进新基座靴链**。旧 start.sh serve 有 fabric 门（F00-F10 22 断言，
   红→heal→复验仍红**拒起**，环研报 §2.4）；`r3-boot-arm.sh` 与 campaign tools/*.sh、
   migrate-assets/bin/ 全文 grep **零 fabricctl 接线**（其硬门只有 drop_caches+UMA 总账）。
   今日 mesh 竞态 boot 崩（打断 needle 131072 证据采集）恰属该门设计对象类——boot 期单元
   竞态/marker 失挂在无门形态下表现为"裸靴失败+事后归因"，而非"拒起+指名故障件"。
   **建议**：P1 级治理回移（r3 靴链起栈前加四机 `fabricctl check` 门；成本=脚本一段；
   收益=竞态族 fail-closed + 省 retry 靴）。落实实证归另一代理。
2. **master plan §六 A22 行状态滞后**：序列图仍写"A22（B11 新配方，γ 绿后）"，而 γ/S1′
   已于同日关账（θ_max=2ms=bias 3.9% 一格负 ⇒ verify-all 最优，4d55df8）⇒ 按因果链 B11
   终局冻结（COMBO-DEPENDENCY-SURVEY §二-B11-c、COMBO-PATHS-ROUND2 §二-⑥）。建议在
   master plan A22 行补"γ 已关账 ⇒ 冻结维持（解冻唯一前提=接受语义结构性变更）"注记，
   消除两档间状态差。

---

## 四、"比选优化空间"终判（四类）

### 4-1 纯环调参 —— **封顶论成立，空间≈0，无值得开的 A/B**

有效 algbw 14.3GB/s = 修正天花板（每方向 1×200G=16.7GB/s）的 **86%**（环研报 §1.2）；
残余 ~14% 的构成=环算法 2(N−1) 拍流水 + 对角 hairpin 代价（9.99-10.18µs vs 直连 8.47µs）
+ 环二分带宽=1 链——全部结构性，非键位可达。**社区同终态三角验证**：knapcio/mia census
NCCL 0 行（RoCEnante 化共同终态）、同一 mesh、同一收敛参数（表二 1/2/3/7/8 行全一致）、
NCCL env 族两岸双证全负（doc74B 三臂+我方历史三臂）。唯一"参数形"悬案=256K vs 2M cap
（表二行 5）——属 B11 冻结线且通道②判例挡路（§1-M1），不是调参开放项。**结论：封顶。**

### 4-2 换数据通路（交换机 fabric）—— **唯一大边际剩余；硬件决策，非优化臂**

外部交换机同镜像中位 **1.548×**、长档 ≥8192 中位 **2.01×**（fabric 主导性经 A/B 站三角
验证：A 站 1.56-1.58 互证、B 站环+自编译 ring-only ≈×1.08 ⇒ 代码不缺）。数据面零开发
（roce/roce_ring 双变体在镜像、单键 `DSV41_ROCE_RING` 切换、doc58 runbook 在档）；验收线
busbw ≥14.3GB/s 且对 mesh ≥1.5×。物理互斥（同批 DAC 口）⇒ 时序先后不可并行，属采购/布线
决策域。**Amdahl 张力须如实披露**：collective 27.7% 下纯带宽 1.55× 只该兑 ~1.11-1.17×，
实测 1.58× ⇒ 收益约一半来自**长档停顿带消除**（同靴 chunk 墙钟 2.47-4.46s 波动 vs 外部
完美线性）——交换机修的不只是带宽，还有环上 NCCL 的停顿行为；这同时意味着"1.548× 全额
兑现"的预期管理要按停顿带份额折算。最大静默坑=QoS trust 交错（§5.6）。届时 cap 两键可
重开 A/B（hairpin 硬顶约束消失，环研报 §8.4）。

### 4-3 通信×计算重叠加深 —— **L2PF 判负后直接杠杆≈0；ε 臂不是通信窗加宽器**

新基座通信面=NCCL ring only（RoCE 族 A2d 判负回退）。历史两条重叠路径均关闭：
①RoCE 捕获期集成（busy 116→121-123% 的重叠红利载体）=B11 冻结；②l2pf 骑 NCCL 集合窗
（A10 重定向→A13→A14T）=c8 −4.9% 争用判负、产形关。stock 侧已有的重叠（hc mix stats
专用侧流）=无缺口。
**ε 臂定性（任务问询项）**：ε（G1 残余融合系列×barrier-zero×window GEMM×T 系微件）削的
是**图间小核发射 sliver 墙**（每 1000 核≈2.7ms）——sliver 位于图重放**之间**，而 NCCL AR
活在图重放**之内**：ε 不改变 AR 窗宽、不制造任何通信/计算重叠，**不是间接加宽通信窗**。
其真实通信面效应是二阶的：步墙缩短 ⇒ AR 份额上升（Amdahl 移位）——只抬高**未来**通信
杠杆（B11/交换机）的兑现价值，不创造当期重叠。⇒ ε 维持其既有归类（DE 发射面前沿，
master plan §六序列不动），不因"通信窗"重开归类。**结论：域内直接剩余≈0。**

### 4-4 参考项目独有未吸收项 —— **逐项判后：环网面真开放候选=空**

§1 表 16+3 行逐件裁定：已吸收/等价实现 11 项、判负禁重开 2 项（K4 谱系/K5）、冻结随 B11
3 项（K8/M1/M2）、无意义 2 项（K7/表二 9-11）、知识/不收件 2 项（K15/K16）、防呆差异 1 项
（K11）。**真开放候选清单：空**（明示）。唯二新增行动项均非性能 A/B：fabricctl 门回移
（§3-1）与 B11 配方勘误+master plan 状态对齐（§2 注 1/§3-2）。剩余优化空间全部在环网面
之外：ε（发射密度）、ζ（量具收口）、η（cert_head）、δ 阶梯（P-SP stage2/深携带后续卡）、
θ半（encoder-swa）——master plan §六序列维持。

---

## 五、δ A23 组合臂全平：knapcio 形 TP_SPLIT+PREFILL_SP 配对未兑现的候选解释

**登记事实**：α=A22（TP_SPLIT+LOGITS_BUDGET 单独臂）五格 ±0.15%、PR 全平、质量净
（git 3afdaae"B2 终判归 δ 配对"）；δ=A23（+PREFILL_SP shard/EXACT + engram 2GiB 顺车键）
六格仍全平（c1 66.39 vs 66.28、PR 32k 4067.8 vs 4069、GSM8K 0.985）。knapcio 同配对
+18-21%（sparkDash 16k-262k）/真实文本 +15%（其 README/CHANGELOG 口径）。
**纪律声明**：以下为"配对未兑现的候选解释"案头清单，供 δ 复盘与后续卡取舍参考；
**不构成任何单测复活依据**。按证据强度排序：

1. **行工段覆盖差（我方只兑现其收益构成的子集）**。knapcio 配对收益=wkv/gate/hc 行切
   三段；我方 stage1 经结构裁决（PREFILLSP-STAGE1-DEV §1c）：wq_a/wkv/engram.wkv 行切
   **拒绝**（与在役 REPLICATED_SPLIT 列切同 GEMM 构造性冲突——注意细化：该列切门
   `rows<=96` 仅 decode 面，prefill 4096 行区间实际空闲，排除是构造性安全裁决而非硬不可
   行，DEV 自注"REPLICATED_SPLIT 关闭的臂上该段成为新缺口（后续卡）"）；gate 段延后；
   hc mix stats=stock 已侧流 overlap 无缺口。⇒ 我方 stage1 增量段仅 hc post/combine A/B
   两站。DEV §4.3 自己预登记"本段兑现面应保守预期（knapcio EXACT +10% 是其树口径）"。
2. **AG 字节膨胀 ~5×（通信税吃掉行工省）**。stage1 每站 AG 传 `updated[T,4·5120]+normalized
   [T,5120]` ≈ 原 AR `o[T,5120]` 的 ~5× 字节（DEV §4.3 原文）；在二分带宽=1 链、NCCL
   algbw 86% 封顶的环 fabric 上，通信面成本随字节近线性 ⇒ 净效趋零与实测平一致。
   **其配对的深形态前提我方未满足**：knapcio 更深形态=updated 以 shard 形态跨层携带、
   AG 延后到非行纯消费前（DEV §4.4 明记"跨层残差携带未做——深携带=后续卡"）——其
   AG 次数/字节远低于我方每站即 AG 的 stage1 正确形态边界。
3. **基线构成差（可切薄片已被先占）**。我方 γ1 基线已含 A15 bounded-replay（PR
   +57-70%）+A16 opt1+INDEXER_HOIST+topk2048+DG_SPARSE；knapcio +18-21% 的参照基线无
   此族。同一配对在贫基线上是大头、在富基线上是残差。
4. **测量域/门槛几何**。knapcio 数字是 sparkDash filler 口径（虚高 9-20%，Engram 行缓存
   全命中；其真实文本 +15%）；TP_SPLIT 门槛 MIN_CONTEXT≥32768 ⇒ 我方六格 battery 中
   仅 32k 格真正行使 TP_SPLIT（4k/8k/16k 不 eligible）——配对的"TP_SPLIT 半"在多数格
   未参与，与 α 单独全平自洽。prefill 侧消息尺寸分布差（其 prefill ladder/EP1 计划表下
   的 chunk 行数-消息谱 vs 我方 chunk4096 谱）属实证域，本审计不预判。
5. **stage2/FP8 半未实现**：其 +1.5-3% FP8 gather 属 stage2（我方未开）。
6. **engram 2GiB 顺车键=构造性中性预期**：sparkDash filler 口径下 1GiB 命中已 99.1%
   （fin2 :33），2GiB 在该 battery 域无增量面（engram 三问定谳 dbc1d78：扩容只在
   evictions>0 域兑现）。
7. **证据完整性缺口（非解释，登记）**：needle 131072 与 engram 2GiB 证据未取——needle
   被一次 mesh 竞态 boot 崩中断；重试链现场（logs/A23-DELTA/）显示重试靴命中 prefill_sp
   layer-carry 缝拒靴（"DeepseekV4DecoderLayer.self_attn missing; refusing to boot
   (layer-carry seam moved)"，12:19 import 拒 + 12:43 二次 rc=1）——fail-closed 设计起效
   （响亮非静默），但意味着 **layer-carry 段在当前部署形态下尚未取得任何运行期 engaged/
   BIT-MISMATCH 证据**；δ 六格全平读数与"段未激活/段激活但净零"两种态在 battery 均值上
   同形（W15 b2 污染教训的镜像：均值同形须靠族表/横幅分辨）。重试链归 δ 主理，本审计
   不介入。

---

## 六、残差与不确定项（诚实登记）

1. **表二行 5/6 的"社区配方从未在我方栈测过"是文档层结论**（C1B :84 + 本次 mia 原文
   复核），不代表它一定判负——它是被因果链冻结，不是被直接测死。若未来接受语义发生
   结构性变更（S1′ 家族重启），B11 应按 §2 注 1 勘误后的配方（256K/256K/TWO_WAVE=0）
   起臂，而非旧记录的"删 TWO_WAVE=0"形态。
2. K10 NIC 资质档逐参数登记未做（行为等价证据在，参数清单不在）——零预期收益，仅
   fabricctl 门回移时顺带登记即可。
3. 今日 mesh 竞态崩的根因分型（§5.3 单元次序 vs §5.4 marker 幽灵 vs 新变体）无现场
   工件可判——归 δ 重试链与运维线；本审计只登记"竞态族复发+无 boot 门"的事实对。
4. δ 重试链在飞（12:43 后状态未观察）；本审计引用的 A23 现场止于 12:43 rc=1。
5. 交换机 1.548× 的停顿带份额折算系数无独立测量（Amdahl 张力仅在案定性）——若交换机
   立项，验收线沿用 busbw ≥14.3 且 ≥1.5×，预期管理按 §4-2 折算。

---

## 七、结论回执

- **终判四类**：纯环调参=封顶（空间≈0）；换数据通路=1.548× 硬件决策（唯一大边际）；
  重叠加深=≈0（ε 非通信窗加宽器，二阶 Amdahl 移位而已）；参考独有未吸收项=空。
- **真开放候选清单：空**（明示；三参考环网件全部落入已吸收/判负/冻结/无意义四桶，
  无一项通过三关）。
- **参数 diff 要点**：七参数六项一致或已吸收；唯一实质差=社区环 cap 256K vs 我方 2M
  （随 B11 冻结）；另纠出 B11 复活配方记录错误（TWO_WAVE 应保持 =0）与两个治理登记项
  （fabricctl boot 门未接 r3 靴链=建议 P1 级回移；master plan A22 行状态滞后）。
- **δ 全平候选解释**：行工段覆盖差（我方仅 hc 两站，其配对依赖的深携带/wkv/gate 段
  未在）+ AG 字节 ~5× 通信税 + 基线已富 + TP_SPLIT 门槛几何 + stage2 未开 + engram 顺车
  键构造性中性；needle/engram 证据缺口与 layer-carry 未取得运行期证据如实登记。

——判词人：环网面三参考对照代理（ZCode 只读）/ 2026-10-02。证据=环研报 542 行 + 本仓
docs/audits·verdicts 择要 + knapcio/mia 全树原文（switchless-ring.md 本次全文实读补齐
fabric 参数段）+ fin2 发布包 env 实读 + migrate-assets 源码级核实（comm 树/IDLE_SPINS/
靴脚本接线）+ A23 现场日志只读。未 boot、未进容器跑 python、未发流量、8899 未触、
未动集群与任何进程。
