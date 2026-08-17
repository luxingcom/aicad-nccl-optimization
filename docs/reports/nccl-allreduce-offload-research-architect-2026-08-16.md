# TP4 小消息 allreduce 执行机制 + 网卡卸载（In-Network Offload）可行性调研

**日期**：2026-08-16
**作者**：Archi（系统架构师）
**性质**：只读调研（WebSearch + 社区/官方论坛，不动服务器）
**输入**：findings-raw-2026-08-15（环境数据包）/ nccl-small-msg-trtllm-bypass-architect-2026-08-16（TRT-LLM bypass 报告）/ nccl-latency-head-balance-architect-2026-08-16（head 均衡报告）/ nccl-tuner-implementation-architect-2026-08-16（tuner 实施文档）+ 本轮官方文档/论文/社区调研
**约束**：4×DGX Spark（GB10 UMA 121.6GiB，SM121），环网 4 边双 200G RoCE（无交换机直连，对角无直连），NCCL 2.30.7 ring-only v3 定制补丁 + PEER_HCA 双 dev 轮换 + GID=3；vLLM 0.26 TP4（DSV4-Flash，43 层/MLA/fp8）；decode 每 step 87 次 1-16KB allreduce，每 call 55-80µs

---

## 0. TL;DR（先给结论）

1. **谁执行**：87 次 allreduce 由 **4 台服务器各自 rank 的 NCCL 实例协同完成**——**没有**"某一台服务器负责归约"。数据路径为 **GPUDirect RDMA（GPU→NIC→RoCE→NIC→GPU）**，**归约算术在 GPU SM 上执行**（NCCL kernel），**CPU proxy 只做网络控制面**（post WQE/轮询 CQ/处理 CTS），**不碰数据**。vLLM 调用链：`tensor_model_parallel_all_reduce → PyNccl → ncclAllReduce`（CUDA graph 捕获期走 PyNccl）。head（01）仅初始化期特殊（ncclUniqueId/TCPStore），每步数据面四 rank 完全对称。
2. **执行模式**：4-rank ring allreduce = **ReduceScatter(3 步) + AllGather(3 步) = 6 个串行网络步**，既不是"串行汇总再分发"也不是真正的流水（1-16KB 单 chunk、单通道，就是 **6 次直连跳**的串行链）。每 rank 收发总量 = 2(n-1)/n×S = **1.5×消息大小**。物理环 01-02-04-03 = 逻辑 0-1-2-3，**每一步都落在直连边上（无 2 跳转发）**，浪费不在"跳数"而在"6 步串行 × 每步固定延迟"。87 次全部在严格数据依赖关键路径上，**不可批量合并、不可跨层重叠**（CUDA graph 单 stream 串行）。
3. **优化空间**：仍有三块肥肉——**步数 6→4**（Tree 或 2-hop 广播）、**协议层（已定案 tuner 插件 LL for ≤40KB）**、**计算-通信重叠**（vLLM 0.26 decode 无跨层重叠，暴露度待 P0-1 归因）。已用尽项：双口并行（PEER_HCA v3）、通道数（MAX_CH16）、消息合并（依赖序锁死，不可行）。
4. **网卡卸载（核心）判定：本环境硬件上不具备任何 in-network allreduce offload 条件。** 三重否决：
   - **无汇聚点**：SHARP 类卸载的前提是 fabric 中存在执行归约的中间设备（IB Quantum 交换机 / NVSwitch）。本环境 4 机 RoCE **直连无交换机**，物理上不存在归约位置；
   - **网卡模式锁死**：DGX Spark 的 ConnectX-7 在固件层被锁定为 **Ethernet-only（RoCE），InfiniBand 模式禁用（LINK_TYPE 锁定）**，而 ConnectX-7 的 SHARP 端点能力恰恰属于 IB 模式（datasheet 将 SHARP 列在 "Enhanced InfiniBand Networking" 之下）；
   - **SHARP over RoCE 官方尚不存在**：NVIDIA 至今未在 Spectrum 系列以太网交换机提供 switch-resident 归约引擎（Spectrum-X 的加速 = 动态路由/拥塞控制/DDP，不是归约）；"SHARP on Ethernet" 只出现在未来/他类产品线（Quantum-X IB 的 SHARPv4、Rubin NVLink6 的 in-network compute），均非当前可用。
   - 即使未来上 200GbE 交换机（NVIDIA 官方对 4 节点 TP4 推理的推荐拓扑），**RoCE 上仍无 SHARP**，收益来自"对角直达 + Tree/CollNet 思路 + 全互联"，而非 offload。
5. **最优替代**（结合 tuner 插件现状）：**P0 tuner 插件（≤40KB→LL，已定案）→ P1 2-hop 小消息 allreduce kernel（6 步→2 相位，10-20µs）→ P2 交换机拓扑（结构性）**。其中 P1 的"GPU 发起 RDMA"可用 **GDAKI（NCCL 的 DOCA GPUNetIO 集成，CUDA 12.x+）** 或 NVSHMEM 实现，这是比"卸载到网卡"更现实、且本环境唯一能真正把 6 步串行打掉的路径——注意它是"GPU 发起"，**归约仍由 GPU 做**，不是 offload，但效果（砍掉串行步数）正是 offload 想达成的。

---

## 1. 问题 1：allreduce 执行者——谁处理？哪台服务器？CPU 还是 GPU？数据路径？

### 1.1 vLLM → PyNccl → NCCL 调用链（TP4，mp 后端）

```
vLLM model layer (attn/MLP 输出)
  → tensor_model_parallel_all_reduce(input_)          # vllm/distributed/communication_op.py
      ① custom_all_reduce(input_)   → 跨节点必返 None（硬性要求同节点 + NVLink）
      ② PyNccl（CUDA graph 捕获期启用）
         → pynccl_utils.all_reduce → ncclAllReduce（ncclComm_t, stream=当前 CUDA stream）
      ③ torch.distributed.all_reduce（仅 eager 模式；graph 模式禁用）
```

- **graph 模式**（生产 TP4 启用 CUDA graph）：allreduce 走 **PyNccl→ncclAllReduce**，被冻结进 CUDA graph；重放期不再走 host API，由 graph 内 NCCL kernel 重放 + host proxy 重新 post 网络操作。
- 来源：vLLM communication_op.py 源码（graph 模式分层约束表 "PyNccl | enabled"）、DeepWiki《Custom AllReduce and Communication》《Communication System》。

### 1.2 执行者拆解（NCCL 机制）

一次跨机 allreduce 由"每个 rank 本地的一份 NCCL 实例"协同完成，每份实例含两个执行主体：

| 主体 | 位置 | 职责 | 是否碰数据 |
|---|---|---|---|
| **NCCL GPU kernel** | GPU SM | 对收到的 chunk 做本地归约（sum）、flag 更新、内存 fence | **是——归约算术在这里** |
| **CPU proxy 线程** | CPU（每 rank 1 个，绑核 8-9） | post RDMA verbs（isend/iwrite）、轮询 CQ、处理 CTS 控制消息、管理 QP/FIFO、推进状态机 | **否（GDR 下数据不经过 CPU）** |

- **数据路径（GPUDirect RDMA，Simple/正常路径）**：
  ```
  GPU send buffer → [NIC DMA 直读 GPU 内存] → RoCEv2 链路 → 远端 NIC DMA 直写 GPU recv buffer → NCCL kernel 归约 → 输出
  CPU proxy 只 post WQE/轮询，不搬运字节
  ```
- **控制路径永远过 CPU**："网卡能直接读写 GPU 内存 ≠ GPU 能直接发起 RDMA"。QP/CQ/WR/rkey/CTS 由 CPU proxy 管理。一次 RDMA 完成还有 **flush**（CPU 轮询 CQ 后发 loopback RDMA_READ 确认 PCIe write 已到达 GPU）。
- 来源：arXiv 2507.04786《Demystifying NCCL》（IB transport 图 2：GDRDMA 时中间缓冲在 GPU 内存、proxy 负责 RDMA 操作）、NCCL 论文阅读笔记（51CTO）、CSDN《用于 NCCL 的 GPU 发起网络》（GDAKI vs proxy 架构对比）。

### 1.3 哪台服务器？——四台对称，无单点

- TP4 = 4 台服务器各 1 rank（每机单 GPU）。**所有 4 个 rank 同时发起各自的 ncclAllReduce**，环上每个 rank 从 prev 收、向 next 发、本地 reduce。**不存在"汇总服务器"**。
- **head（<node1> / rank0）的特殊性只在初始化期**：`ncclGetUniqueId`（rank0 生成）→ TCPStore/Gloo 广播 → `ncclCommInitRank`。**每 step 数据面 head 与其他 rank 完全对称**（ring 对称性，见 head-balance 报告：每 rank 收发 1.5S，四口 32/32 均衡）。
- 归约最终结果是**集体计算**：reduce-scatter 阶段每个 chunk 环游 4 个 rank 依次累加，全部 GPU 的 SM 都参与了一部分加法。

### 1.4 GB10 UMA 特殊性（对数据路径的影响）

- DGX Spark 的 GPUDirect RDMA 与传统独显路径**不完全相同**：传统 nvidia-peermem/PCIe BAR 映射机制在 GB10 上并非主要路径；由于 **CPU/GPU 共享同一物理 LPDDR5X（UMA）**，NIC DMA 直接写入的就是 GPU 可访问的同一内存，**天然 zero-copy、无 bounce**，实测证实"无额外 staging 拷贝"。
- 对 **LL 协议**（host buffer + CPU 轮询 flag，禁 GDR）而言：UMA 下"host buffer"就是 GPU 同池内存，**架构上抵消了 LL 的 host 惩罚**——这正是 tuner 插件切 LL 能赢 28-34% 的硬件前提（已由阈值扫描实证）。
- 来源：hardware-corner《Hacker Unlocks 3-Node DGX Spark Clustering》（UMA 下 RDMA 写入即 GPU 可访问内存）、STH DGX Spark 拆解（ConnectX-7 PCIe Gen5 x4×2、UMA）、previous TRT-LLM bypass 报告 §1.4。

---

## 2. 问题 2：执行模式——"串行汇总再分发"还是"环状流水"？6 步的物理含义？拓扑感知？87 次能否重叠？

### 2.1 ring allreduce 的物理含义（不是"串行汇总再分发"）

4-rank ring allreduce 精确分解：

```
阶段 1 ReduceScatter（3 步）：把 S 分成 4 个 chunk，chunk 沿环前传，每跳累加
  步 1-3：每个 rank 每步向 next 发 1 个 chunk、从 prev 收 1 个 chunk 并累加
  3 步后：每个 rank 持有 1/4 的"完全归约结果"
阶段 2 AllGather（3 步）：4 个完全归约 chunk 沿环复制扩散
  步 4-6：每个 rank 把自己持有的 chunk 发给 next，同时收 prev 的 chunk（纯拷贝）
  3 步后：所有 rank 拥有完整归约结果
总步数 = 2(n-1) = 6；每 rank 收发总量 = 2(n-1)/n × S = 1.5S
```

- **不是"一台汇总再分发"**：那是 reduce-then-broadcast（star 模型）。ring 是**分片循环累积 + 分片循环分发**，所有节点每步都在收发。
- **也不是传统意义上的"环状流水"**：对 1-16KB 小消息，NCCL 用**单 chunk（整个消息不分片）+ 单通道**，不存在多 chunk 流水；6 步就是 **6 次串行直连跳**。每步延迟 ≈ 协议固定开销（Simple ~6µs/跳、LL ~1µs/跳）+ RDMA 往返 + 同步/launch。**小消息的瓶颈 = 步数 × 每步固定延迟，不是带宽**。
- 每步的物理内容（1 跳）：RDMA_WRITE 数据 + RDMA_WRITE_WITH_IMM 完成通知（正向 QP）；CTS 控制消息走反向 QP（rendezvous：收发双方先同步 buffer 就绪）。
- 来源：NCCL 官方文档（collectives）、arXiv 2507.04786（QP 布局、CTS）、til.codes / SimCCL（6 步分解）、dl1683.github.io《GPU All-Reduce》。

### 2.2 拓扑感知——NCCL 在纯环下"知道"什么

- NCCL 初始化构建拓扑图（GPU/NIC/PCIe switch 位置、带宽、延迟），据此选 algo/proto、建 channel、为每 peer 选 NIC（`PEER_HCA` 补丁接管此处）。
- **对 ring 算法**：NCCL 只需一个 rank 顺序。本环境逻辑 0-1-2-3 = 物理 01-02-04-03，**6 步全部落在 4 条直连边上**（0→1、1→2、2→3、3→0 都是直连），**NCCL 不产生 2 跳转发**。"对角无直连"对 ring 无影响（对角本就不是 ring 边）。
- **NCCL 不感知的**：物理上"对角缺失"这件事对 Tree / CollNet / NVLS 类算法才有意义（这些算法假设任意对可达/交换机存在）。ring-only 补丁禁掉这些算法后，拓扑感知退化为"每 peer 选哪个 dev"（已由 PEER_HCA 处理）。
- 纯环 + ring-only 下，NCCL 的"拓扑感知"收益已耗尽——剩余优化要么换算法（Tree/2-hop，需补丁扩展），要么换物理拓扑（交换机）。

### 2.3 87 次的可重叠性

- 87 次 = 43×(attn allreduce + mlp allreduce) + 1×embedding allreduce，全部落在严格串行关键路径：`AR_mlp_i → 残差+norm → layer i+1 输入`。**第 i+1 层必须等第 i 层归约完成**。
- **CUDA graph 模式**：decode 各 kernel（GEMM/NCCL allreduce/norm）捕获进**单一 stream 的图**，执行严格按依赖序串行——**无跨层重叠、无 allreduce 与相邻计算的并发窗口**（vLLM 0.26 未做 TRT-LLM 式多 stream 层间流水）。
- **"计算-通信重叠"的实际状态**：历史 A/B（Simple vs LL 对 E2E 仅 -2.7%~-9.8%）说明 **GB10 decode 计算/内存带宽主导、通信净暴露有限**——不是 vLLM 做了 overlap，而是通信占比本身较小且部分被 GPU 吞吐隐藏。真实暴露度需 P0-1 归因（nsys/NCCL_DEBUG=TRACE）后才能定标。
- 来源：previous TRT-LLM bypass 报告 §3.1（依赖图分析）、vLLM communication_op graph 模式源码。

---

## 3. 问题 3：优化空间（四台服务器在此环节还能做什么）

| 方向 | 现状 | 剩余空间 | 优先级 |
|---|---|---|---|
| **ring 步数 6→4** | 6 步串行（小消息延迟主因） | **Tree（double binary tree）4 步** 或 **2-hop 广播（2 相位）**；ring-only 补丁需扩展 | P1/P2 |
| **双口并行** | ✅ 已用尽（PEER_HCA v3 双 dev 轮换，13.9→23.86 GB/s） | 小消息对双口不敏感（带宽无关） | 已做 |
| **通道数** | ✅ 已用尽（MAX_CH16 / MIN_CH4；小消息 NCCL 自动少通道） | 无 | 已做 |
| **协议层（per-size）** | 全局 Simple（T1aM4）牺牲小消息 | **tuner 插件 ≤40KB→LL**（实测 44.6-54.3µs，-28~34%）| **P0 已定案** |
| **消息合并 87→N** | 不可行（依赖序锁死） | 无 | 排除 |
| **计算-通信重叠** | vLLM 0.26 无跨层 overlap | 需 P0-1 归因定暴露度；P1 kernel 可顺带做 allreduce+norm 融合 | P1 |
| **物理拓扑** | 环网直连、对角 2 跳 | **200GbE 交换机**（NVIDIA 官方推荐 TP4 推理拓扑）：对角直达 + Tree/CollNet 思路 + 消除环上限 | P2 结构项 |

> 核心判断不变：**decode 小消息的杠杆 = "减少步数 × 次数" 与 "降每步延迟"，不是带宽**。已用尽 env 层参数空间（head-balance 报告 P0/P1 全部覆盖），下一波收益必须来自 算法/协议/kernel/拓扑 四个层面。

---

## 4. 问题 4（核心）：网卡卸载（in-network compute / SHARP）可行性

### 4.1 SHARP 的三种形态与本环境对照

| 形态 | 归约执行位置 | 硬件前提 | 本环境（4×DGX Spark 直连环网） |
|---|---|---|---|
| **IB SHARP**（in-switch reduce） | Quantum 系列 **InfiniBand 交换机** ASIC 内 | Quantum/Q-2/Q-3 交换机 + ConnectX-6+ + nccl-rdma-sharp-plugins + sharp_am(Aggregation Manager) + 子网管理器 | **✗ 无 IB 交换机、无 IB fabric、CX-7 IB 固件锁定** |
| **NVLink SHARP（NVLS）** | **NVSwitch** 内（第三代 NVSwitch，Hopper+） | 机内多 GPU + NVSwitch（NVL72 类） | **✗ DGX Spark 单 GPU、无 NVSwitch**（NCCL_NVLS_ENABLE=2 自动禁用） |
| **SHARP over Ethernet/RoCE** | 无（官方不存在） | Spectrum-X 只有动态路由/拥塞控制/DDP，**无 switch-resident 归约引擎** | **✗ 不存在；且本环境连交换机都没有** |

关键证据：
- **NVIDIA SHARP 用户手册**（Rev 3.14）：setup 要求"Run NVIDIA Switch-IB 2 / Quantum / Quantum-2 switches with supported firmware"，AM 运行在管理服务器，支持的设备表仅列 Quantum/Q-2/Q-3 与 ConnectX-6+（IB 模式）。[docs.nvidia.com SHARP 手册]
- **nccl-rdma-sharp-plugins** 官方 README/Wiki 要求："**Mellanox ConnectX 6 HCA and Mellanox Quantum IB switch with SHARP support**"；启用靠 `NCCL_COLLNET_ENABLE=1` + `NCCL_ALGO=CollNet`。→ **RoCE 无 CollNet/SHARP**。[github.com/Mellanox/nccl-rdma-sharp-plugins]
- **CoreWeave 生产文档**：明确 "NCCL's built-in InfiniBand verbs transport ... has **no SHARP path**"；"**The No Aggregation Manager sharp_am detected** line reports that fallback on InfiniBand **as well as RoCE**"。→ 即便有插件，无 AM 的 RoCE fabric 也回退。[docs.coreweave.com NCCL configuration reference]
- **ai-infrastructure.net《SHARP: in-network reduction》**："As of writing **SHARP is primarily an InfiniBand technology**. Spectrum-X improves all-reduce with congestion control and adaptive routing **but does not expose switch-resident reduction engines** analogous to SHARP."；"Small clusters (two-to-four nodes) ... the offload barely registers."；"Not worth it (or unavailable): Ethernet / RoCE fabrics."
- **NVIDIA 官方**：Quantum-X800（IB）明确 SHARPv4 14.4 TFLOPS 网络内计算；Spectrum-X800（以太）官方列出的能力为自适应路由/拥塞控制/安全——**未宣称交换机内归约**；NVLink6（Rubin 代）才把 SHARP in-network compute 放进 NVSwitch。→ **"SHARP on Ethernet" 至今不是 Spectrum 系列产品能力**。[NVIDIA Developer Blog《Inside the Vera Rubin Platform》《Networking Switches for GPU Computing》]

### 4.2 ConnectX-7 / 8 能力核查（本环境网卡）

| 项 | 结论 | 证据 |
|---|---|---|
| 本机网卡型号 | **ConnectX-7 OCP3.0 2×200GbE（Ethernet-only 固件）**，Socket Direct → 4 个逻辑 RoCE 口（rocep1s0f0/f1 + roceP2p1s0f0/f1），两条 PCIe Gen5 x4（lspci 0000:01:00.0 / 0002:01:00.0） | STH《The NVIDIA GB10 ConnectX-7 200GbE Networking is Really Different》；丽台配置指南（4 逻辑端口原理） |
| SHARP 端点能力 | **属于 IB 模式能力**：ConnectX-7 datasheet 将 "Collective operations offloads / Support for NVIDIA SHARP" 列在 **Enhanced InfiniBand Networking** 章节；Ethernet 章节只有 RoCE/ASAP2/加密 | ConnectX-7 datasheet / Lenovo LP1693 |
| DGX Spark 的 CX-7 是否可用 IB | **不可用**：InfiniBand 在固件层被禁用（LINK_TYPE 锁定，硬件支持但仅限 Ethernet）；社区（NVIDIA AI LinkedIn）已证实 | LinkedIn NVIDIA AI #sparksomethingbig 讨论；resilient-tec 指南（"QSFP ports operate in Ethernet mode (with RoCE), not InfiniBand"） |
| ConnectX-8 | 支持 SHARP（IB 模式）+ 更高带宽；**与 Spectrum-X 搭配的 "SHARP" 仍非当前 RoCE 归约引擎** | NVIDIA 官方 datasheet / 手册 |

**结论：本机网卡是"Ethernet-only 的 ConnectX-7"，其 SHARP 能力（属于 IB 模式）已被固件禁用；即便未禁用，无 IB 交换机也无从卸载。ConnectX-8 同理不改变本环境结论。**

### 4.3 无交换机直连对 offload 的硬性否决

- SHARP 类卸载的**物理前提是 fabric 内存在归约汇聚点**（交换机 ASIC 或 NVSwitch）。本环境 4 机 **1:1 直连（无交换机）**，数据包在任何中间节点都不会"相遇"，**没有可以执行归约的硬件位置**。
- 社区 4 机直连环网实测（Dre Dyson）亦佐证：ring 拓扑对 TP 工作负载 "Do not use ... The latency penalty for non-adjacent nodes is a dealbreaker"——直连无交换机的结构天花板真实存在。

### 4.4 NVIDIA 官方立场：4 机 RoCE 直连做 LLM 推理

- **GTC 2026 官方博客（Scaling Autonomous AI Agents with DGX Spark）** 明确四档推荐拓扑：
  - 1 节点：低延迟/大上下文推理（≤120B）；
  - 2 节点直连：均衡扩展（≤400B）；
  - **3 节点 ring：面向更大模型微调/小型训练**；
  - **4 节点 + RoCE 200GbE 交换机：本地推理服务器，面向 ≤700B / 通信密集工作负载 / 本地 AI 工厂**。
  → **NVIDIA 官方对"4 节点 TP4 通信密集 LLM 推理"的推荐拓扑就是交换机，不是直连环网**；直连 4 节点不在官方支持矩阵内（官方 playbook 只到 connect-three-sparks / multi-sparks-through-switch）。
- **官方 playbook**：`connect-three-sparks`（3 机 ring）、`multi-sparks-through-switch`（4 机经交换机，200G/口，需手动设 200G 速率、关自协商）。[build.nvidia.com]
- **NVIDIA 论坛实证**：4×DGX Spark + MikroTik CRS812 交换机 + RoCE，NCCL busbw 2.12→9.78 GB/s（4.6×）、Qwen3-235B EP4TP4 吞吐 34.6→65.4 tok/s（1.88×）——RoCE 走对 vs TCP 回退的巨大差距；Qwen3.5-397B 4 机 TP4 稳定运行。[NVIDIA Developer Forums]
- **GB10 集群通信设计文档**：无独立"GB10 通信设计白皮书"；官方信息集中在上述博客 + playbooks + DGX Spark 规格页（ConnectX-7 NIC @200G、NCCL/RDMA/GPUDirect 列为特性）。社区资料（STH/丽台）补充了 Socket Direct/4 逻辑口/PCIe Gen5 x4 带宽上限等硬件事实。

### 4.5 社区实践（与 offload 相关的真实案例）

1. **3 机直连 mesh 自定义 NCCL 网络插件**（r/LocalLLaMA，hardware-corner 报道）：开发者写 ~1500 行 C 的 NCCL net 插件（subnet-aware NIC 选择 + 直接 libibverbs QP/MR），绕开"同一共享子网"假设，3 机直连 allreduce ~7.4-7.6 GB/s（~60-65% 线速，无 PFC/ECN）。**证明直连多机可行但需软件重写，且带宽仍受无交换机限制**。→ 对本环境 P1 2-hop kernel 是正面参照。
2. **4 机无交换机方案横评**（Dre Dyson）：ring / 光纤 breakout / H-cross-connect / 交换机四种方案实测，**ring 对 TP 判定不可用**（非相邻节点多跳延迟 + 中继瓶颈），交换机为唯一实用路。
3. **容器化 RDMA 陷阱**：`--network=host` 不传递 `/dev/infiniband/*`，NCCL 静默回退 NET/Socket（2 GB/s）；需显式 `--device=/dev/infiniband/...`。[NVIDIA Forums container-native thread]
4. **RoCE vs TCP 4.6×**（前述论坛帖）——本环境已用 RoCE + GID=3 规避同类回退。

### 4.6 "把归约放到 GPU 而非网卡"的替代路径：GDAKI / GPU 发起 RDMA

- **NCCL 已集成 GDAKI（GPU Direct Async Kernel Init，基于 DOCA GPUNetIO）**：GPU kernel 可直接 post RDMA（QP 门铃/内存可见），消除 CPU proxy 热路径开销；架构上属 **"GPU 发起网络"（GIN）**，归约仍在 GPU/端点，**不是 offload**，但对小消息可省 ~15µs/op 级 proxy 开销（NCCL EP 口径）。
- 触发条件：ConnectX-6+ NIC（✓ CX-7）、CUDA 版本、DOCA GPUNetIO 在容器内可用。**是否在 GB10 + CUDA 13 + 驱动 580.173 + 容器内可用需现场核实**（`NCCL_DEBUG=INFO` 看 GIN/GDAKI 日志）。
- 对本环境意义：**P1 2-hop kernel 的首选实现路径**（GPU 侧 post 2 相位 RDMA 广播），比 NVSHMEM 更贴近 NCCL 管线；即使不用它，也说明"低延迟小消息"的正确技术方向是 GPU 发起 + 少步数，而非幻想把归约塞进网卡。

---

## 5. 问题 5：结论——本环境硬件是否具备网卡卸载条件

### 5.1 判定：**无。**（三重硬性否决 + 一条软件替代）

```
[硬件条件核查]
① 归约执行位置（switch/NVSwitch）     → 无：4 机直连无交换机，单机单 GPU 无 NVSwitch
② 网卡 SHARP 端点（ConnectX-7）       → 无：IB 模式固件锁定（Ethernet-only），SHARP 属 IB 能力
③ SHARP over RoCE / Ethernet          → 无：NVIDIA 官方未在 Spectrum 提供 switch 内归约引擎
④ NVLink SHARP（NVLS）                → 无：NCCL_NVLS_ENABLE=2 在无 NVSwitch 系统自动禁用
⇒ 网卡/交换机 in-network offload：不可行（本环境）
```

> **一句话**：要"把 allreduce 卸载到网卡"得满足"网卡/交换机能做归约"+"fabric 有汇聚点"两个前提，本环境两个都不成立——网卡是 Ethernet-only（IB SHARP 端点被锁），fabric 是 4 机 1:1 直连（连交换机都没有），且 NVIDIA 至今没在 RoCE 上提供 switch-resident 归约。

### 5.2 本环境该环节的最优替代（结合 tuner 插件现状）

| 优先级 | 手段 | 预期（每 call） | 现状/备注 |
|---|---|---|---|
| **P0（已定案）** | **NCCL tuner 插件：≤40KB→LL / >40KB→Simple** | 55-80µs → **44.6-54.3µs**（实测 -28~34%）；每 step 通信 5.2→~4.2ms | 见 tuner 实施文档；先做 CUDA graph 前置专项（fix72 教训） |
| **P1** | **2-hop 小消息 allreduce kernel**（6 步→2 相位；ring-only 补丁新增算法，或 vLLM 层 NVSHMEM/**GDAKI**） | → **10-20µs**（去掉 6 步串行） | GPU 发起 RDMA + 本地归约；CUDA graph 兼容需专项验证 |
| **P1/P2** | **Tree 使能**（ring-only 补丁扩展） | 6→4 步，小消息 -33% | 需先确认补丁是否支持 Tree（bench 试 `NCCL_ALGO=Tree`） |
| **P2（结构项）** | **200GbE 交换机拓扑**（NVIDIA 官方对 4 机 TP4 推理的推荐） | 对角直达 + Tree/CollNet 思路 + 全互联；消除环上限 | 硬件采购/迁移窗口；**注意 RoCE 上仍无 SHARP**，收益是拓扑而非 offload |
| 长期 | vLLM 0.27 序列并行 / NCCL GIN（GPU 发起）演进 | 通信频率结构性下降 | 受 flashinfer SM120 缺陷阻塞（0.27 不切换） |

**替代策略的核心逻辑**：既然"卸载到网络"不可行，就把"6 步串行"这个真正的延迟来源打掉——协议层（LL）先吃到 30% 左右（已定案、零 kernel），算法层（2-hop）再吃 60-75%（P1），拓扑层（交换机）作为结构性终局（P2）。tuner 插件是这条线的**第一步**，不是终点。

### 5.3 与 tuner 插件现状的衔接（避免重复建设）

- tuner 插件解决的是"协议层每跳固定延迟"；**不解决 6 步串行**。二者收益可叠加（插件实测 LL 44.6µs → 2-hop 理论 10-20µs）。
- 部署纪律不变：上插件必须删 `NCCL_PROTO=Simple`；`NCCL_ALGO=RING` 可保留（ring-only 库）。
- 若 P1 走"ring-only 补丁新增 2-hop 算法"，插件可顺带通过 cost table 让 ≤40KB 走 2-hop、>40KB 走 ring/Simple——**per-size 算法+协议双维路由**是插件接口本来就支持的（getCollInfo 含 numAlgo/numProto）。

---

## 6. 需现场核实项清单（给执行角色的下传件）

1. **网卡型号与模式**：`lspci -nn | grep Mellanox`（预期 0000:01:00.0 / 0002:01:00.0 两个 ConnectX-7 设备）；`mstflint -d <dev> q | grep -i link_type` 确认 **Ethernet-only 固件**；`ibstat`/`ibdev2netdev` 看 4 个 RoCE 口。
2. **NCCL proxy / GDR 行为**：测试容器 `NCCL_DEBUG=INFO` 确认 `NET/IB` + RoCE 端口选择；`NCCL_DEBUG=TRACE` 统计每次 allreduce 的 size/通道数/协议选择（P0-1 归因，同时验证 tuner 插件选路）。
3. **NCCL 插件装载路径**：`nm -D <libnccl.so> | grep -i tuner`；`NCCL_DEBUG=INFO` 看 "Successfully loaded tuner external plugin"（tuner 实施文档 S0）。
4. **GDAKI 可用性**（P1 路径）：`NCCL_DEBUG=INFO` 看是否出现 GIN/GDAKI 相关行；容器内 `ldconfig -p | grep -i gpunetio\|nvshmem`；`python -c "import torch; print(torch.cuda.nccl.version())"` 确认 2.30.7 + CUDA 版本。
5. **NVLS/offload 可行性再确认**（一次清零）：`NCCL_DEBUG=INFO` 看是否出现 "NVLS not supported" / "LL128 not supported" 等自动禁用日志；`NCCL_NVLS_ENABLE=2` 下运行 torch.distributed 无异常即可。
6. **环网每跳延迟**：`ib_write_lat`/`ib_read_lat` 四条边各测一次（1-16KB），为 2-hop kernel 的 10-20µs 理论提供实测锚点。
7. **CUDA graph + LL 前置专项**：测试容器全局 `NCCL_PROTO=LL` + 全档 capture（1..64），验证 capture 成功/TPOT 无尖峰/NCCL 绑核 8-9 的 proxy 利用率（tuner 实施文档第 2 关）。
8. **CPU proxy 每 step 负载**：`ps -eLo tid,psr,pcpu | grep NCCL` 打点，87 次/step × LL 轮询是否爆表（R3 风险项）。

---

## 7. 数据来源

**本地**：findings-raw-2026-08-15 / nccl-small-msg-trtllm-bypass-architect-2026-08-16 / nccl-latency-head-balance-architect-2026-08-16 / nccl-tuner-implementation-architect-2026-08-16 / nccl-proto-threshold-scan-2026-08-16 / nccl-p0-scan-results-2026-08-16

**官方（NVIDIA/Mellanox）**：
- NVIDIA Developer Blog《Scaling Autonomous AI Agents and Workloads with NVIDIA DGX Spark》（GTC 2026，4 节点拓扑推荐）— developer.nvidia.com/blog?p=114188
- NVIDIA Developer Blog《Inside the NVIDIA Vera Rubin Platform》（NVLink6 SHARP in-network compute；Quantum-X800 SHARPv4 vs Spectrum-X800 能力清单）— developer.nvidia.com/blog?p=111036
- NVIDIA Blog《Networking Switches for GPU Computing》（Quantum-X800 IB SHARPv4 14.4 TFLOPS vs Spectrum-X800）— blogs.nvidia.com.tw
- NVIDIA SHARP 用户手册 Rev 3.14 / Rev 3.11（setup 要求：Quantum 交换机 + ConnectX-6+ + AM；能力表）— docs.nvidia.com/networking
- NCCL 官方 env 文档（NCCL_NVLS_ENABLE 语义、自动禁用）— docs.nvidia.com/deeplearning/nccl
- NVIDIA Spectrum-X 平台白皮书（RoCE 动态路由/拥塞控制/DDP，未含 switch 内归约）— images.nvidia.cn
- DGX Spark 官方 playbooks：connect-three-sparks / multi-sparks-through-switch — build.nvidia.com/spark
- Mellanox nccl-rdma-sharp-plugins（要求 Quantum IB switch + ConnectX-6；NCCL_COLLNET_ENABLE）— github.com/Mellanox/nccl-rdma-sharp-plugins
- ConnectX-7 datasheet / Lenovo LP1693（SHARP 列于 Enhanced InfiniBand Networking；Ethernet 章节仅 RoCE/ASAP2）
- NVIDIA SHARP with NCCL 使用文档（NCCL_COLLNET_ENABLE / NCCL_ALGO=CollNet）— docs.nvidia.com/networking/display/sharpv3140

**论文/技术**：
- arXiv 2507.04786《Demystifying NCCL》（IB transport/GDRDMA/proxy/QP 布局/协议曲线）
- NCCL 论文阅读笔记（51CTO）；CSDN《用于 NCCL 的 GPU 发起网络》（GDAKI vs proxy、GIN 架构）
- til.codes《Fast & Furious Tensor Parallelism》（ring 6 步分解）；SimCCL/astra-sim（6 步与每跳延迟表）
- dl1683.github.io《GPU All-Reduce》；mlsbook.ai（SHARP 需 IB，非 RoCE）
- ai-infrastructure.net《SHARP: in-network reduction》（"SHARP primarily an InfiniBand technology；Spectrum-X 无归约引擎；2-4 节点收益微乎其微"）、《NVIDIA DGX Spark playbooks》（ring-allreduce busbw 模型）

**社区/论坛**：
- NVIDIA Developer Forums《Two multi-node DGX Spark wins: RoCE 2×...》（4 节点 + MikroTik 交换机，RoCE vs TCP 2.12→9.78 GB/s；Qwen3.5-397B TP4）
- NVIDIA Developer Forums《Container-native multi-node NCCL on 2x DGX Spark》（/dev/infiniband 传递陷阱，179.54 Gbps）
- LinkedIn NVIDIA AI #sparksomethingbig（CX-7 IB 固件锁定，LINK_TYPE locked）
- hardware-corner.net《Hacker Unlocks 3-Node DGX Spark Clustering》（自定义 NCCL mesh 插件 ~1500 行 C；UMA 下 RDMA=GPU 内存；3 机 7.4-7.6 GB/s）
- dredyson.com《4-node DGX Spark cluster without a switch 全方案实测》（ring 对 TP 判定不可用）
- servethehome.com（DGX Spark 拆解：ConnectX-7 PCIe Gen5 x4×2；GB10 UMA）；丽台科技《DGX Spark 4 逻辑端口配置指南》
- CoreWeave Docs《NCCL configuration reference》（RoCE 无 SHARP 路径、sharp_am 缺失回退、插件一致性）
- resilient-tec.com / CSDN《DGX Spark 200G 与 100G 设备通讯协议》（CX-7 Ethernet-only、RoCEv2）
