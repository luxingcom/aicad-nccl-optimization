# TensorRT-LLM 小消息通信优化调研 + 定制通信算子设计（TP4 环网 87 次 1-16KB allreduce 绕过 NCCL 专案）

**日期**：2026-08-16
**作者**：Archi（系统架构师）
**性质**：只读分析（WebSearch 调研 + 方案设计，不动服务器）
**输入**：nccl-p0-scan-results-2026-08-16（MAX_CH16 实测）/ nccl-latency-head-balance-architect-2026-08-16（历史方案 v1）/ findings-raw-2026-08-15（环境数据包）+ 本轮 WebSearch
**约束**：4×DGX Spark（GB10，UMA 121.6GiB，20 核），环网 4 边双 200G RoCE，对角无直连，NCCL ring-only v3 补丁 + PEER_HCA + GID=3；vLLM 0.26 TP4（DSV4-Flash，43 层/256 experts/MLA/fp8）；decode 每 step 87 次小 allreduce（1-16KB）每 call 55-80µs

---

## 0. TL;DR（直接给结论）

1. **87 次融合成 N 次的"直接合并"在 vLLM 0.26 的依赖图下不可行**——43 层 × (attention allreduce → MLP allreduce) 全部在数据流关键路径上严格串行（第 i 层 MLP 输出是第 i+1 层输入），没有可批量合并的独立 allreduce。**但**可以三件事："每 call 延迟砍半以上"（改协议/改算法）、"allreduce 与下游 norm 融合"（省 launch + 部分流水）、"跨层延迟不可行"（数学上被依赖序锁死）。
2. **绕过 NCCL 走 RDMA 直写对 1-16KB 的理论延迟：10-20µs/call**（vs 当前 55-80µs，约 3-5× 收益）。依据：RoCEv2 单条 RDMA WRITE 延迟 1.3-3µs、GPUDirect RDMA 小消息 2-5µs；**环网 6 步 ring 是最大浪费**——把 ring 的"6 步串行"换成"2 相位 all-to-all 广播 + 本地 reduce"后，1-16KB 的理论地板是 2 跳 × ~3-5µs + reduce ≈ **10-20µs**。
3. **TRT-LLM 无可直接搬运的 kernel，但有三个可借鉴的思路**：ONESHOT（单跳 all-to-all + 本地归约）、AllReduceFusion（allreduce+Residual+RMSNorm 单内核）、以及"绕过 NCCL 走自研 kernel"的决策本身。其 NVLink/NVSwitch 专属实现（ONESHOT/TWOSHOT/MultiShot/MNNVL）**全部依赖机内 NVLink 或跨机 NVLink fabric，在 DGX Spark 上不适用**（单机单 GPU、无 NVSwitch、跨机仅 RoCE）。
4. **性价比最高的第一步不是写 kernel，而是 tuner 插件把 decode 小消息切回 LL 协议**：Simple 协议每跳 ~6µs（当前 T1aM4 全局 Simple 就是小消息 55µs 的元凶之一），LL 协议每跳 ~1µs；**GB10 的 UMA 让 LL 的"host buffer + CPU 轮询"代价趋近于零**（host 内存即 GPU 内存，无拷贝）。预期 1-16KB 从 55-80µs 直接压到 20-35µs（-50~60%），零 kernel 开发。这条必须最先验证。
5. **端到端收益预期**：若 decode 通信在当前 step（~10ms @100tok/s）中暴露占比 ~50%（5.2ms/step），协议切 LL 约可回收 2-3ms/step（decode +25~35%），自研 2-hop kernel 再回收至 ~1.3ms/step（decode +40~60%）。实际取决于通信与计算重叠度（见 §4.3 的"暴露度"折减）。

---

## 1. 调研：TensorRT-LLM 的通信优化（可借鉴点 + 来源）

### 1.1 TRT-LLM 的 allreduce 策略体系

TRT-LLM 把 allreduce 做成多策略可切换（`AllReduceStrategy` 枚举），按消息尺寸与硬件拓扑选路径：

| 策略 | 说明 | 硬件前提 | 对本环境 |
|---|---|---|---|
| **NCCL** (0) | 标准 NCCL collective | 任意 | 当前路径 |
| **ONESHOT** (4) | 自研低延迟 kernel，单次数据传输完成 allreduce | NVLink（机内 P2P） | ✗ 无机内多 GPU |
| **TWOSHOT** (5) | 面向较大消息的两次传输 | NVLink（机内 P2P） | ✗ |
| **UB** (6) | UserBuffers 持久缓冲，省内存注册/同步开销 | NVLink / IB | 思路可借鉴（持久缓冲） |
| **MNNVL** (7) | 跨机 NVLink fabric（对称内存 + Lamport 同步） | 跨节点 NVLink（DGX SuperPOD/GB200 NVL72 类） | ✗ DGX Spark 跨机仅 RoCE |
| **LOWPRECISION** | 低精度（FP8/INT8）allreduce 省带宽再反量化 | 任意 | 可借鉴（fp8 已是本模型精度） |

核心实现文件：`cpp/tensorrt_llm/kernels/customAllReduce.cu` / `communicationKernels/allReduceFusionKernels.cu`（flag 轮询 + PTX `ld.acquire/st.release` barrier）。
来源：DeepWiki《Communication Operations and Backends》、NVIDIA Blog《3x Faster AllReduce with NVSwitch and TensorRT-LLM MultiShot》。

**结论**：TRT-LLM"绕过 NCCL"的两条路（机内 NVLink kernel / 跨机 NVLink fabric）在本环境都走不通；**能带走的只有算法思想**（ONESHOT 的 all-to-all、UB 的持久缓冲、融合模式）。

### 1.2 MultiShot：2 次通信步代替 Ring 的 2N-2 步

MultiShot 用 NVSwitch multicast 把 Ring 的 O(N) 步数压到 2 步（RS + AG 各 1 步）。**关键思想对我们是"步数必须压"**：NVIDIA 官方博客明确"小消息 + 高并行下，通信步数是延迟主因"。Ring 在 4 节点 = 6 步；MultiShot 用硬件 multicast 做到 2 步。我们没有 NVSwitch multicast，但**可以在 RoCE 上用"并行广播"做到 2 相位**（见 §3.2）。
来源：NVIDIA Developer Blog（3x Faster AllReduce with NVSwitch and TensorRT-LLM MultiShot）。

### 1.3 AllReduceFusionOp：allreduce 与下游算子融合

TRT-LLM 的 `AllReduceFusionOp` 枚举定义了融合模式：`RESIDUAL_RMS_NORM`、`RESIDUAL_RMS_NORM_QUANT_FP8`、`RESIDUAL_RMS_NORM_QUANT_NVFP4`，在 `allReduceFusionKernels.cu` 中用单个 CUDA kernel 完成"allreduce + 残差 + RMSNorm +（量化）"，128-bit 向量化。收益：减少 kernel launch（1 个 fused kernel vs 3-4 个分离 kernel）+ 数据局部性。
**vLLM 侧已有同款基础设施**：`vllm/compilation/collective_fusion.py` 的 `AllReduceFusionPass` 用 pattern matcher 把 `all_reduce → rms_norm / fused_add_rms_norm / quant` 替换为 `flashinfer_comm.trtllm_allreduce_fusion`（flashinfer 复刻的 TRT-LLM fused kernel，支持 kARResidualRMSNorm / +FP8Quant / +NVFP4Quant 等 6 种 pattern）。但**该 fused kernel 走 NVLink ONESHOT/TWOSHOT，机内专用**；且本环境 flashinfer-cubin 0.6.14 存在 SM120 decode dispatch 缺陷（0.27 升级阻塞项）。
来源：DeepWiki（Communication Operations / Tensor Parallelism）、vLLM API docs（collective_fusion）、GitLab vllm_patched_mi100（collective_fusion.py）。

### 1.4 社区低延迟小消息方案

**a) 零拷贝 / GPUDirect RDMA**：
- RDMA WRITE 单条小消息延迟：InfiniBand ~0.8-1.3µs，RoCEv2 ~1.3-3µs；GPUDirect RDMA 小消息（GPU→GPU）实测 ~1.9-5µs。
- 机制：NIC DMA 直写远端 GPU 内存，CPU/内核零参与（仅 setup），消除 2 次拷贝 + kernel 开销（无 GDR 时 10-50µs）。
- **GB10 特殊性**：UMA（CPU/GPU 共享 LPDDR5X 物理内存）+ NVLink-C2C，机内 zero-copy 天然成立；ConnectX-7 挂在 PCIe Gen5 x4（实测单口 107-110Gbps 即此上限），支持 RDMA 与 GPUDirect RDMA。→ **跨机 zero-copy = GPUDirect RDMA，GB10 上应天然可用**（无 PCIe bounce）。
来源：kindatechnical RDMA overview、Weka GPUDirect RDMA glossary、engineering.fyi Benchmarking GPUDirect RDMA（GPU-to-GPU 1.9µs）、CUDA 6 GTC overview（1K→7.5µs/16K→12µs 早期数据）、STH/read.theaimerge DGX Spark 拆解（CX7 PCIe Gen5 x4 + UMA）。

**b) 自适应算法（按消息尺寸选协议）**：
- NCCL 三协议：**Simple ~6µs/hop（memory fence 同步）、LL ~1µs/hop（4B 数据+4B flag 原子）、LL128 ~2µs/hop（120B 数据+8B flag，需 128B 原子写 = NVLink 硬件约束）**。
- LL 限制：**强制 host buffer 且禁 GPUDirect RDMA**（带宽掉到 25-50%，但 1-16KB 不在乎带宽）。→ **GB10 UMA 上"host buffer"就是 GPU 内存，LL 的代价被架构抵消**——这是本环境的隐藏红利。
- NCCL tuner 插件（`NCCL_TUNER_PLUGIN` + `getCollInfo`）：按 `collType/nBytes/拓扑` 返回 (algo, proto, nChannels)，官方示例是 CSV 规则表，如 `allreduce, 0, 262144, tree, ll`。AMD RCCL 同款 API 实测 CPX 模式小消息 Tree+LL 收益显著。→ **per-size 协议混合在插件层完全可行**（历史方案 P2-2 的落点）。
来源：arXiv 2507.04786（NCCL 协议深度解析）、SPCL 课件、NVIDIA NCCL GitHub issue #1049（Simple 网络 14µs/LL 5µs/LL128 8.5µs per-layer 实测口径）、NVIDIA Developer Blog（Understanding NCCL Tuning）、DeepWiki NCCL Tuner Plugin、AMD ROCm blog（RCCL tuner）。

**c) 梯度/消息融合（fused communication）**：
- TRT-LLM/vLLM 的"融合"实际是 **allreduce+下游算子融合**（§1.3），不是"多次 allreduce 合并成一次"。
- 训练侧的多 tensor 融合（DeepSpeed/Zero 的梯度 bucketing）把多个小 allreduce 合并为一个大 allreduce——**其前提是这些 allreduce 相互独立**。推理 decode 的 87 次 allreduce 不满足（严格依赖）。
来源：vLLM DeepWiki（Distributed Computing）、DeepWiki compilation/fusion。

### 1.5 GB10 / 环网硬件特性结论

| 特性 | 值 | 对通信的影响 |
|---|---|---|
| UMA 统一内存 | CPU/GPU 共享 128GB LPDDR5X（273GB/s），NVLink-C2C | 机内 zero-copy 天然；**LL 协议 host-buffer 代价≈0**；GPUDirect RDMA 无 bounce |
| 单机 GPU 数 | 1 | TP4 = 纯跨机通信，无任何机内 GPU 通信 |
| NVSwitch / NVLink SHARP | **无**（单 GPU 无 NVSwitch；跨机无 NVLink） | TRT-LLM ONESHOT/MultiShot/MNNVL 全部不可移植 |
| ConnectX-7 | PCIe Gen5 x4（~100Gbps/口有效），双口 200G | 单口带宽上限 ~110Gbps；小消息延迟与带宽无关 |
| 环网拓扑 | 4 边直连、对角 2 跳 | NCCL Ring = 6 步（2(N-1)）；Tree 理论 4 步 |

---

## 2. 三方向在 GB10 环网的可行性矩阵

| 方向 | 具体手段 | 对 1-16KB 的预期 | 可行性 | 风险/前提 | 优先级 |
|---|---|---|---|---|---|
| **① 零拷贝** | GPUDirect RDMA（NCCL 已默认启用）；GB10 UMA 已消除 host↔GPU 拷贝 | 单次 RDMA 1-16KB = 2-5µs（理论地板） | ✅ 高 | 已被 NCCL 使用，单独不能突破 ring 步数 | —（基础项） |
| **① 零拷贝** | vLLM custom allreduce（IPC/peer-map） | 机内 P2P 专用 | ❌ 不适用 | vLLM `custom_all_reduce` 硬性要求 **同节点** + NVLink（world>2）；我们 TP4 跨 4 节点 | 排除 |
| **② 自适应** | per-size tuner 插件：<64KB → **LL**（ring，6 步 × ~1µs），≥64KB → Simple | 55-80µs → **20-35µs**（-50~60%） | ✅✅ 高（最快落地） | 需实测 LL 在 ring-only 补丁 + CUDA graph + UMA 下可用；LL 禁 GDR 但 UMA 可抵消 | **P0** |
| **② 自适应** | per-size algo：小消息走 Tree（4 步） | 6 步→4 步，-33% | ⚠️ 中 | ring-only 补丁需使能 Tree（P2-3）；P0 扫描已证当前 Tree 不可用 | P2 |
| **③ 消息融合** | 87→N 跨层合并为一次大 allreduce | ✗ **不可行** | — | 依赖序锁死（见 §3.1） | 排除 |
| **③ 消息融合** | allreduce + residual + RMSNorm 单内核（TRT-LLM 模式） | 省 launch ~2-5µs + 小规模流水 | ✅ 中 | 本环境 flashinfer fused kernel 不可用（NVLink 专用 + SM120 缺陷）；需自研跨机版本 | P1/P2 |
| **③ 消息融合** | **自研 2-hop all-to-all 广播 allreduce**（跨机版 ONESHOT） | 55-80µs → **10-20µs**（-65~80%） | ⚠️ 中高 | 需 GPU 侧 RDMA 路径（NCCL 补丁内新增算法 或 NVSHMEM/GDAKI），开发量大 | **P1** |
| **补充** | 环网 6 步→更少步数（拓扑级） | TP2×2（2 步/次）或交换机（Tree/CollNet） | ⚠️ 中 | 结构性方案，历史 P2-1/P2-4 | P2 |

---

## 3. 定制通信算子设计（核心交付）

### 3.1 消息融合可行性：为什么"87→N"不可行（依赖图分析）

以 DSV4-Flash（L=43）decode 一个 step 的数据流：

```
token 输入
  │
  ▼
[embedding allreduce] ①
  │
  ▼
layer 0:  attn: qkv→attention→o_proj(GEMM)→AR_attn[1KB] → +residual→RMSNorm
          mlp : gate/up(GEMM)→swiglu→down(GEMM)→AR_mlp[4KB] → +residual→RMSNorm
  │（AR_mlp 结果 = layer 0 输出 = layer 1 输入）
  ▼
layer 1:  …（同构，43 层）
  │
  ▼
[final norm → lm_head GEMM → logits allgather]（非 allreduce）
```

- **AR_attn_i 依赖链**：`o_proj(GEMM)` 完成 → AR_attn_i 完成 → 残差+norm → `gate/up(GEMM)`。norm 需要完整归约结果（对整个 hidden dim 归一化），**不能**在归约完成前开始。
- **AR_mlp_i 依赖链**：`down(GEMM)` 完成 → AR_mlp_i 完成 → 残差+norm → layer i+1 的 qkv。**第 i+1 层必须等 AR_mlp_i**。
- **结论**：43×2 + 1 = 87 次 allreduce 全部落在严格串行的数据流关键路径上，两两之间都有不可跳过的计算依赖。**把 87 次合成 1 次大 allreduce 在数学上被依赖序锁死**——不存在"batch 多个 tensor 一次同步"的窗口（那是训练梯度场景的专利，梯度之间相互独立）。
- 只有两种"非合并"但等效的降本：
  1. **把每次的"通信延迟"降低**（协议/算法层面，§3.2）；
  2. **把每次通信与紧邻计算融合/重叠**（§3.3）。
- 注：MLA 的 latent（o_lora_rank=1024）确实把 attention 输出压到 1KB，但这只减少传输字节，不减少 call 次数与固定延迟。

### 3.2 绕过 NCCL 的方案：自研 2-hop all-to-all 广播 allreduce（跨机版 ONESHOT）

**为什么 ring 是浪费**：4 节点 ring allreduce = reduce-scatter（3 步）+ allgather（3 步）= **6 个串行网络步**；每步 ~9µs（Simple）→ 54µs。对 1-16KB，瓶颈是"步数 × 每步固定延迟"，不是带宽。

**方案：2 相位并行广播 + 本地归约**（把 6 步压到 2 跳）：

```
环序 0-1-2-3（实际 01-02-04-03）。每个 rank 拥有自己的 1-16KB 分片 Xi。
相位 1（并行发送邻居）：
  每个 rank 把自己的 Xi RDMA-WRITE 到 2 个直连邻居的接收缓冲（并行，1 跳）
  完成后每个 rank 已有：自己 + 2 个邻居 = 3/4 数据
相位 2（接力对角数据）：
  每个 rank 把"远端邻居"的数据再 RDMA-WRITE 转发给对角（1 跳）
  例：rank1 把 rank0 的数据转给 rank2；rank2 把 rank3 的数据转给 rank0
  完成后每个 rank 收齐 4/4
归约：GPU kernel 读 4 份缓冲求和（1-16KB，亚微秒级）
```

- **步数：6 → 2**；每跳 ~3-5µs（RoCEv2 + GPU 侧 flag 轮询）；归约本地 ~2µs。
- **理论延迟**：2 × (3-5µs) + 归约 + launch ≈ **10-20µs**（vs 当前 55-80µs）。
- **带宽代价**：每 rank 发送量 = 3× 消息大小（8KB→24KB 级别），对 1-16KB 完全可忽略（200G 网卡无感）。
- **为什么这是"跨机版 ONESHOT"**：TRT-LLM ONESHOT 的思路 = 一次 all-to-all 后本地归约（机内靠 NVLink P2P）；我们用 RoCE 在环网上用 2 相位复刻同一思路。

**实现路径（两条，二选一或递进）**：

| 路径 | 做法 | 优点 | 缺点 | 建议 |
|---|---|---|---|---|
| **A. 在 ring-only NCCL 补丁内新增小消息算法** | 在 ncclKernel 里为 nBytes<阈值 增加 2-hop 广播路径（复用 NCCL 的 GPU-RDMA/proxy/GDAKI 管线） | 对 vLLM 透明（仍走 torch.distributed→NCCL）；CUDA graph 兼容性由 NCCL 保证；与我们已有的补丁体系（P1/P2）同源 | 需要深入了解 NCCL kernel 架构；开发量大（周级）；ring-only 补丁需谨慎扩展 | **首选**（最稳健） |
| **B. vLLM 层新增跨机 custom communicator** | 在 `vllm/distributed/communication_op.py::tensor_model_parallel_all_reduce` 的 `custom_all_reduce()` 尝试点前加一个跨机分支；GPU 侧用 NVSHMEM（对称内存 put/get）或 GDAKI 发起 RDMA | 完全掌控；可顺便实现 fused norm；hook 点单一（vLLM 已留 custom allreduce 扩展位） | CUDA graph 捕获兼容性必须自证；QP/MR 管理 + 内存序 bug 风险高；需 NVSHMEM/GDAKI 在容器内可用 | 若 A 受阻再走 B |

**关键前提（必须先验证）**：GPU 侧 RDMA 发起的可用性——
- **GDAKI（GPU Direct Async / GPU-initiated networking）**：CUDA 12.x+ 允许 GPU kernel 直接 post RDMA；ConnectX-7 支持。若 GB10 + CUDA 13 + 驱动 580.173 支持，这是最干净的实现。
- **NVSHMEM**：对称内存 + GPU put/get + flag 同步，跨机 RoCE 成熟（Perplexity 多节点 DeepSeek 部署即用 NVSHMEM/自研 kernel）。容器内是否有 `libnvshmem` 需确认。
- 若两者都不可用，则 GPU-capturable 的自研 RDMA 极难做（WQE 必须由 host post），退回方案 A（借 NCCL 管线）。

**替代的"低代码"版本（值得先试）**：tuner 插件把 decode 小消息切回 **LL 协议**（§1.4b）。LL 每跳 ~1µs → ring 6 步 ~6µs + 轮询/launch → **20-35µs**。**不写任何 kernel，收益即达自研方案的 50-70%**。这应是 P0。

### 3.3 融合方案：allreduce + residual + RMSNorm 单内核（TRT-LLM 模式的跨机版）

- **做什么**：仿 TRT-LLM `RESIDUAL_RMS_NORM`，把 `AR_* → +residual → RMSNorm` 三段合成一个 GPU kernel，在数据块到达时边归约边 norm（小规模流水）。
- **收益拆分**：对 1KB tensor，流水粒度 ≈ 整个 tensor，norm 仍要等归约完 → **主要收益是省 1-2 次 kernel launch（~3-8µs/call）+ 减少同步屏障**；对 4-24KB（MLP/投机 batch=6）流水收益略增。
- **实现位置**：vLLM 0.26 有现成 pattern-matcher 基础设施（`vllm/compilation/collective_fusion.py`，torch.compile/inductor 侧），可替换替换函数为跨机 fused kernel（自研，非 flashinfer 机内版）。若走方案 B（vLLM 层自定义 communicator），可顺带把 fused norm 编进同一个自定义 op。
- **预期**：每 call 再省 ~3-10µs；与 §3.2 叠加后 1-16KB 有望到 **10-18µs**。
- **风险**：需要与 CUDA graph 捕获、fp8/quant 路径（DSV4 是 fp8 激活）对齐；数值一致性与 flashinfer 版需 A/B。

### 3.4 实现复杂度与侵入性评估

| 方案 | 代码量（估） | vLLM 侵入 | 与 ring-only 补丁兼容 | 测试方法 |
|---|---|---|---|---|
| P0 tuner 插件（LL for small） | ~200-400 行 C（CSV 规则 + getCollInfo） | 无（NCCL 插件层，LD_PRELOAD） | 兼容（不碰内核） | bench 容器四机扫 <64KB/≥64KB + `NCCL_DEBUG=TRACE` 确认选路 |
| P1 自研 NCCL 小消息算法（2-hop） | ~1000-3000 行 CUDA | 无 | 需并入 ring-only 补丁（同仓库扩展） | staging 容器 `NCCL_ALGO=CustomSmall` A/B + nsys 对比；正确性用 torch.distributed 校验 + 崩溃回滚锚点 |
| P1/B NVSHMEM/GDAKI communicator | ~800-2000 行 py+CUDA | 中（communication_op.py 加分支 + 模型初始化） | 独立于 NCCL，可并存 | 容器内 mock：四机 torch.distributed 同构跑通 → CUDA graph 捕获测试 → E2E c1@32K |
| P2 allreduce+norm fused kernel | ~500-1500 行 CUDA + 编译 pass | 中（collective_fusion 替换函数） | 独立 | 数值 A/B（与 NCCL 逐元素对比）→ E2E |

---

## 4. 推荐实施路径（P0/P1/P2）

### P0（最快落地，零 kernel 开发，先做数据闭环）
1. **P0-1：per-call 延迟归因**（nsys / `NCCL_DEBUG=TRACE`，测试容器一次短请求）：确认 55-80µs 中"host launch / ring 6 步 / 每步 RDMA / GPU 同步"各占多少——决定后续所有优先级。**数据先行**（历史 P0-2 的延续）。
2. **P0-2：tuner 插件切 LL 协议**（<64KB → LL，≥64KB → Simple）：
   - 预期 1-16KB 从 55-80µs → 20-35µs；每 step 通信 5.2ms → ~2.4ms（若通信暴露）。
   - **GB10 UMA 红利**：LL 的 host-buffer + CPU 轮询代价≈0，是切 LL 最划算的平台。
   - 验证点：LL 在 ring-only 补丁 + CUDA graph + RoCE 下不崩、且确实走 LL（TRACE 确认）；368KB/1MB 档不劣化（Simple 保留）。
   - 与历史 P2-2 是同一件事，本次明确为**第一优先**。
3. **P0-3：顺带测 NCCL_PROTO=LL 全档**（bench 容器四机一次扫描）：拿到 LL 对 1-16KB/64KB/368KB/1MB 的完整曲线，为 tuner 阈值定档。

### P1（结构性收益，需开发）
4. **P1-1：ring-only 补丁新增小消息 2-hop 算法**（§3.2 方案 A，首选）——预期 10-20µs/call，每 step 通信再降到 ~1.3ms。作为独立 `NCCL_ALGO=CustomSmall`（或 tuner 指定）合入，保留回滚锚点。
5. **P1-2：确认 GDAKI/NVSHMEM 在容器内的可用性**（一次 `ldconfig -p | grep nvshmem` + 官方 smoke test）——若可用，方案 B（vLLM 层 communicator）作为 P1-1 的备胎/叠加；同时可评估 vLLM 0.26 的 symmetric-memory allreduce 是否可借（`torch.distributed._symmetric_memory`，需 ring-only 补丁支持）。
6. **P1-3：CUDA graph 捕获兼容性专项测试**——任何自研路径（2-hop kernel / NVSHMEM / fused norm）必须通过 vLLM 的 `--cudagraph-capture-sizes` 全档捕获，否则 TPOT 崩（历史 fix72 教训）。

### P2（结构性/长期）
7. **P2-1：allreduce+rmsnorm fused kernel**（§3.3，叠加在 P1 之上）。
8. **P2-2：使能 Tree 算法**（ring-only 补丁扩展，4 步 vs 6 步，与 2-hop 方案互补用于 16KB+ 中档）。
9. **P2-3：拓扑级**——TP2×2（2 步/次，历史 P2-1）或 200GbE 交换机（Tree/CollNet/对角直连，历史 P2-4）；作为与自研 kernel 的收益对比基线，数据决定是否值得硬件投入。

### 预期收益汇总（通信暴露假设下的上限估算）

| 场景 | 每 call | 每 step 通信 | 相对当前 | decode 估算↑ |
|---|---|---|---|---|
| 当前 T1aM4（Simple） | 55-80µs | ~5.2ms | — | 基线 100 |
| +P0 tuner（LL for small） | 20-35µs | ~2.4ms | -54% | +25~35% |
| +P1 2-hop kernel | 10-20µs | ~1.3ms | -75% | +40~60% |
| +P2 fused norm | 8-18µs | ~1.1ms | -79% | +45~65% |

> ⚠️ **暴露度折减**：历史 A/B 显示 Simple 对小消息 -17~30% 时 E2E 仅 -2.7%~-9.8%，说明 GB10 decode 已存在一定通信/计算重叠。上表的 decode 增益上限按"通信完全暴露"估算；实际需 P0-1 归因后折减（若暴露 50%，则 LL 协议约 +12~18%，2-hop 约 +20~30%）。**无论如何，通信从 5.2ms 往下压是"免费算力"级别的收益，值得投入。**

---

## 5. 重点问题直接回答

### a) 87 次融合成 N 次在 vLLM 0.26 是否可行、在哪改？

**不可行（直接合并）**。87 次 allreduce（43×attn + 43×mlp + 1×embedding）全部位于严格串行的数据流关键路径：`AR_mlp_i → 残差+norm → layer i+1 qkv`，第 i+1 层不可能在第 i 层归约完成前开始。**没有可合并的独立 allreduce 窗口**——"多 tensor 一次同步"是训练梯度场景（梯度相互独立）的特权，推理 decode 不适用。

**可行的是"降每次延迟 + 融合紧邻计算"**，改的位置：
- 若走 tuner/协议：**改 NCCL 插件层**（`NCCL_TUNER_PLUGIN` + getCollInfo），vLLM 零改动。
- 若走自研 kernel：**改 `vllm/distributed/communication_op.py::tensor_model_parallel_all_reduce`**（vLLM 已在此函数为 custom allreduce 预留扩展位，`custom_all_reduce()` 先试、再落 torch.distributed）——加一个跨机分支；或更底层地**改 ring-only NCCL 补丁**（对 vLLM 完全透明）。
- fused allreduce+norm 的 pattern matcher 在 `vllm/compilation/collective_fusion.py`（0.26 已有基础设施，替换函数为自研跨机版本）。

### b) 绕过 NCCL 走 RDMA 直写对 1-16KB 的理论延迟？

**10-20µs/call（vs 当前 55-80µs）**。推导：
- RoCEv2 单条 RDMA WRITE（host）~1.3-3µs；GPUDirect RDMA 小消息（GPU→GPU）~2-5µs。
- **关键是去掉 ring 的 6 步串行**：自研 2-hop all-to-all 广播 = 2 跳 × (3-5µs) + 本地归约(~2µs) + launch(~2-3µs) ≈ **10-20µs**。
- 若先只做协议层（LL），不写 kernel：ring 仍 6 步但每跳 ~1µs → **20-35µs**（GB10 UMA 使 LL 的 host-buffer 代价≈0，是此路成立的关键）。
- 下限边界：单条 RDMA ~2µs 决定 2-hop 方案的绝对地板 ~6-8µs（归约+同步前）；工程现实取 10-20µs。

### c) TRT-LLM 有无可直接借鉴的 kernel 或思路？

**kernel 本体不可搬运**：ONESHOT/TWOSHOT/MultiShot/MNNVL 全部依赖 NVLink P2P 或跨机 NVLink fabric（NVSwitch multicast、对称内存、Lamport 同步），DGX Spark 单机单 GPU + 无 NVSwitch + 跨机仅 RoCE，全部不适用；vLLM 复刻的 flashinfer fused allreduce 同样是 NVLink 机内版，且被本环境 flashinfer SM120 缺陷阻塞。

**思路可直接借鉴（三条）**：
1. **ONESHOT = "all-to-all 一次传 + 本地归约"** → 我们在 RoCE 上做 2 相位广播 allreduce（§3.2），这是 TRT-LLM 单机做法在多机环网上的移植版。
2. **AllReduceFusionOp = 通信与下游算子融合**（RESIDUAL_RMS_NORM/QUANT）→ 跨机 fused kernel（§3.3），vLLM 0.26 的 collective_fusion pattern 框架可直接复用。
3. **UB（UserBuffers）持久缓冲** → 自研路径都用持久 MR/缓冲，避免每 call 内存注册开销。

---

## 6. 风险与纪律

- **LL 协议风险**：LL 禁 GPUDirect RDMA（走 host 路径）；GB10 UMA 理论上抵消，但**必须实测**（flag 轮询在 UMA 的延迟、CUDA graph 捕获、ring-only 补丁兼容）。任一不满足即回退 tuner 只切 ≥64KB 档或放弃。
- **自研 kernel 风险**：CUDA graph 捕获兼容性（P1-3 前置专项）；内存序/flag 轮询正确性（崩溃回滚锚点）；与 fp8 量化路径的数值一致性。
- **"融合不可行"结论的边界**：前提是"decode 单 token 严格串行"。若未来 vLLM 引入跨层并行/异步注意力（非本 0.26），需重新评估；0.27 的序列并行改变的是 allreduce 形式（RS+AG），不改变"次数×延迟"主导性。
- **E2E 收益折减**：通信暴露度需 P0-1 归因后才能定标；不承诺未经实测的具体数字。

---

## 7. 数据来源

- 本地：nccl-p0-scan-results-2026-08-16 / nccl-latency-head-balance-architect-2026-08-16 / findings-raw-2026-08-15
- Web：
  - DeepWiki：TensorRT-LLM Communication Operations and Backends / Tensor Parallelism；NCCL Tuner Plugin API / Plugin Ecosystem
  - NVIDIA Blog：3x Faster AllReduce with NVSwitch and TensorRT-LLM MultiShot；Understanding NCCL Tuning；Blackwell DeepSeek-R1 优化（oneshot allreduce + 通信内核定制）
  - arXiv 2507.04786《Demystifying NCCL》（Simple/LL/LL128 协议表）；NCCL GitHub issue #1049（协议每层延迟口径）
  - SPCL ATLAHS 课件（NCCL 协议对比）
  - vLLM：communication_op.py（custom allreduce 扩展位）；collective_fusion.py（AllReduceFusionPass + flashinfer trtllm fused allreduce，含 max one-shot/two-shot size 表）；device_communicators/custom_all_reduce.py（同节点/NVLink 硬性要求）
  - hardware：STH / read.theaimerge / dickerdata DGX Spark 拆解（ConnectX-7 PCIe Gen5 x4、UMA、RDMA+GPUDirect）；kindatechnical RDMA overview；Weka GPUDirect RDMA；engineering.fyi GPUDirect RDMA benchmark（GPU-to-GPU 1.9µs）
  - AMD ROCm RCCL tuner blog（per-size Tree+LL 规则范式）

---

## 8. 实施细化（2026-08-16 补充：LL 实测验证后）

### 8.1 LL vs Simple 实测（主理人容器验证，本方案核心论据实证）

| size | Simple(T1aM4) | LL | 判定 |
|---|---|---|---|
| 4KB | 62.7 | 44.6 | -29% ✅ |
| 8KB | 67.3 | 48.6 | -28% ✅ |
| 16KB | 82.1 | 54.3 | -34% ✅ |
| 64KB | 241 | 321 | +33% ❌ |
| 131KB | 240 | 1315 | +448% ❌ |
| 368KB | 173 | 3414 | 爆炸 ❌ |

- 小消息（1-16KB，87 次/step 主战场）LL 快 28-34%；**64KB 已反转，硬上限在 (16,64)KB 区间**。per-size tuner 必要性实证成立。
- **修正 TL;DR 的 LL 预期**：实测 LL 为 44.6-54.3µs（非理论 20-35µs）。每 call 仍含 ~40µs 固定开销（launch + 6 步同步 + CPU proxy），LL 只省掉"每跳协议"部分。87×~48µs≈**4.2ms/step（vs Simple 5.2ms）→ 每 step 省 ~1ms（-19%）**。真正打到 10-20µs 需要 P1 的 2-hop kernel（去掉 6 步串行）。
- **LL128 值得顺带一测**：若 cross-node RoCE 支持（128B 原子），它是 16-64KB 中档的候选（LL128 兼有低延迟与 ~95% 带宽），可给 tuner 加第二条带。

### 8.2 NCCL tuner 插件在 2.30.7 的挂载机制（问题 1）

**结论：可写成独立 .so 动态加载，不必改 collectives.cc / getAlgoInfo 重编。**

机制（已确认，来源 DeepWiki NCCL Tuner Plugin API + Volcengine 文档 + 2.29/2.30 文档）：
- NCCL ≥2.19 内置 tuner 插件装载器（`src/plugin/tuner.cc`，`ncclTunerPluginLoad`）；**2.30.7 正常包含**（tuner v6 为当前接口，向后兼容 v2-v5）。
- 加载方式：环境变量 `NCCL_TUNER_PLUGIN`（值 = 库名后缀 / 文件名 / 绝对路径，或 `none` 禁用）。插件导出符号 `ncclTunerPlugin_v6`。
- 调用时机：`getCollInfo` 在**每次 collective 规划时**被调，入参含 `collType/nBytes/numPipeOps/collCostTable/numAlgo/numProto/nChannels`——即**按实际消息尺寸逐 call 选择协议**，比 env 全局强制精确。
- 改法：修改 `collCostTable[a][p]`，把期望 [algo][proto] 成本置 `0.0f`，其余置 `NCCL_ALGO_PROTO_IGNORE`（-1.0）；可选覆盖 `nChannels`。
- 构建：独立 .so，fork 一份 `plugins/tuner/example/nccl/tuner.h`（+`nccl_tuner.h`）即可，不需要整库重编。NCCL 仓库自带 example（`plugins/tuner/example/` + makefile）。

**最小实现（伪代码级，~60 行）**：
```c
/* nccl_tuner_ll_small.c —— 独立插件，不改 NCCL 源码 */
#include "tuner_v6.h"   /* fork 自 plugins/tuner/example/nccl/ */
typedef struct { int threshold; } TunerCtx;

static ncclResult_t init(size_t nRanks, size_t nNodes, ncclDebugLogger_t log, void** ctx) {
    TunerCtx* c = calloc(1, sizeof(TunerCtx));
    c->threshold = 32768;                          /* 默认 32KB */
    const char* t = getenv("NCCL_TUNER_THRESHOLD"); if (t) c->threshold = atoi(t);
    *ctx = c; return ncclSuccess;
}
static ncclResult_t getCollInfo(void* ctx, ncclFunc_t coll, size_t nBytes, int numPipeOps,
        float** cost, int numAlgo, int numProto, int regBuff, int* nChannels) {
    TunerCtx* c = ctx;
    if (coll != ncclFuncAllReduce) return ncclSuccess;         /* 只调 allreduce */
    int want = (nBytes <= (size_t)c->threshold) ? NCCL_PROTO_LL : NCCL_PROTO_SIMPLE;
    for (int a = 0; a < numAlgo; a++)                          /* ring-only: numAlgo≈1 */
        for (int p = 0; p < numProto; p++)
            cost[a][p] = (p == want) ? 0.0f : NCCL_ALGO_PROTO_IGNORE;
    if (nBytes <= (size_t)c->threshold && nChannels) *nChannels = 1;  /* 可选：小消息单通道 */
    return ncclSuccess;
}
static ncclResult_t destroy(void* ctx) { free(ctx); return ncclSuccess; }
const ncclTuner_v6_t ncclTunerPlugin_v6 = {
    .name = "LLSmallSimpleLarge", .init = init,
    .getCollInfo = getCollInfo, .finalize = NULL, .destroy = destroy };
```
部署（bench/测试容器先行）：
```
export LD_LIBRARY_PATH=/opt/nccl-plugin:$LD_LIBRARY_PATH
export NCCL_TUNER_PLUGIN=nccl-tuner-ll-small        # 或绝对路径
export NCCL_TUNER_THRESHOLD=32768
# 其余 env（Simple/8M/4CH/PEER_HCA/GID/TOS）保持不变
```
验证：`NCCL_DEBUG=TRACE` 应显示小消息走 LL、大消息走 Simple。

**与 ring-only 补丁的兼容性（必须确认）**：
- 补丁若只改 algo（禁 Tree/NVLS 等），tuner 插件路径完好 → 直接用插件。
- 补丁若剥离了 plugin 装载代码 → 退化方案：在 `src/graph/tuning.cc::getAlgoInfo()` 内加 ~10 行按尺寸强制协议（重编 NCCL，已有 build 路径），效果等同。
- 判断方法（零风险）：`nm -D <libnccl.so> | grep -i tuner` + `NCCL_DEBUG=INFO` 看插件 load 日志。

### 8.3 vLLM 层 custom allreduce 扩展（问题 2）

**结论：hook 点存在且干净，但对"LL 协议"这个收益，vLLM 层不是正确位置**——NCCL 协议是库内部选择，`torch.distributed.all_reduce` 无 per-call 协议开关。vLLM 层只对"自研小消息 kernel（P1 2-hop）"有意义。

hook 点与侵入（vLLM 0.26 已具备）：
- 文件：`vllm/distributed/communication_op.py::tensor_model_parallel_all_reduce(input_)`
- 现有流程：`custom_all_reduce(input_)`（同节点 IPC，跨节点返回 None）→ `pynccl_utils.all_reduce`（如启用）→ `torch.distributed.all_reduce(tp_group)`。
- 插入点（P1 落地）：
```python
out = custom_all_reduce(input_)          # 现有，跨节点 None
if out is not None: return out
out = small_msg_allreduce(input_)        # 新增：≤阈值走自研 2-hop/NVSHMEM，否则 None
if out is not None: return out
torch.distributed.all_reduce(input_, group=get_tensor_model_parallel_group())
```
- 侵入度：低（communication_op.py 加一个分支 + `device_communicators/` 新增一个 communicator）。但**必须自研小消息路径**（2-hop kernel / NVSHMEM put-get），CUDA graph 可捕获性需专项验证（fix72 教训）。
- 结论：**LL 快赢 → NCCL tuner 插件（零 vLLM 改动）；vLLM 层预留给 P1 自研 kernel**，不要为"切 LL"做 vLLM 层（做不到）。

### 8.4 阈值确认（问题 3，已由阈值细扫定案）

**阈值细扫实测（nccl-proto-threshold-scan-2026-08-16，p50 µs）**：
| size | Simple | LL | 判定 |
|---|---|---|---|
| 24KB | 104.2 | 89.8 | LL -14% ✅ |
| 32KB | 123.4 | 112.4 | LL -9% ✅ |
| 40KB | 145.5 | 139.3 | 持平 |
| 48KB | 172.8 | 174.0 | 持平 |
| 56KB | 196.3 | 228.8 | Simple 优 ❌ |
| 64KB | 241 | 321 | Simple 优 ❌ |
| 131KB | 240 | 1315 | LL 爆 ❌ |

**翻转点 ~40KB**。**定案：单边界 ≤40KB → LL，>40KB → Simple**（40KB 本身持平可归 LL 侧，48KB 以上归 Simple）。理由：
- decode 战场上界 = 投机 batch=6 的 mlp ~24KB，40KB 边界覆盖 + 大余量；
- 单边界最简单（插件里一行常量），比"≤32KB/≥48KB 留过渡区"更干净；48KB 持平、56KB 已反转，40KB 边界安全；
- **严禁 ≥56KB 走 LL**（已反转）；≥64KB LL 爆炸。
- 补充：若后续想让 16-48KB 中档更优，可测 LL128 作第二条带（见 §8.5）。

### 8.5 实现前必补测试（问题 4）

1. **32KB / 24KB / 48KB 三单点**（bench 容器，同 P0 脚本）——定阈值边界。
2. **1KB / 2KB LL 补测**——decode attn 低端档（1-6KB）还没在 LL 下测过，确认低端也赢。
3. **CUDA graph 兼容性专项（最高风险，fix72 教训）**：测试容器 vLLM TP4 + tuner 强制小消息 LL，验证：全档 capture（1 2 4 8 16 24 32 36 40 48 56 64）成功、TPOT 无周期尖峰/无重捕获风暴、长稳运行；LL 的 CPU proxy 在 NCCL 绑核（8-9）上的利用率不爆表（87 次/step × 轮询）。
4. **正确性 A/B**：LL vs Simple 输出逐元素一致（fp8 归约），dspark 投机路径数值不漂移。
5. **LL128 顺带测试**：确认 cross-node RoCE 是否支持；若支持且 16-64KB 中档表现好，tuner 加第二条带（<16KB LL，16-64KB LL128，>64KB Simple）。
6. **ring-only 补丁插件路径确认**：`nm -D` + 插件 load 日志（见 8.2）。

### 8.6 实施路径定案（2026-08-16，Archi 决定）

**路径选择：NCCL tuner 插件（选项 1）；vLLM 层（选项 2）对"LL 协议"收益否决。**

**否决 vLLM 层的理由（决定性）**：NCCL 协议是库内部 per-collective 选择，`torch.distributed.all_reduce` **没有 per-call 协议开关**；`NCCL_PROTO` 是进程全局 env，无法按消息尺寸切换；也不存在"自建 NCCL comm 换 proto"的机制（协议不挂在 communicator 上）。vLLM 层唯一能做的"小消息走自定义路径"需要自研 kernel（P1 2-hop），那是另一件事。**结论：LL 快赢必须走 NCCL 层，即 tuner 插件。**

**2.30.7 动态加载确认**：支持。NCCL ≥2.19 内置 tuner 插件装载器（src/plugin/tuner.cc），`NCCL_TUNER_PLUGIN=<库名/绝对路径>` 动态加载独立 .so，插件导出 `ncclTunerPlugin_v6`（v2-v6 向后兼容）。`getCollInfo` 每次 collective 规划被调，入参含真实 nBytes → **逐 call 选协议**。构建只需 fork `plugins/tuner/example/nccl/` 的两个头文件 + gcc 编 .so，不重编 NCCL。

**部署关键注意（易踩坑）**：上插件后**必须移除 `NCCL_PROTO=Simple`**（T1aM4 当前设置），否则 env 全局强制会覆盖插件的 per-size 选择。插件内对大消息显式置 Simple 成本=0 保证 ≥40KB 仍走 Simple。

**阈值**：单边界 **40KB**（≤40KB LL / >40KB Simple，插件内一行常量，可 env 覆盖）。

**CUDA graph 兼容性（fix72 教训）——先测再开发，且有小规模前置测试方案**：
- 机理判断：LL 的 send 侧 fifo 在 host 内存、CPU proxy 轮询 flag 并发 RDMA，recv 侧 fifo 在 GPU；NCCL 自 ~2.19 支持 collective 的 CUDA graph 捕获，proxy 是 host 侧独立线程，不随 graph 重放。**GB10 UMA 下"host 缓冲"就是 GPU 同池内存，无 PCIe 惩罚、无拷贝，LL 在架构上反而更优**。
- 但必须实测，风险点：① 87 次/step 下 CPU proxy 是否跟得上 graph 重放（NCCL 绑核 8-9 利用率）；② capture 稳定性（无重捕获风暴）；③ fp8 数值一致。
- **前置小规模测试（无需插件，最便宜）**：测试容器 vLLM TP4 **全局 `NCCL_PROTO=LL`** + 短上下文 + 显式 `--cudagraph-capture-sizes` 全档，验证 capture 成功、TPOT 无尖峰、CPU proxy 负载、与 Simple 的数值 A/B。全局 LL 会把 prefill 打爆（368KB 20×），故**仅短上下文/decode 验证**，不碰长 prefill。通过后再建插件做生产形态（per-size 同时保住 prefill）。
- 测试顺序：A（全局 LL graph 兼容验证）→ B（插件，prefill+decode 双档）→ 生产窗口 AB。
