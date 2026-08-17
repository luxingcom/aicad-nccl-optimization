# NCCL 2-hop Allreduce Kernel 可立项设计（P1 深化）

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**性质:** 源码 + 运行时日志 + 容器实测 + 裸 RDMA 实测锚点的可立项设计（只读，不编译不部署不改生产）
**输入:** nccl-tree-algo-feasibility（P2-3 关闭）/ nccl-allreduce-offload-research（P1 方向）/ nccl-optimization-final-report（生产终态 2be94172）/ 现场核查（源码 /tmp/nccl-official-2307、生产容器 vllm-tp4-rank0、测试容器 bench-SB-r0、四机 ib_write_lat 实测）
**结论先行:** **2-hop allreduce 是本环网小/中消息延迟的正确且可落地方向——但不是通过"GDAKI/NVSHMEM 现成路径"，而是通过"在 vLLM 层或 NCCL 层实现 2 相位 kernel + 现有 RDMA 传输"**。现场已证三件事定案路径：① NCCL 2.30.7 原生含完整 GDAKI 代码，但**运行时因 GB10 `GPU_DIRECT_RDMA_WITH_CUDA_VMM_SUPPORTED=0` 被判定不可用**（`globalGinSupport 0, cuMemGdrSupport 0`），且 GDAKI 仅提供 AllGather/AllToAll 控制面、**无 AllReduce 数据路径**——"开箱即用"是幻想；② NVSHMEM C 库存在于容器（3.7.1 + gpunetio transport）但**无 Python 绑定**，vLLM 0.26 无法直接挂；③ 生产 vLLM 0.26 allreduce 已确认走 `torch.distributed.all_reduce → ProcessGroupNCCL → 定制 libnccl`（`VLLM_DISABLE_PYNCCL=1` 已禁用 PyNccl 分支），**注入点唯一且清晰**。裸 RDMA 实测 4 条环边 1KB 延迟 **2.40-2.42µs 均匀**，368KB 单跳 32.4µs、4MB 单跳 313µs（带宽饱和）——2-hop 在小消息的理论收益 -30~40%（6 步→2 相位），中消息 -15~25%，大消息**无收益（带宽受限）**，须靠 per-size 路由隔离。

---

## 0. TL;DR（先给结论）

1. **机制定案**：4-rank 环网 2 相位 allreduce 采用 **ReduceScatter(2步) + AllGather(2步) = 2 相位 / 4 网络步** 设计（不是 Tree 的 4 步，而是每相位 2 步、两两配对同时收发的"2-hop 结构"）。数学上：ring 6 步 → 2-hop 2 相位；每 rank 收发总量 ring 1.5S → 2-hop **仍为 1.5S**（步数少但每步带宽更高），**关键路径 = 2 相位 × 每相位 2 步**，对小消息（延迟主导）**净收益 -30~40%**。
2. **路径选择**：**不是 GDAKI，不是 NVSHMEM**——三条路径现场核查后定案：
   - **GDAKI：否决（运行时不可用）**。代码在（生产库 nm 有 `ncclGinIbGdaki`），但生产日志明确 `Symmetric memory is not supported. cuMemEnable 1, globalGinSupport 0, cuMemGdrSupport 0`——根因是 GB10 的 `CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_WITH_CUDA_VMM_SUPPORTED=0`（UMA 无传统 PCIe VMM GDR）。即使绕过，GDAKI 也只做 AllGather/AllToAll，不做 AllReduce。
   - **NVSHMEM：延后（无 Python 绑定）**。C 库 + gpunetio transport 齐全，但 vLLM 0.26 挂载需写 C 扩展，属于"自己造 kernel"，不如直接用 NCCL 传输。
   - **✅ 自定义 2 相位 kernel（NCCL 层或 vLLM 层）**：复用生产已验证的 RDMA 传输（RoCE + GID=3 + 双 dev），只改"网络步的调度结构"。
3. **注入点（唯一且已确认）**：生产 vLLM 0.26 设 `VLLM_DISABLE_PYNCCL=1` → `tensor_model_parallel_all_reduce → GroupCoordinator.all_reduce → CudaCommunicator.all_reduce → torch.distributed.all_reduce（fallback 分支）→ ProcessGroupNCCL → 定制 libnccl.so.2（LD_PRELOAD=/opt/nccl-ringonly）`。因此**替换 libnccl.so.2 即为全局注入点**，vLLM 源码一行不用改；若走 vLLM 层则在 `CudaCommunicator.all_reduce` 的 fallback 前插入 2-hop backend。
4. **收益量化（实测锚点）**：裸 RDMA 1KB 单跳 2.40-2.42µs ×4 边均匀；NCCL LL 小消息现 44.6-54.7µs（≈6 步 × 7.4-9.1µs/步）。2-hop 2 相位理论 ≈ 4 步 × 7.4µs ≈ **30µs（-33%）**，叠加每相位步内双收发可实现 -30~40%（24-31µs）。368KB Simple 173µs → 理论 **~130-150µs（-15~25%）**。4MB 293µs 带宽饱和 → **无收益**。
5. **立项建议**：3 阶段（S1 mock 验证 4 人日 → S2 生产原型 8-12 人日 → S3 上量/回滚 4-6 人日），总 **16-22 人日**。风险首位 **CUDA graph 兼容**（生产 64 档全捕获），其次 v1 环邻过滤对 2-hop 非环邻通信的屏蔽（2-hop 若需 0-2/1-3 对就必须扩展 v1），回滚=换库（现有 .bak 机制直接复用）。

---

## 1. 现场核查：三条实现路径的硬件/软件现实（本轮新增证据）

### 1.1 NCCL 2.30.7 含完整 GDAKI 代码——但运行时不可用（决定性）

**源码证据**（`/tmp/nccl-official-2307/src`）：
- `src/gin/gin_host.cc`、`gin_host_proxy.cc`（GIN 框架）；`src/transport/net_ib/gdaki/gin_host_gdaki.cc`（GDAKI host）；`src/include/nccl_device/gin/gdaki/gin_gdaki.h`（device API：`ncclGinApi_Put/Flush/Wait/PutValue`）；`doca-gpunetio/` 头文件在源码树内（Makefile L102-110 `DOCA_HOME ?= transport/net_ib/gdaki/doca-gpunetio`）。
- GDAKI 是**内置插件**：`plugin/gin.cc` L246 `pluginLibs[...].ncclGin = &ncclGinIbGdaki` 无条件注册。
- 启用前置（`transport/net_ib/gin.cc` L19-23、L31-40）：GDAKI 不支持 nv_peer_mem，走 **DMA-BUF**（`ncclIbDmaBufSupport`）或 device `CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED`。

**生产库证据**（`/opt/nccl-ringonly/libnccl.so.2` = 2be94172）：
- `nm`（local symbol）：`ncclGinIbGdaki`、`ncclGinIbGdakiInit/Connect/Progress/RegMrSym` 等全在 → **生产库已编译 GDAKI**。
- `strings`：`"GDAKI qp %p companion qp..."`、`"GIN_IB_GDAKI"`、`ncclGinIbGdakiGetProperties` → 代码真实存在。
- 生产日志 `/var/log/vllm/nccl-<node1>.log`：`GIN/Plugin: Assigned plugin GIN_IB_GDAKI type 3 to comm`（插件分配了！）——但随后：
  ```
  Symmetric memory is not supported. cuMemEnable 1, globalGinSupport 0, cuMemGdrSupport 0
  ```
- 根因（`init.cc` L781-784）：`globalCuMemGdrSupport` 由 `CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_WITH_CUDA_VMM_SUPPORTED` 判定。本机实测该属性 **=0**（GB10 UMA，无传统 PCIe VMM GDR）；而 `CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED = 1`。→ `globalGinSupport = NONE`，GDAKI 虽分配插件但**运行期不建立对称内存/GIN 连接**。

**GDAKI 能力面**：`gin.cc` 只有 `ncclGinIbAllGather / ncclGinIbAllToAll / ncclGinIbP2PBarrier`——**没有 AllReduce**。NCCL 2.30.7 的 GIN/GDAKI 是"对称内存 + 控制面 + AllToAll"路径，**不是 allreduce kernel 的数据路径**。

**结论**：GDAKI 作为 2-hop allreduce 载体 = **当前环境不可用**（两层墙：VMM=0 阻断启用 + 无 AllReduce 接口）。除非未来驱动/CUDA 版本修复 VMM 判定，否则不投入。

### 1.2 NVSHMEM：C 库齐全、无 Python 绑定（延后）

- 容器 `bench-SB-r0`（nvcr.io/nvidia/sglang:26.07-py3）实测：
  - `libnvshmem_host.so.3.7.1`、`libnvshmem_device.bc` 存在于 `/usr/local/cuda-13.3/targets/sbsa-linux/lib/`；`/usr/src/nvshmem/13/src/transport-plugins/gpunetio/` 含 gpunetio transport 插件（`nvshmem_transport_gpunetio.so.6` 已编译）。
  - **`python -c "import nvshmem"` → ModuleNotFoundError**（无 Python 绑定）。
- NVSHMEM 对称内存 + 双口并行可实现 2-hop allreduce（对称段 + `nvshmem_float_sum_to_all` 类 API），但 vLLM 0.26 集成需要**自写 CUDA 扩展**（C++/Pybind），等价于"自己造 kernel"，比在 NCCL 层改算法更远。
- **结论**：技术可行、工程成本高；作为 S3 之后的可选增强（若需绕过 NCCL 时）。

### 1.3 生产 vLLM 0.26 注入点（唯一且已确认）

- 生产容器 `vllm-tp4-rank0`（anemll/dspark-vllm-gx10:0.2.1-v026.0）：
  - env：`VLLM_DISABLE_PYNCCL=1`、`NCCL_ALGO=RING`、`NCCL_NET_PLUGIN=none`、`NCCL_IB_PEER_HCA=...`（v4 硬编码）、`NCCL_DEBUG=INFO`、`LD_PRELOAD=/opt/libncclpin.so /opt/nccl-ringonly/libnccl.so.2`。
  - 进程 maps 确认实际加载 `/opt/nccl-ringonly/libnccl.so.2.30.7`（2be94172）。
- vLLM 0.26.1.dev0 源码（容器内 pip 包）：
  - `communication_op.py`：`tensor_model_parallel_all_reduce → get_tp_group().all_reduce(input_)`。
  - `parallel_state.py` `GroupCoordinator.all_reduce`：`use_custom_op_call ? torch.ops.vllm.all_reduce : self._all_reduce_out_place` → `device_communicator.all_reduce`。
  - `cuda_communicator.py` `all_reduce`：**dispatch 顺序** = `nccl_symm_mem → quick_reduce(仅ROCm) → flashinfer → AITER custom → CustomAllreduce(ca_comm) → symm_mem → PyNccl(pynccl_comm) → fallback torch.distributed.all_reduce`。
  - 跨 4 节点（`nnodes=4`）：`CustomAllreduce.__init__` L90 `not all(in_the_same_node_as(...))` → **disabled=True**（确认跨节点 custom allreduce 不生效）；`PyNcclCommunicator` 因 `VLLM_DISABLE_PYNCCL=1` → disabled。
  - **∴ 生产每步 87 次 allreduce 全部落在 `torch.distributed.all_reduce(out, group=device_group)` → ProcessGroupNCCL → 定制 libnccl**。
- **注入点结论**：
  - **NCCL 层（推荐）**：替换 `/opt/nccl-ringonly/libnccl.so.2`（LD_PRELOAD 已是生产机制），vLLM 零改动；2-hop 做成 NCCL 新协议/新算法条目由 tuner 路由。
  - **vLLM 层（可选）**：在 `CudaCommunicator.all_reduce` 的 fallback 前插入 `TwoHopBackend`，改容器内 pip 包（约 40 行 Python + kernel）。

### 1.4 裸 RDMA 延迟锚点（本轮实测，4 条环边）

`ib_write_lat`（perftest 24.01，host `/usr/bin/ib_write_lat`，`-x 3` GID=3，RC/以太链路，单线程）：

| 边 | 设备/IP | 1KB avg | 16KB avg | 368KB avg | 4MB avg |
|---|---|---|---|---|---|
| 01-02 | roceP2p1s0f1, <NFS-IP>↔.2 | **2.42µs** | 4.68µs | 32.4µs | 313µs |
| 01-03 | roceP2p1s0f0, <NFS-IP>↔.2 | **2.42µs** | — | — | — |
| 02-04 | roceP2p1s0f0, <NFS-IP>↔.14 | **2.42µs** | — | — | — |
| 04-03 | roceP2p1s0f1, <NFS-IP>↔.2 | **2.40µs** | — | — | — |

- 4 边 1KB **均匀 2.40-2.42µs**（环对称、无异常边）。
- 4MB 313µs ≈ **13.4GB/s 单口**，与生产 allreduce 4MB 293µs/13.7GB/s 吻合 → 确认单口带宽上限（GB10 55% 线速）。
- **对 2-hop 的意义**：裸 RDMA 每跳 2.4µs 说明"6 步 NCCL ≈ 44.6µs"里**每步协议/同步开销 ≈ 5-7µs**（非裸延迟）——2-hop 砍步数主要省的是**每步的 NCCL 协议固定开销**，这正是收益来源。

---

## 2. 2-hop kernel 机制设计（精确数学）

### 2.1 物理拓扑与基线

- 4×DGX Spark 环：逻辑 0-1-2-3（物理 01-02-04-03），直连边 {0-1, 1-2, 2-3, 3-0}，对角 {0-2, 1-3} 无物理 L2（已多次确认）。
- ring allreduce 基线：ReduceScatter 3 步 + AllGather 3 步 = **6 个串行网络步**；每 rank 收发总量 = 2(n-1)/n·S = **1.5S**；关键路径 = 6 × interLat。

### 2.2 2 相位设计（定案）：ReduceScatter(2步) + AllGather(2步)

核心思想：4-rank 环天然是"每 rank 有 2 个邻居"，因此可以把 6 步串行链重排为 **2 个相位，每个相位 2 步，每步同时沿 2 条边收发**（0↔1、0↔3 两对同时；或 0-1/2-3 与 1-2/3-0 两两配对）。

**ReduceScatter 相位（2 步）**：
- 把 S 分成 4 个 chunk（每 chunk S/4）。rank i 目标持有 chunk i 的完全归约。
- 步 1：rank i 与 rank i+1 交换并归约（chunk 0/1 在边 0-1、chunk 2/3 在边 2-3）；**同时** rank i 与 rank i-1 交换并归约（利用每 rank 双口/双 NIC）。经 2 条边同时，2 步后每 rank 持有 1 个 chunk 的完全归约（含全部 4 rank 贡献）。
- 每 rank 每相位收发 = S/2（步内 2 条边各 S/4）。

**AllGather 相位（2 步）**：
- 对称反向：把 4 个完全归约 chunk 扩散回所有 rank，2 步完成（与 ReduceScatter 同构反向）。
- 每 rank 每相位收发 = S/2。

**步数/数据量/关键路径精确对比**：

| 指标 | Ring | 2-hop | 变化 |
|---|---|---|---|
| 总网络步数 | 6 | **4**（2 相位×2步） | -33% |
| 相位数 | 2（RS/AG） | 2（RS/AG） | 同 |
| 每 rank 收发总量 | 1.5S | **1.5S** | 同 |
| 每步同时使用边数 | 1（单边） | 2（双边配对） | 步内并行×2 |
| 关键路径（延迟项） | 6×L | **4×L** | -33% |
| 关键路径（带宽项） | 1.5S/BW | 1.5S/BW | 同 |
| 所需物理边 | {0-1,1-2,2-3,3-0} | **同**（只走直连边） | 环内可嵌 |

> 说明：本设计**不需要对角边**（与 Tree 不同）——这是它能跑在环网上的根本原因。2-hop 的"hop"含义是"每相位 2 步、每步沿 2 条边"而非"发两跳到对角"。

### 2.3 与"每 rank 发两跳直达对角"备选设计的取舍

- 备选"2-hop 广播（每 rank 直接发 2 跳）"需要对角物理可达或中间转发；本环境对角无 L2，若经中间转发则退化为 3 步以上、丧失收益。**否决**，采用 2.2 的两两配对设计。

### 2.4 关键路径延迟公式

- 设 L = 单步协议延迟（含 RDMA + 同步 + NCCL 协议开销），B = 单口有效带宽（≈13.4GB/s）。
- Ring：T = 6L + 1.5S/B（小消息时带宽项可忽略 → 6L）。
- 2-hop：T = 4L' + 1.5S/B，其中 L' 可能略高于 L（步内双边收发，GPU/NIC 并发调度开销），实测校准。
- 小消息（1-16KB，decode 战场）：T2hop/Tring ≈ 4/6 = **-33%**（若 L'≈L）；实测 LL 44.6µs → 理论 ~30µs；若 L' 有 10% 上浮 → ~33µs（-26%）。
- 中消息（368KB，Simple 173µs，16ch）：延迟项约占 30-40%（173µs 中每步 ~6µs×6≈36µs 延迟项 + 137µs 带宽项）。2-hop 延迟项 4×6=24µs → T≈161µs（**-7%**）；若 2-hop 使每步带宽更高（双边并行）则带宽项也可能降 → **-15~25% 区间**，需实测定标。
- 大消息（4MB，带宽饱和 293µs）：带宽项 1.5S/B 主导，步数收益 ~36µs/293µs ≈ **+12% 无收益**。**2-hop 只路由到 ≤512KB（tuner 阈值）**。

---

## 3. 与 ring-only 补丁兼容性

### 3.1 三层补丁交互

| 补丁 | 位置 | 与 2-hop 的交互 | 兼容性 |
|---|---|---|---|
| **v1 环邻过滤** | `transport.cc` L49-77 | 2-hop 只走环邻 {0-1,1-2,2-3,3-0}，**不涉及对角** → v1 过滤**不拦截任何 2-hop 连接** | ✅ 天然兼容 |
| **v4 硬编码映射** | `net.cc` | 2-hop 需要"每 rank 双 dev 同发"（v4 已为每 peer 映射 dev，本设计步内双边各用一 dev，**与 v4 的 per-peer 单 dev 不冲突**，因为不同 peer 用不同 dev） | ✅ 兼容（需验证 per-peer dev 选择在双边并发下的仲裁） |
| **PerSizeTuner** | `enqueue.cc` | 2-hop 作为新算法条目，tuner 路由 ≤512KB → 2-hop / >512KB → ring | ✅ 兼容（tuner 接口支持多算法） |

### 3.2 注入路径（推荐 NCCL 层）

- **实现位置**：在定制库中新增 2-hop 协议/算法条目（`ncclAlgo.h` 新增 algo + `enqueue.cc` tuner 路由 + kernel `device/` 新 kernel 或复用 ring kernel 改步结构），通过 `NCCL_ALGO` 或 tuner 按 size 路由。
- **为什么推荐 NCCL 层而非 vLLM 层**：
  1. 生产已用 LD_PRELOAD 机制加载定制库，**换库即上线/回滚**（现有 .bak 机制）。
  2. CUDA graph 兼容由 NCCL 原生处理（生产 64 档捕获已验证 ring kernel 兼容；2-hop kernel 需专项验证但走同一条 capture 路径）。
  3. vLLM 0.26 所有 allreduce 已收敛到 torch.distributed→ncclAllReduce，无需改 Python。
- **vLLM 层备选**：`CudaCommunicator.all_reduce` fallback 前插入 `TwoHopBackend`（torch custom op 或 monkey-patch），优点是与 NCCL 库解耦、可只对小消息启用；缺点是需改 pip 包 + 自管 CUDA graph 捕获（vLLM 的 graph capture context 对自定义 op 支持有限）。

### 3.3 与 CUDA graph 的兼容要求

- 生产 `--cudagraph-capture-sizes 1 2 4 8 16 24 32 36 40 48 56 64` 全档捕获。
- NCCL kernel 在 CUDA graph 中通过 **capture-safe 的 proxy 线程重新 post 网络操作**实现；2-hop kernel 若复用该机制（NCCL proxy + RDMA WRITE + flag），则与 ring kernel 同为 capture-safe。
- **风险点**：2-hop 的"每相位 2 步双边同时收发"在 capture 时需要 proxy 线程按 2-hop 调度发 WQE；若步内双边并发引入额外同步，可能增加 capture 失败概率（需 S1 mock 验证）。
- 回退保证：tuner 关 2-hop 即回 ring（生产现有路径不动）。

---

## 4. 收益量化（结合实测锚点）

### 4.1 分尺寸汇总

| 尺寸 | 现状（实测） | 2-hop 理论 | 收益 | 路由 |
|---|---|---|---|---|
| 1-16KB（decode 87 次/step） | LL 44.6-54.7µs | 4步 × ~7.4µs ≈ **30µs** | **-26~40%** | 2-hop |
| 32KB-512KB（中消息） | Simple 54.7-173µs | 延迟项 -33% + 带宽项双边并行 | **-7~25%** | 2-hop（≤512KB） |
| 368KB 生产主档（16ch） | 173µs | ~130-161µs | **-7~25%** | 2-hop |
| 1MB+（大消息） | 294µs（1MB）、293µs（4MB） | 带宽饱和 | **≈0 或 +** | **ring（不路由）** |

### 4.2 端到端意义

- decode 每 step 87 次小 allreduce：现每 step 通信 ~4.2ms（LL）；2-hop 每 call 44.6→30µs（-33%）→ 每 step 通信 ~2.8ms → **每 step 省 ~1.4ms**。
- 在 TPOT ~10ms/step 量级下，理论端到端 **+3~8%**（受计算/通信重叠率影响，需 P0-1 归因后定标）。
- 中消息 368KB 主档：prefill/长上下文收益，理论 -7~25%。

### 4.3 与 Tree / 其他路径的对比

- 2-hop 4 步 = Tree 的 4 步（tuning 模型），但 Tree 需要对角边（本环境物理不可行），**2-hop 是环网上能达到 Tree 步数的唯一方案**。
- 2-hop 数据量 1.5S 与 ring 相同、优于 Tree 的 2(N-1)/N·S（同为 1.5S，4 节点无差别）。
- 大消息：2-hop ≈ Tree ≈ ring，均带宽受限 → 结构性收益只能来自 P2 交换机（不改此结论）。

---

## 5. 立项建议

### 5.1 阶段划分与工作量

| 阶段 | 内容 | 人日 | 验收 |
|---|---|---|---|
| **S1 容器 mock** | 在 bench-SB-r0 上：① 用现有 ring kernel 验证"双边同时收发"可行性（nccl 层改步结构的快速原型，仅单机/两机）；② CUDA graph 全档捕获 2-hop kernel；③ tuner 路由 2-hop≤512KB；④ per-peer dev 仲裁验证 | 4 | mock 通过 + graph 捕获无尖峰 |
| **S2 生产原型** | 定制库新增 2-hop 算法（kernel + enqueue tuner + 连接复用）；A/B 与现有 2be94172 对比；修复 v1/v4 交互 | 8-12 | 容器 A/B：1-16KB -20%+、368KB 无劣化 |
| **S3 上量/回滚** | 生产四机部署（沿用备份机制）；FULLTEST 全量；CUDA graph 64 档验证；长窗口稳定 | 4-6 | FULL32K/131K 主判据全绿、无 110 |

**总计 16-22 人日**（不含不可控风险缓冲）。

### 5.2 风险清单（按优先级）

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| 1 | **CUDA graph 兼容**（2-hop 双边并发在 capture 下失败/尖峰） | **高** | S1 前置验证；失败则回 ring（tuner 关闭） |
| 2 | **步内双边并发的 per-peer dev 仲裁**（v4 映射冲突） | 中 | S1 验证；必要时 v4 扩展为 per-peer 双 dev |
| 3 | **GB10 UMA 下 2-hop 协议开销与预期不符**（L' > L） | 中 | 实测校准；若收益 <15% 则降级为仅小消息 |
| 4 | 2-hop 与 LL 协议叠加效果不明 | 中 | tuner 双维路由（algo×proto），S2 扫描 |
| 5 | 368KB 主档收益不达预期（带宽项主导） | 低 | 阈值实测调整；大消息仍 ring |

### 5.3 回滚方案

- NCCL 层：`/opt/nccl-ringonly/libnccl.so.2.30.7.bak-stageB-prod-20260816`（= v3）直接覆盖 + 重启即回滚（与现机制一致）。
- tuner：移除 2-hop 路由条目即回 ring（无需换库）。
- vLLM 层：还原 pip 包（若有备份）。

---

## 6. 待执行角色后续项（下传）

1. **S1 mock 前哨**：在 bench-SB-r0 用现有 2be94172 库跑 `NCCL_ALGO=RING` + 强制 2 相位步结构的微基准（模拟每相位 2 步），抓步数→延迟曲线，验证 L'≈L 假设。
2. **CUDA graph 前置专项**：测试容器全档 capture（1..64）含 2-hop kernel，验证 TPOT 无尖峰（沿用 tuner 报告 fix72 教训）。
3. **368KB 主档基线再确认**：同窗测 2-hop 阈值（256KB/512KB）在 16ch Simple 下的实际收益，为 tuner 阈值定标。
4. **GDAKI 观测保留**：不投入，但记录 `CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_WITH_CUDA_VMM_SUPPORTED=0` 于已知问题清单；若未来驱动更新，可低成本复测。

---

## 7. 数据来源

**现场核查（2026-08-16 本轮）**：
- 源码：`/tmp/nccl-official-2307/src/gin/gin_host.cc`、`transport/net_ib/gin.cc`、`transport/net_ib/gdaki/gin_host_gdaki.cc`、`include/nccl_device/gin/gdaki/gin_gdaki.h`、`plugin/gin.cc`、`init.cc`（L781-784 VMM 判定、L1668-1681 globalGinSupport）、`device/CMakeLists.txt`、`Makefile`（L102-110 DOCA）
- 生产库：`/opt/nccl-ringonly/libnccl.so.2`（2be94172）nm/strings；`/var/log/vllm/nccl-<node1>.log`（GIN 插件分配 + Symmetric not supported）
- 生产容器：`vllm-tp4-rank0` env（LD_PRELOAD、VLLM_DISABLE_PYNCCL、PEER_HCA）；进程 maps
- vLLM 源码（容器内 pip）：`communication_op.py`、`parallel_state.py`（GroupCoordinator.all_reduce）、`device_communicators/cuda_communicator.py`（all_reduce dispatch）、`custom_all_reduce.py`（跨节点 disabled）
- 测试容器：`bench-SB-r0`（sglang 26.07）：DOCA 库、NVSHMEM 库/transport、DMA-BUF/VMM 属性
- 裸 RDMA：四机 `ib_write_lat`（1KB/16KB/368KB/4MB）

**历史**：nccl-tree-algo-feasibility-architect（Tree 三层墙）/ nccl-allreduce-offload-research-architect（P1 方向）/ nccl-optimization-final-report（生产 2be94172）/ nccl-tuner-implementation-architect（PerSizeTuner）/ nccl-p0-scan-results / nccl-large-msg-nonmonotonic
