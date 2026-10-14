# 环网通讯面落实核查（RING-FACE-LANDING-VERIFICATION）

- 日期：2026-10-02 12:45–13:05 UTC；核查代理：只读取证（未 kill/重启任何链进程与容器；未对 8898/8899 发流量；未 drop_caches；kernel_census_v2 未使用；fabricctl 只跑 check 未跑 selftest）。
- 对象：新基座 SGLang main-79cafece + adapter（~/migrate-assets/dsv41/adapter/，四机本地拷贝）对照《四机无交换机环网集合通信优化技术指导》（/home/liux***ya/RING-NETWORK-RESEARCH-REPORT-20261002.md，542 行）。
- 集群背景：δ 重试链（pid 215112，12:42:31Z 点火）靴 12:43:38Z rc=1，链自身仍在 20s 健康轮询（预计 13:03:38Z 自判 ABORT health 未达，未复核前以链日志为准）。**本核查全程无活靴**：活靴横幅/env 取证改走存档证据源（~/l10-incident/*.exit.log、logs/A23-DELTA/{chain.log,container-head.log,container-head-attempt2.log}）+ 镜像静态检查（docker run --rm --entrypoint 形式，不碰 GPU/网络）。

---

## 0.【最优先】`[roce_ar] gates=0/0 tp=4 max=(512K) gather=0` 横幅三读裁定

**证据**：chain.log:322；worker-dgxspark04.exit.log:88（另 :35/:113）；四份 12:43 exit.log 合计 13 处 + 12:19 container-head.log 4 处——四秩 × 双靴（12:19 与 12:43）完全同串。

**源码定位**：~/migrate-assets/dsv41/adapter/sitecustomize.py:573-579，注释原文 "I14-A: RoCE AR face gates (**arm/no-arm visible without a GPU**; install() itself banners REFUSED on a bad TP_SIZE when pynccl loads)"。横幅是**适配器 import 期对四个 env 键的裸转储**，f-string 缺省标签：`DSV41_ROCE_RING→"0"`、`SGLANG_ROCE_ALLREDUCE→"0"`、`SGLANG_ROCE_MAX_SIZE→"(512K)"`、`DSV41_ROCE_GATHER→"0"`（括号缺省串约定与同行 `tp=(unset)` 一致）。

**三读裁定**：

| 读法 | 裁定 | 依据 |
|---|---|---|
| (a) gates=0/0 = 零安装位 ⇒ RoCEnante AR 在新基座整体未接 | **成立（实质正确）** | 转储的是 env 值而非计数器：0/0 = 双门（DSV41_ROCE_RING、SGLANG_ROCE_ALLREDUCE）均未设。roce_ar.py:37 "Gates: …both required at import"、:76-77 `_both_gates()`、:241 `cls.roce_capture, cls._should_roce = …` 只在双门=1 时安装 ⇒ pynccl 面未挂钩，RoCEnante AR 未武装。 |
| (b) 0 运行期命中（横幅靴早期打印）= 良性 | **不成立** | 横幅设计语义就是"arm/no-arm 指示器"（源码注释自述），非命中计数；打印时机早≠读数无害。0/0 对本臂就是真实的"未武装"。 |
| (c) max=512K 说明实值 524288、gather=0 说明未设 | **机制错、结论半对** | `(512K)` 与 `0` 都是**键缺席时的缺省显示标签**：SGLANG_ROCE_MAX_SIZE 整键不在（非"实为 512K"；且双门=0 下 cap 语义本就休眠）；DSV41_ROCE_GATHER 整键不在（`0` 非安装计数）。⇒ §6 两键缺席这一结论方向正确。 |

**值链追溯（为何 0/0）**：arm env（A23-DELTA-spec1.env，27 键）零 RoCE 键 → r3-boot-arm.sh COMMON_ENV（:124-191，仅 NCCL 面）零 RoCE 键 → 镜像 main-79cafec0 无 DSV41 RoCE env。新基座上 §6 RoCE 面键的**唯一交付通道是 ARM_ENV_FILE**，且只有 A2/C1 世系臂携带（A2-C1-spec0.env:5-11、A2d-C1-spec1.env:5-11、A2c…）；fin2 旧基座则经 .env.tp4:87 EXTRA_DOCKER_ENV 常带。

**定性**：采纳臂 γ1 与现行 δ 臂均不携带 RoCE 面键 = **RoCEnante 用户态核面在生产候选臂未落实（红）**；同时它是**登记在案的刻意推迟**而非遗忘——MASTER-GAP-CLOSURE-PLAN-20261002.md:47（B11："C1 RoCE AR 家族（SGLANG_ROCE_ALLREDUCE=1 等 5 键）…新基座未测…A22（任务书 C1 线，I14 四机硬前置核查后）"）；A2-C1 四机首靴 DOA（判词卡 A2-C1-roce-20260930.md："READY 0/4 秩=路由面残废…非机制判负——RoCE oneshot AR 语义本靴根本未被测到"）。指导文件 §4.7 的判负对象是**全路由**（threshold=1.0），选择性路由（fin2 形态，cap 2MiB）才是文档定义的正确生产位置——故本缺口不能用 §4.7 开脱。

---

## 1. D1–D5 逐项表

| 项 | 状态 | 证据（来源:行 / md5） | 缺口 |
|---|---|---|---|
| **D1** RoCEnante pynccl 构造块 | **代码已移植=绿；武装/验证=红** | adapter/roce_ar.py（fork 67 行 δ 的 install() 形态）：`_should_roce` :114、`roce_capture` :135、双门 :37/:76-77、拒装 raise :186/:202；捕获期集成=roce_capture 即 CUDA 图捕获期入口（docstring "construction, maybe_roce_context = pynccl_comm.roce_capture(stream)"，:53 保留 fork 的 pynccl 模块级 WeakSet）。sitecustomize.py:155-177 挂装（门 DSV41_ROCE_RING=1 且 SGLANG_ROCE_ALLREDUCE=1）。四机 md5 全等：sitecustomize.py=8c2c8b14…、roce_ar.py=932fe12b…、roce_gather.py=93a2c823…、l2_prefetch.py=e8e8675d…、l2pf_attn.py=42438834…。`RoCEnante ready: world=%d hcas=%s gid_index=%d…` 横幅源在 b12x 树三变体（b12x_next/comm/roce/roce_oneshot.py:352、b12x/comm/roce/roce_oneshot.py:351、b12x/comm/roce_ring/roce_oneshot.py:390） | gates=0/0（第 0 节）⇒ 新基座从未武装成功（A2-C1 DOA）；"ready: world=4 hcas=×4 gid_index=3" 横幅在 main 上**未复现** |
| **D2** /opt/b12x 树 | **绿（机制等价改道）** | 镜像内无 /opt/b12x（`docker run --entrypoint ls` 实测 No such file）——按靴设计改挂载：r3-boot-arm.sh:122 `-v $B12X_DIR:/opt/b12x-tree:ro`、:151 PYTHONPATH=/opt/dsv41/adapter:/opt/b12x-tree。运行期旁证：四份 12:43 exit.log 均有 "DSV41 MXFP8 dense linears routed to FlashInfer backend 'b12x'"（b12x_next 计算路径实活） | comm 半边（roce/roce_ring）随树在位但因 gates=0 未用（非 D2 本身缺口） |
| **D3** ring-only NCCL 2.30.7 + ncclpin | **静态=绿；运行期横幅无样本** | 靴前置核验 :103；pip 路径盖写挂载 :120（`$NCCL_DIR/libnccl.so.2.30.7` → /opt/sglang/.../nvidia/nccl/lib/libnccl.so.2）；LD_PRELOAD 同身份 :138 `/opt/ncclpin.so + $PIP_NCCL`。镜像 find：pip libnccl.so.2（被盖写）+ **系统 2.28.3 仍在**（/usr/lib/aarch64-linux-gnu/libnccl.so.2.28.3）——单一性靠 preload+盖写保证；fail-closed 断言 deep_ep `check_nccl_so()`（镜像 deep_ep/__init__.py:54 定义、:91 import 即调，/proc/self/maps 与链接库**二进制级**比对+重复库 abort）**未压制**（新靴/两臂 env 均无 EP_SUPPRESS_NCCL_CHECK；对照 fin2 .env.tp4:87 里是小写变体 `EP_SUPPRESS_nccl_CHECK=1`，对该断言无效化不成立） | 今日无活靴 ⇒ `nccl==2.30.7` 运行期横幅无样本；系统 2.28.3 静默回退风险仅靠 preload 关断，留待下一成功靴留档 |
| **D4** roce_gather / l2pf 落点断言 | **黄** | roce_gather.py:14 install() 挂 PyNcclCommunicator.\_\_init\_\_/all_gather；正向横幅对存在但**惰性**：:27 "DSV41_ROCE_GATHER ready: max %d bytes per rank"（依赖 self.roce 在）+ :39 首路由日志——非 install 计数；gates=0 时静默惰性（by design）。l2pf：adapter 内移植齐（l2_prefetch.py/l2pf_attn.py/l2pf.cu/libdsv41_l2pf.so；sitecustomize:45-47/:91-93/:113-121 挂装，门 DSV41_L2_PREFETCH 缺省关） | 数值型 install 计数断言无；l2pf 无现行臂携带 DSV41_L2_PREFETCH=1 ——**按判负不部署（A14T-REJECTED，do-not-reopen）= 预期态，如实记录** |
| **D5** mesh 宿主三件（四机只读） | **通讯面=绿；F10 见黄** | 四机 dsv41-mesh 单元 active (exited) since 09-30 15:16 全 SUCCESS；hairpin 1024→8192 四机 journal 实证（如 dgxspark01 hairpin.sh[2165] 09-30 15:16:38/44 两口，四机同形；unit 文件 ExecStartPre=/opt/dsv41-mesh/hairpin.sh 8192）；tc flower 规则每机 4 条 in_hw（01/02 落 enP2p1s0\*、03/04 落 enp1s0\*，eth_type 88b5 + skip_sw，分布合拓扑）；GID idx3 16/16 口非空 RoCEv2（02/04 各两口 idx3=10.20.0.x 为黄金拓扑对角段，fabricctl F05 按 topology.json 逐口断言通过）；**fabricctl check：01=22/22 PASS、02=22/22 PASS、03=21/22、04=21/22**（唯一 FAIL 均 F10 NFS：src 含 `systemd-1\n` automount 前缀 vs 期望裸串——fabricctl 头注自记的 03/04 NFS 持久化已知项，非通讯面断言；F00-F09 全绿含 F03 本靴 marker attached=true、F04 in_hw、F05 gid3） | 03/04 F10 红（非通讯面、已知项）；attached:true 需经 marker 单元 journal 读（我直查父单元计数=0 属查询口径，fabricctl F03 权威口径通过） |

## 2. §6 七参数逐键表（靴默认 vs arm env）

| 键（指导值） | 靴 COMMON_ENV 默认 | γ1（A21-GAMMA1，采纳臂） | δ（A23-DELTA） | 判 |
|---|---|---|---|---|
| SGLANG_ROCE_MAX_SIZE=2097152 | 无 | **缺** | **缺** | **红**（仅 A2 系臂有：A2d-C1-spec1.env:7；fin2 .env.tp4:87 在役） |
| DSV41_ROCE_GATHER=524288 | 无 | **缺** | **缺** | **红**（同上，:8） |
| DSV41_ROCE_RING=1（+伴门 SGLANG_ROCE_ALLREDUCE=1、B12X_ROCE_HCA/PEER_HCA_MAPS/TWO_WAVE 三族键） | 无 | **缺（整族）** | **缺（整族）** | **红**——**生产候选臂 γ1 落实缺口，单独标红** |
| ROCE_IDLE_SPINS=20000000 | 不适用（非 env）——烘焙为 `#define`：b12x_next/comm/roce/_roce_proxy.c:48、b12x/comm/roce_ring/_roce_proxy.c:47（=2×10⁷；provenance json:22 记 200000→20000000 定谳） | 随 b12x 挂载自动交付 | 同左 | 绿（编译期内建；武装前休眠） |
| NCCL_TUNER_THRESHOLD=40960 | **有**（r3-boot-arm.sh:147） | 继承 | 继承 | 绿 |
| NCCL_IB_GID_INDEX_FORCE=3 | 键名偏差：靴设 **NCCL_IB_GID_INDEX=3**（:127，无 _FORCE） | 继承 | 继承 | 黄——ring-only 2.30.7 实读裸键（strings 实证 HINT…NCCL_IB_GID_INDEX，无 _FORCE 变体），功能等价；_FORCE 是 fin2 旧栈约定（.env.tp4:67、guardctl.sh:711）；本队内核 6.17.0-1031 与 .env.tp4:7-9 注释的 1031 GID-reorder 观察相关，F05 16/16 通过为当前实证 |
| NCCL_IB_TOS=46 | **有**（:142） | 继承 | 继承 | 绿 |
| （附）LD_PRELOAD ncclpin 身份 | **有**（:138，ncclpin + 盖写后 pip 路径同身份） | 继承 | 继承 | 绿（静态）；见 D3 运行期横幅缺口 |

附注（黄）：COMMON_ENV:147 `NCCL_VERSION=2.28.3-1` 为**陈旧标签键**，与实挂 2.30.7 矛盾（NCCL 不读此键，纯误导性标签，建议清理）。

## 3. §8.2 断言链逐项

| # | 判据 | 状态 |
|---|---|---|
| 1 | boot 前置门：四机 fabricctl check 22/22 + `RoCEnante ready…` 或 `nccl==2.30.7` 横幅 | **半红**：check 01/02=22/22，03/04=21/22（仅 F10 非通讯面）；两横幅在新基座均未复现（RoCEnante：gates=0/0 + A2-C1 DOA；nccl==：今日无活靴样本） |
| 2 | nccl-tests busbw ≥14.3GB/s + per-link 抽查 | **PENDING**（无靴槽；链占用+靴失败；未重跑） |
| 3 | RDMA 跨机延迟探针（对角 10.0-10.2µs / 直连 8.47µs 锚） | **PENDING**（同上） |
| 4 | census 桶形状（主判据）：6.732ms±0.3、138.6±5%/步、三分量在带 | **PENDING 且结构性红预警**：gates=0/0 下 RoceOneshot/RoceAG 两族**不可能出现**，全 NCCL 桶按 §8.2 判据 4 必读红——除非先经 B11/A22 武装 RoCE 面，否则 ζ 量具靴的 census 只能确证缺口而非通过 |
| 5 | 单机窗边界剔桶规则 | 本日为四机靴尝试，不适用 |

## 4. 12:19 崩溃法证裁定

**证据保全说明**：~/l10-incident/\*.exit.log 四件已被 12:43 δ 链 cleanup **同名覆盖**（现时间戳 12:43:34-37）；12:19 原始 head 日志以 logs/A23-DELTA/container-head.log（12:22 落盘，md5 3d7e578b，与 12:43 件 34c440fc 不同）+ chain.log:1-192 全史补全。12:43 件=head.exit.log==container-head-attempt2.log（md5 34c440fc）。

**双靴同签名**（12:18:07→12:19:20 rc=1；12:42:31→12:43:38 rc=1）：
1. 四模型模块 import 期 adapter 守卫 raise：`[prefill_sp] … DeepseekV4DecoderLayer.self_attn missing; refusing to boot (layer-carry seam moved)`（head.exit.log:79/185/189/193；container-head.log 同 4 处）——P-SP stage1 的 layer-carry 接缝在 main-79cafece 已漂移，适配器按设计 fail-closed 拒装；
2. SGLang 回退 Transformers 实现（"DeepseekV4ForCausalLM has no SGLang implementation, falling back…"）；
3. head **父进程**（tokenizer manager→多模态 processor init）致命栈：`AttributeError: TokenizersBackend has no attribute tokenizer`（transformers_auto.py:64→base_processor.py:134；首崩者有完整 Python 栈）；
4. 三 worker（02/03/04）日志止于 `Init parallel begin.`，无栈——被 kill_process_tree 连坐，是果非因。

**三问**：(1) 是 init 阶段崩溃（模型 import + tokenizer/processor 初始化期，与各秩 Init parallel begin 并行），首崩者=head 父进程且有完整 Python 栈；(2) RoCE/QP/modify_qp/errno 61/GID 迹象：四件日志 grep 计数 **全 0**；(3) OOM/UMA 迹象：**0**（唯一大小写匹配行=server_args 转储中 `enable_unified_memory': False`，良性）。

**裁定**：**既非已知 mesh 单元竞态（§5.3 签名=tc 空+RTR 超时——今日 tc in_hw 且 fabricctl F00-F09 全绿），亦非环网面落实缺口（崩溃先于任何 NCCL/RDMA 通信子建立，fabric 层四机实测健康）。** 定性=δ 臂移植缺陷（架构性，但属 PREFILL_SP stage1 接缝，不属通讯面）：接缝守卫按设计拒装 + Transformers 回退路径的 TokenizersBackend API 不兼容把拒装掩蔽成无关致命错。对用户问题方向：**12:19/12:43 崩溃对"环网面是否落实"不构成反证；倒是暴露 P-SP 移植需先修接缝并考虑让回退路径显式红而非错位崩。**

## 5. §8.1 census 桶形：PENDING

不采——活靴槽归 δ 链（且链靴失败，无靴可用）。载体=下一次 ζ 量具靴。锚=三分量 6.732ms±0.3 / calls 138.6±5%/步（fin2 旧基座口径；新基座允许族构成漂移，但 **RoceOneshot/RoceAG/RING_LL 三族必须在**）。与第 3 节判据 4 联动：gates=0/0 未解前，该 census 的可判结论只有"确证 RoCE 面缺席"。

## 6. 三色总结

**绿（已落实有据）**
- D5 宿主三件四机：mesh 单元 active、hairpin 8192、tc in_hw、marker attached、GID idx3 16/16 对黄金拓扑（fabricctl：01/02 22/22，03/04 21/22 仅非通讯面 F10）。
- NCCL 库面：NCCL_ALGO=RING + 4 HCA + GID_INDEX=3 + TOS=46 + TUNER=40960 + LD_PRELOAD(ncclpin+盖写 pip 路径) + deep_ep 二进制级单一性断言（未压制）。
- ROCE_IDLE_SPINS=2×10⁷ 编译期内建于 b12x 双树；adapter 通讯五文件四机 md5 全等。
- D1 代码件与仪表（gates 横幅、拒装 raise、RoCEnante ready 横幅源 ×3 变体）已在树；b12x 计算面运行期实活。
- 12:19/12:43 崩溃与环网面无关（法证三问全阴性）。

**黄（部分/证据缺失）**
- GID 键名偏差（FORCE vs 裸键，功能等价、内核 1031 观察项）；NCCL_VERSION=2.28.3-1 陈旧标签。
- D3 运行期 `nccl==2.30.7` 横幅新基座无样本；系统 2.28.3 仍在镜像（回退风险靠 preload 关断，未见断言样本）。
- D4 roce_gather 断言惰性非计数；l2pf 按判负不部署=预期态。
- 03/04 fabricctl F10（NFS automount 前缀，已知项）；12:19 法证原件被覆盖（已用 container-head.log 补全）。

**红（缺口）**
- **§6 RoCE 面键族（DSV41_ROCE_RING/SGLANG_ROCE_ALLREDUCE/SGLANG_ROCE_MAX_SIZE=2097152/DSV41_ROCE_GATHER=524288 + B12X_ROCE_\*）在采纳臂 γ1（生产候选）与现行 δ 臂整体缺席**——`[roce_ar] gates=0/0` 四秩双靴实证，RoCEnante AR 面在新基座从未武装；A2-C1 四机首靴 DOA，机制未测。**生产候选臂落实缺口，单独标红**（登记态：B11→A22，非遗忘）。
- §8.2 判据 1 的横幅半边未复现；判据 4 在面武装前结构性不可能过。

**总结论**：环网通讯面的**基座两层（fabric 数据面 + ring-only NCCL 库面）落实到位且有四机实证**；**第三层 RoCEnante 用户态核面只完成了"代码+仪表"半边，武装半边（env 键族入臂）在生产候选臂 γ1 未落实**，且 census 主判据因此被封死在结构性红。12:19/12:43 崩溃是 δ 臂 P-SP 接缝缺陷，与环网面无关。建议顺序：修 P-SP 接缝 → A22 按 B11 武装 RoCE 面四机复跑 → ζ 量具靴过 §8.2 全链。

---

### 证据索引
- 横幅：logs/A23-DELTA/chain.log:322；~/l10-incident/{head,worker-dgxspark0{2,3,4}}.exit.log（gates 行号 35/79-118/150 等）；12:19=logs/A23-DELTA/container-head.log:35/114/120/150
- 靴脚本：~/migrate-assets/bin/r3-boot-arm.sh（COMMON_ENV :124-191；资产核验 :101-110；挂载 :113-123；LD_PRELOAD :138；arm 注入 :200-207）
- 臂：arms/A23-DELTA-spec1.env、arms/A21-GAMMA1-spec1.env（均零 RoCE 键）；A2d-C1-spec1.env:5-11（RoCE 全键）；fin2 .env.tp4:67/:87
- adapter：sitecustomize.py:155-179（roce 挂装门）、:573-579（gates 横幅）；roce_ar.py:37/76-77/114/135/186/202/241；roce_gather.py:14-45
- b12x：b12x_next/comm/roce/_roce_proxy.c:48、b12x/comm/roce_ring/_roce_proxy.c:47（IDLE_SPINS=2×10⁷）；roce_oneshot.py:351/352/390（ready 横幅）
- 镜像（192.168.5.187:5000/lmsysorg/sglang:main-79cafec0）：无 /opt/b12x；libnccl=pip libnccl.so.2（靴时盖写 2.30.7）+ /usr/lib/aarch64-linux-gnu/libnccl.so.2.28.3；deep_ep/__init__.py:54/:91
- 宿主：/etc/systemd/system/dsv41-mesh.service（hairpin 8192→qos pcp→mesh-up 次序）；/opt/dsv41-mesh/topology.json（黄金态 09-28 采集）；fabricctl=~/dsv41-flash-dgxsparks/scripts/ring_mesh/fabricctl（check 只读）
- 决策档案：docs/MASTER-GAP-CLOSURE-PLAN-20261002.md:47（B11）；docs/verdicts/A2-C1-roce-20260930.md（DOA 非机制判负）
