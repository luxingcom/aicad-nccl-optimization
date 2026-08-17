# NCCL per-size 协议 tuner 实施路径细化（tuner 插件主推 · 实施级）

**日期**：2026-08-16
**作者**：Archi（系统架构师）
**性质**：实施细化设计（纯设计文档，不动服务器；命令/路径已标注"待现场核实"处）
**输入**：nccl-small-msg-trtllm-bypass-architect-2026-08-16 / nccl-proto-threshold-scan-2026-08-16 / nccl-p0-scan-results-2026-08-16 / findings-raw-2026-08-15 / nccl-latency-head-balance-architect-2026-08-16 + 本轮 Web 核实（NCCL 2.30.x tuner 插件接口）
**约束**：4×DGX Spark（GB10 UMA），环网 4 边双 200G RoCE；vLLM 0.26 TP4（DSV4-Flash）；NCCL 2.30.7 ring-only 定制版；生产已上线 T1aM4 + MAX_CH16；测试载体 sglang 26.07 容器

---

## 0. TL;DR（先给结论）

1. **路径 A（NCCL tuner 插件）为唯一主推**：2.30.7 确认支持 `NCCL_TUNER_PLUGIN` 动态加载独立 .so，接口为 `ncclTunerPlugin_v6`（回调 `getCollInfo`，v2–v6 向下兼容），**不重编 NCCL、不碰 ring-only 补丁**。预计 ~200 行 C，gcc 单文件编译。
2. **路径 B（vLLM 层）对"LL 协议"收益正式否决**：`torch.distributed.all_reduce` / vLLM PyNccl 均无 per-call 协议开关，NCCL 协议是库内按消息尺寸逐 call 选择的（正是 tuner 插件的活）；vLLM 层唯一能做的是"自研小消息 kernel（P1 2-hop）"，那是另一件事。vLLM 层不承担 LL 快赢。
3. **关键部署纪律（易踩坑）**：上插件后**必须删除 `NCCL_PROTO=Simple`**（env 优先级高于插件，否则 per-size 选择失效）；`NCCL_ALGO=RING` 可保留（ring-only 库本就只有 ring，插件只选协议维度）。
4. **阈值定案**：单边界 **40KB**（≤40KB → LL，>40KB → Simple，插件内一行常量可 env 覆盖）。实测翻转点 ~40-56KB，严禁 ≥56KB 走 LL（已反转）、≥64KB LL 爆炸（20×）。
5. **最小验证路径**：容器 torch.distributed mock（零 vLLM）→ CUDA graph 前置专项（fix72 教训）→ vLLM TP4 A/B → 生产窗口 AB。回滚 = 删 .so + 还原 env，**比重编安全**。
6. **工作量**：插件本体 ~0.5-1 人日；完整落地（含验证三关 + 生产窗口）~3-4 人日。**风险最高项 = CUDA graph + LL 的 CPU proxy 负载（fix72 教训），先测再上。**

---

## 1. 背景与目标（实证回放）

### 1.1 已确立的数据事实

| 事实 | 数据 | 来源 |
|---|---|---|
| decode 每 step 87 次小 allreduce（1-16KB，投机 batch=6 时 ≤24KB） | 1-16KB | findings / head-balance |
| 小消息 LL 快 28-34%（1-16KB 主战场） | 4KB: 44.6 vs 62.7；8KB: 48.6 vs 67.3；16KB: 54.3 vs 82.1 | 阈值扫描 |
| 翻转点 ~40KB，≥56KB Simple 优，≥64KB LL 爆炸 | 40KB 持平/LL 微胜；56KB LL +16%；64KB LL +33%；368KB LL 20× | 阈值扫描 |
| 生产 368KB allreduce 已由 MAX_CH16 优化 | 368KB: 173µs（-58%） | P0 扫描 |
| 当前 Simple 下 1-16KB 每 call 55-80µs | — | P0/阈值扫描 |

### 1.2 目标

在**保住 prefill 大消息 Simple 收益**（368KB/16MB 档）的前提下，把 decode 87 次小 allreduce 切到 **LL 协议**，实现"per-size 协议混合"：
- decode 每 call：55-80µs → **44.6-54.3µs**（实测 LL 数据，约 -30%）
- 每 step 通信：~5.2ms → **~4.2ms**（-19%，若通信暴露；实际暴露度需 P0-1 归因折减）
- prefill：维持 Simple（368KB/1MB/16MB 档不劣化）

> 注意：这是"不写 kernel 的最快收益"。真正打到 10-20µs 需 P1 的 2-hop 小消息 kernel（去掉 ring 6 步串行），不在本文范围（已在 TRT-LLM bypass 报告 §3.2 设计）。

---

## 2. 路径 A：NCCL tuner 插件（主推）

### 2.1 2.30.7 动态加载支持确认（已核实）

**结论：支持。** 机制链（来源：NCCL 官方 DeepWiki Tuner Plugin API + NCCL 文档 + 源码级核实）：

1. NCCL ≥2.19 内置 tuner 插件装载器 `src/plugin/tuner.cc::ncclTunerPluginLoad`；2.30.7 正常包含（NCCL 官方推荐 tuner 插件作为"现场修复调优"的标准手段，自 2.27 起最小接口聚焦 getCollInfo）。
2. 加载由环境变量 `NCCL_TUNER_PLUGIN` 控制：值可为 **库名后缀 / 文件名 / 绝对路径** 或 `none`（禁用）。取值策略：
   ```
   NCCL_TUNER_PLUGIN=foo
     → 尝试加载 "foo"
     → 失败则尝试 "libnccl-tuner-foo.so"（需在 LD_LIBRARY_PATH）
   未设置 → 尝试 "libnccl-tuner.so" → net 插件 → 内部 tuner
   ```
3. 装载器做**版本握手**：依次查 `getNcclTuner_v6` → v5 → v4 → v3 → v2 符号。**2.30.7 的当前接口 = v6，导出符号 `ncclTunerPlugin_v6`**。
4. 加载失败不崩溃：回退内部 tuner（`NCCL_DEBUG=INFO` 有日志）。失败模式是"静默不生效"——**必须用日志确认加载成功**。

### 2.2 接口签名（v6 vs 老版本，含 getAlgoInfo 澄清）

**命名澄清**：任务描述中的 "getAlgoInfo" 对应 NCCL **内部**函数（`src/graph/tuning.cc::getAlgoInfo`，即插件加载路径被剥离时的退化改法落点）；**插件 API 的回调名是 `getCollInfo`**（v2–v6 一贯如此）。不要在插件里找 getAlgoInfo。

**v6 接口（2.30.x 当前，推荐实现）**——`ncclTuner_v6_t`（源码已核实）：

```c
typedef struct {
  const char* name;
  ncclResult_t (*init)(void** ctx, uint64_t commId, size_t nRanks, size_t nNodes,
                       ncclDebugLogger_t logFunction,
                       ncclNvlDomainInfo_v6_t* nvlDomainInfo,
                       ncclTunerConstants_v6_t* constants);
  ncclResult_t (*getCollInfo)(void* context, ncclFunc_t collType, size_t nBytes,
                              int numPipeOps, float** collCostTable,
                              int numAlgo, int numProto, int regBuff, int* nChannels);
  ncclResult_t (*finalize)(void* context);
  ncclResult_t (*getChunkSize)(void* context, ncclFunc_t collType, size_t nBytes,
                               int algo, int proto, int nChannels, size_t* chunkSize); // 可选
} ncclTuner_v6_t;
```

**v2 老接口**（`ncclTuner_v2_t`，v6 装载器向下兼容）——注意参数不同（直接输出 algo/proto 指针，无 cost table）：

```c
ncclResult_t (*getCollInfo)(void* context, ncclFunc_t collType, size_t nBytes,
                            int collNetSupport, int nvlsSupport, int numPipeOps,
                            int* algorithm, int* protocol, int* nChannels);
```

**选型建议**：直接实现 v6（`ncclTunerPlugin_v6`）。v6 的 cost-table 修改模式更安全（保留 NCCL 对不兼容组合的 IGNORE 标记），且 v6 是 2.30.7 首选加载的符号。

**调用时机**：`getCollInfo` 在**每次 collective 规划时**被调（每次 `ncclAllReduce` 的 planning 阶段），入参含**真实 nBytes** → 天然支持"按实际消息尺寸逐 call 选协议"。这是比全局 env（`NCCL_PROTO`）精确得多的机制。

### 2.3 getCollInfo 内按 nbytes 选 proto（完整可编译伪代码）

核心模式：**修改 cost table**——把期望 [algo][proto] 的成本置 `0.0f`，其余置大数（或 `NCCL_ALGO_PROTO_IGNORE`）；**跳过 NCCL 已标记为 IGNORE 的组合**（不兼容组合覆盖为可用值是危险操作）。

```c
/* nccl_tuner_llsmall.c —— 独立插件，不改 NCCL 源码，约 110 行 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tuner_v6.h"   /* fork 自 NCCL plugins/tuner/example/nccl/tuner.h + 必要的常量 */

#define NCCL_ALGO_PROTO_IGNORE (-1.0f)

typedef struct { int threshold; } TunerCtx;

static ncclResult_t init(void** ctx, uint64_t commId, size_t nRanks, size_t nNodes,
                         ncclDebugLogger_t logFunction,
                         ncclNvlDomainInfo_v6_t* nvlDomainInfo,
                         ncclTunerConstants_v6_t* constants) {
    TunerCtx* c = calloc(1, sizeof(TunerCtx));
    c->threshold = 40960;                          /* 默认 40KB */
    const char* t = getenv("NCCL_TUNER_THRESHOLD");
    if (t) c->threshold = atoi(t);
    if (c->threshold <= 0) c->threshold = 40960;   /* 防御 */
    *ctx = c;
    return ncclSuccess;
}

static ncclResult_t getCollInfo(void* context, ncclFunc_t collType, size_t nBytes,
                                int numPipeOps, float** collCostTable,
                                int numAlgo, int numProto, int regBuff,
                                int* nChannels) {
    TunerCtx* c = (TunerCtx*)context;
    if (collType != ncclFuncAllReduce) return ncclSuccess;  /* 只调 allreduce */
    int want = (nBytes <= (size_t)c->threshold) ? NCCL_PROTO_LL : NCCL_PROTO_SIMPLE;
    for (int a = 0; a < numAlgo; a++) {
        for (int p = 0; p < numProto; p++) {
            if (collCostTable[a][p] == NCCL_ALGO_PROTO_IGNORE) continue; /* 跳过不兼容 */
            collCostTable[a][p] = (p == want) ? 0.0f : 1e18f;
        }
    }
    /* v1 不动 nChannels —— 交给 NCCL/env（MIN_CH 4 / MAX_CH 16 保持） */
    return ncclSuccess;
}

static ncclResult_t finalize(void* context) {
    TunerCtx* c = (TunerCtx*)context;
    if (c) free(c);
    return ncclSuccess;
}

const ncclTuner_v6_t ncclTunerPlugin_v6 = {
    .name = "LLSmallSimpleLarge",
    .init = init,
    .getCollInfo = getCollInfo,
    .finalize = finalize,
    .getChunkSize = NULL,   /* 可选：v1 不覆盖 chunk size */
};
```

要点：
- **只改 allreduce**（decode 战场全是 allreduce；allgather/broadcast 走 NCCL 默认，避免误伤 logits gather）。
- **不碰 nChannels**（v1 最小化；`MIN_CH=4`/`MAX_CH=16`/`BUFFSIZE=8M` 是生产已验证组合，插件不动它）。
- **跳过 IGNORE 组合**：ring-only 库中非 ring 的 algo 被标记 IGNORE，跳过即可；LL 对 ring 一定可用（阈值扫描已实证）。
- 若后续想试 16-48KB 中档，可在此加第二条带（LL128）——**但需先确认本环境 LL128 是否可用**（见 §6 风险，跨机 RoCE 上极可能不可用）。

### 2.4 编译方式

在测试容器（sglang 26.07，Ubuntu 24.04 ARM64，有 gcc）内编译，产出 aarch64 .so：

```bash
# 在容器内
cd /opt/nccl-tuner
# 1) 从 NCCL 仓库 fork 需要的头文件（只读参考，不改 NCCL 本体）
#    plugins/tuner/example/nccl/tuner.h
#    src/include/plugin/nccl_tuner.h
#    src/include/plugin/tuner/tuner_v6.h
# 2) 把 nccl_tuner_llsmall.c 与上述头放同目录
gcc -O2 -fPIC -shared -o libnccl-tuner-llsmall.so nccl_tuner_llsmall.c \
    -I./include   # 头文件目录
# 3) 验证符号
nm -D libnccl-tuner-llsmall.so | grep ncclTunerPlugin_v6   # 期望出现
```

- 编译产物约几十 KB，四机各放一份（或共享目录 bind-mount）。
- **注意**：编译时头文件与 NCCL 主库符号仅做结构体对齐，**不需要链接 libnccl.so**（插件通过 dlsym 由 NCCL 装载器取符号）。`待现场核实`：容器内 gcc 可用性（`gcc --version`）；head 容器 01 镜像 34.2G 含 build 工具，worker 21.6G 未必——**若 worker 无 gcc，在 head 容器编译后 scp 到 worker**。

### 2.5 部署方式（环境变量 + 与现有 env 的交互）

**当前生产 env（findings-raw §2）**：
```
NCCL_ALGO=RING, NCCL_NET=IB, NCCL_IB_GID_INDEX=3, NCCL_IB_TOS=46,
NCCL_PROTO=Simple,            <-- 必须删除（见下）
NCCL_MIN_NCHANNELS=4, NCCL_BUFFSIZE=8388608, NCCL_MAX_NCHANNELS=16, ...
```

**部署 diff（start_tp4_head.sh / start_tp4_worker.sh）**：
```diff
+  -v /opt/nccl-tuner:/opt/nccl-tuner:ro            # .so 挂进容器
   -e 'NCCL_ALGO=RING'
   -e 'NCCL_NET=IB'
   -e 'NCCL_IB_GID_INDEX=3'
   -e 'NCCL_IB_TOS=46'
-  -e 'NCCL_PROTO=Simple'                            # 删除！env 优先级高于插件
+  -e 'NCCL_TUNER_PLUGIN=/opt/nccl-tuner/libnccl-tuner-llsmall.so'
+  -e 'NCCL_TUNER_THRESHOLD=40960'
   -e 'NCCL_MIN_NCHANNELS=4'
   -e 'NCCL_BUFFSIZE=8388608'
   -e 'NCCL_MAX_NCHANNELS=16'
```

**为什么必须删 `NCCL_PROTO=Simple`**（已核实的优先级规则）：
- NCCL 官方与社区一致：`NCCL_ALGO`/`NCCL_PROTO` 环境变量**优先级高于 tuner 插件**（"While those overrides are in place, any default choices by NCCL are ignored"；"环境变量优先：当同时通过环境变量和插件指定时，环境变量的设置具有更高优先级"）。
- 若保留 `NCCL_PROTO=Simple`，则所有 collective 被 env 强制为 Simple，插件 getCollInfo 的 per-size 修改不生效（或直接短路不调插件）——**per-size 选择彻底失效，等于白上插件**。
- `NCCL_ALGO=RING` 可保留：ring-only 库只有 ring，env 强制 ring 与插件"只选协议"不冲突；插件仍被调用于协议维度。`待现场核实`：上插件后以 `NCCL_DEBUG_SUBSYS=TUNING` 验证小消息确实选中 LL；若发现 NCCL_ALGO 存在时插件完全不 consult，则把 NCCL_ALGO 也删除（ring-only 库默认也只会选 ring）。

**验证加载成功的日志锚点**（`NCCL_DEBUG=INFO`）：
```
NCCL INFO ... Successfully loaded tuner external plugin /opt/nccl-tuner/libnccl-tuner-llsmall.so
```

### 2.6 与 ring-only 补丁的兼容性（net.cc 改动是否影响 tuner 路径）

**结论：不影响。** 理由：

| 补丁（findings §7） | 改的文件 | 是否影响 tuner 插件路径 |
|---|---|---|
| P1 ring-only | `src/graph/`（算法使能/拓扑） | 不影响 `src/plugin/tuner.cc` 装载器；插件仍在 collective planning 时被调 |
| P2 PEER_HCA v3 双 dev 轮换 | `src/transport/net.cc`（net transport） | **net.cc 是传输层，tuner 是调度层**，二者解耦；LL 的"选路/数据路径"由 transport 提供，与"选协议"无关 |
| P3 libncclpin shim | 外部 shim | 无关 |

**潜在冲突点（必须现场核实，零风险判断法）**：
1. 补丁是否剥离/改写了 `src/plugin/tuner.cc` 或 `src/graph/tuning.cc` 的插件调用段：
   ```bash
   nm -D <libnccl.so> | grep -i tuner       # 期望看到 ncclTunerPluginLoad 等符号
   NCCL_DEBUG=INFO ...                       # 容器内跑任意 torch.distributed，看插件 load 日志
   ```
2. ring-only 补丁若通过 `NCCL_ALGO` 相关代码硬编码禁用了其他 algo，插件 cost table 中非 ring 行已是 IGNORE，跳过即可——**插件逻辑天然兼容**。
3. **退化方案**（若 2.30.7 定制库被剥掉插件装载器）：改 `src/graph/tuning.cc::getAlgoInfo()` 内部加 ~10 行按 nBytes 强制协议（重编 NCCL，已有 build 路径 `make src.build CUDA_HOME=... NVCC_GENCODE sm_121`）。效果等同但需要重编 + 四机重部署，**仅当插件路径不可用时才走**。

---

## 3. 路径 B：vLLM 层 custom allreduce 扩展（对 LL 否决，对 P1 保留）

### 3.1 vLLM 0.26 调用点（communication_op.py，行号级——待现场核实）

**文件**：`vllm/distributed/communication_op.py`，函数 `tensor_model_parallel_all_reduce(input_)`（0.26 源码结构已核实，行号为近似值）：

```python
# ≈ L20-40
def tensor_model_parallel_all_reduce(input_: torch.Tensor) -> torch.Tensor:
    from vllm.distributed.device_communicators import pynccl_utils
    from vllm.distributed.device_communicators.custom_all_reduce import custom_all_reduce
    if get_tensor_model_parallel_world_size() == 1:
        return input_                          # TP1 直通
    out = custom_all_reduce(input_)            # ① 同节点 IPC kernel（跨节点返回 None）
    if out is not None:
        return out
    if is_pynccl_enabled_for_all_reduce():     # ② PyNccl（NCCL 薄封装）
        pynccl_utils.all_reduce(input_)
    else:
        torch.distributed.all_reduce(input_, group=get_tensor_model_parallel_group())  # ③
    return input_
```

- 调用方：`vllm/model_executor/layers/...` 各层通过 `tensor_model_parallel_all_reduce` 做 allreduce；group 来自 `vllm/distributed/parallel_state.py::get_tensor_model_parallel_group()`。
- ① `custom_all_reduce`：**硬性要求同节点 + world_size∈[2,4,6,8] + NVLink（world>2）** → 本环境跨 4 节点必然返回 None（已核实 custom_all_reduce.py 约束）。
- ②/③ 最终都落到 **NCCL `ncclAllReduce`**（pynccl 是 Python 封装，torch.distributed 走 ProcessGroupNCCL）。

### 3.2 能否对 <32KB 的 tensor 走 LL？（决定性否决）

**不能。** 三连证：
1. **`torch.distributed.all_reduce` 无 per-call 协议开关**：协议是 NCCL **库内部**在 collective planning 时按消息尺寸选择的（正是 tuner 插件介入的地方）。`torch.distributed` 不暴露 algo/proto 参数。
2. **`NCCL_PROTO` 是进程全局 env**，无法按消息尺寸切换（全局 LL 会把 prefill 打爆：368KB → 3414µs，20×）。这正是当前 T1aM4 全局 Simple 牺牲 decode 小消息的根因。
3. **"自建 NCCL comm 换 proto"不可行**：NCCL 协议不挂在 communicator 上（是 per-collective 的 tuner 决策），创建多个 NCCL comm 也不能让同一个 comm 的小消息走 LL、大消息走 Simple。

**结论**：vLLM 层对"LL 协议快赢"**无正确改法**。vLLM 层唯一能实现的"小消息走自定义路径" = **完全绕过 NCCL 的自研小消息 allreduce kernel**（P1 2-hop / NVSHMEM / GDAKI，见 TRT-LLM bypass 报告 §3.2 方案 B），那是开发级项目，不是本 LL 快赢的落点。

### 3.3 若未来走 P1 自研 kernel，vLLM 层的侵入点（保留设计）

```python
# communication_op.py 插入点（P1 落地时）：
out = custom_all_reduce(input_)          # 现有，跨节点 None
if out is not None: return out
out = small_msg_allreduce(input_)        # 新增：≤阈值走自研 2-hop/NVSHMEM，否则 None
if out is not None: return out
# 原 pynccl / torch.distributed 分支保持
```
侵入度低（communication_op.py 加分支 + `device_communicators/` 新增 communicator）。但必须过 CUDA graph 捕获专项（fix72），且需要 GDAKI/NVSHMEM 在容器内可用（`ldconfig -p | grep nvshmem` 核实）。

### 3.4 与 CUDA graph 的兼容分析（对 LL 路径 A 与 P1 路径 B 都相关）

vLLM 0.26 的 graph capture 模式有明确的分层约束（源码注释已核实）：

```
# allreduce \ Mode | Eager | Graph |
# custom allreduce | enabled | enabled |
# PyNccl           | disabled| enabled |
# torch.distributed| enabled | disabled|
```

关键推论：
1. **Graph 捕获期 allreduce 走 PyNccl（→NCCL）**，`torch.distributed` 在捕获期被禁用。本环境生产 TP4 的 allreduce 在捕获期必然是 PyNccl→NCCL。**tuner 插件的协议选择在捕获期 planning 时生效，并被冻结进 graph**——per-batch-size 捕获（1..64）天然按尺寸选中 LL/Simple。重放期不重复调用 tuner（零每步开销）。
2. **LL 的 host 侧 CPU proxy 不是 graph 的一部分**：NCCL 捕获的 collective 在重放时由 GPU kernel 重跑 + host proxy 重新 post 网络操作。LL 对网络的 flag 轮询由 GPU kernel 承担、proxy 为 host 线程——**机理上可捕获，但 87 次/step × 重放时的 proxy 负载必须实测**（fix72 教训）。
3. **GB10 UMA 红利**：LL 的 net buffer 走 host 内存（禁 GPUDirect RDMA），UMA 下"host 内存"即 GPU 同池内存，无 PCIe 拷贝惩罚——架构上 LL 反而更优，阈值扫描已实证 LL 在真实环境可用且小消息赢。
4. **P1 自研 kernel 的 graph 兼容**必须自证（GDAKI GPU 发起 RDMA 可捕获；host 侧 post WQE 则难捕获）。

---

## 4. 推荐结论（二选一/组合）

| | 路径 A（tuner 插件） | 路径 B（vLLM 层） |
|---|---|---|
| 目标 | per-size 协议混合（LL for small） | 对 LL：**不可行**；对 P1 自研 kernel：可行但开发级 |
| 工作量 | ~0.5-1 人日（插件）+ 验证 | LL：无解；P1：~2-4 周 |
| 风险 | 中（graph/proxy 需实测） | 高（graph 兼容需自证） |
| 侵入 | 零（NCCL 插件层，不重编） | 中（communication_op.py + 新 communicator） |
| 与 ring-only | 兼容（net.cc 改动不影响） | 独立于 NCCL |

**决策：路径 A（NCCL tuner 插件）为唯一主推，vLLM 层对 LL 正式否决。** 理由：
1. **收益可达且已被实测**：LL 小消息 44.6-54.3µs（-28~34%）是容器实测，不是估计。
2. **工作量最小**：~200 行 C + gcc 编译，零 kernel、零重编、零 vLLM 改动。
3. **回滚最安全**：删 .so + 还原 env = 瞬时回滚，比重编/打镜像安全一个量级。
4. **vLLM 层对 LL 没有正确实现路径**（§3.2 三连证），投入即浪费。
5. **组合关系**：路径 A 完成后，若收益不足（暴露度折减），P1 的 2-hop kernel（路径 B 形态或 NCCL 补丁形态）作为下一阶段结构性方案，二者是**递进**关系，不是二选一。

---

## 5. 最小验证方案（容器 mock → vLLM 层 → 生产）

> 纪律：**每关通过才进下一关**。任一关失败即停止并回退，不强行上生产。

### 第 0 关：静态确认（零运行，5 分钟）
```bash
# 每机
nm -D <libnccl.so> | grep -i tuner      # 期望有 ncclTunerPluginLoad 等
ldd <libnccl.so> | grep -i tuner         # 期望空（插件是运行时 dlopen，不链接）
# 容器内
gcc --version                            # head 容器应有；worker 无则 head 编后 scp
```

### 第 1 关：容器 torch.distributed mock（零 vLLM，0.5 人日）
目标：验证插件在**真实四机 NCCL 环境**下按尺寸选路，且与 T1aM4 其余 env 共存。

1. **补齐 1KB/2KB LL 数据点**（阈值扫描首轮漏采）：同 `nccl_scan.py` 脚本，仅切 `NCCL_PROTO=LL`，补 1KB/2KB/3KB p50。确认低端也赢（预期 ≤16KB 赢 28-34%）。
2. **编译插件**（§2.4）→ 四机放置 → 容器内 torch.distributed all_reduce bench（复用 nccl_scan.py，env 变为 T1aM4-其余项 + `NCCL_TUNER_PLUGIN`，**去掉 NCCL_PROTO**）。
3. **判据**：
   - 各 size 曲线 ≈ "小消息取 LL 曲线、大消息取 Simple 曲线" 的组合（≤40KB 接近 LL 列，>40KB 接近 Simple 列）；
   - `NCCL_DEBUG_SUBSYS=TUNING` 确认小消息 selected proto=LL、大消息 selected=Simple；
   - 368KB/1MB 不劣化于 T1aM4 基线（173/198/315µs）。
4. **正确性**：all_reduce 结果逐元素一致（LL vs Simple，随机输入 + 多轮）。

### 第 2 关：CUDA graph 前置专项（最高风险，fix72 教训，0.5-1 人日）
> 无需插件也可先做（最便宜的 graph 兼容预检）：sglang 容器 vLLM TP4 **全局 `NCCL_PROTO=LL`** + 短上下文 + 显式 `--cudagraph-capture-sizes` 全档，验证：
> - capture 全档成功（1 2 4 8 16 24 32 36 40 48 56 64），无重捕获风暴；
> - TPOT 无周期尖峰（对比 Simple 基线）；
> - NCCL 绑核（8-9）上 CPU proxy 利用率不爆表（87 次/step × LL 轮询）——`ps -eLo tid,psr,pcpu | grep NCCL` 打点；
> - 与 Simple 数值 A/B。
> **注意**：全局 LL 会把长 prefill 打爆（368KB 20×），此关**只跑短上下文/decode 验证 graph 兼容性**，不碰长 prefill。

通过后**再上插件**跑同样的 graph 专项（per-size 形态，prefill 走 Simple 不受影响）。

### 第 3 关：vLLM 层 A/B（0.5-1 人日）
- sglang 容器 vLLM TP4 + 插件，短请求 A/B：
  - c1@32K（主判据：PR/DE/TTFT 相对 T1aM4 基线 ±10% 无回归）；
  - c1@131K（视窗判据，长 prefill → 验证 Simple 保住，不劣化）；
  - 带 `num_requests_running` 分层判读（T1aM4 窗口教训：R1 污染 DE 39 vs R2 纯净 93.84）。
- 判读：decode 侧若通信暴露，DE 应有提升；若被计算隐藏（历史 A/B 显示 Simple→LL 对 E2E 影响有限），至少无回归 + prefill 无劣化。

### 第 4 关：生产窗口 AB（0.5-1 人日，参考 MAX_CH16 SOP）
- **停机**：同 MAX_CH16 SOP §3.1（systemctl stop 保险 + docker rm -f 逆序）。
- **补丁**：备份 → start_tp4_head/worker.sh 加 `-v` 挂载 + `NCCL_TUNER_PLUGIN` + `NCCL_TUNER_THRESHOLD` + **删 NCCL_PROTO=Simple** → md5 记录 → check 脚本。
- **回滚锚点**：`.bak-ncclTUNER-20260816`（内容 = T1aM4+MAX_CH16 终态）。
- **启动/健康/观察**：同 MAX_CH16 SOP §3.3-3.5；env 确认无 NCCL_PROTO、有 NCCL_TUNER_PLUGIN；日志确认插件 load + 通道数正常。
- **Tessa AB**：32K 主判据 + 131K 视窗。
- **保留/回滚**：通过 → 归档锚点 + 更新 REFERENCE.md；不通过 → 还原脚本 + 重启（§6 回滚）。

---

## 6. 风险与对策

| # | 风险 | 影响 | 对策 | 缓解级别 |
|---|---|---|---|---|
| R1 | **LL 禁 GPUDirect RDMA（走 host）** | 带宽掉到 25-50%（LL 双写 + host 中转） | 1-16KB 不在乎带宽；**GB10 UMA 使 host=GPU 内存，代价≈0**；实测已证 LL 小消息赢 | 低（已实证） |
| R2 | **CUDA graph 兼容（fix72 教训）** | TPOT 崩/周期尖峰/重捕获风暴 | 第 2 关前置专项，全局 LL 先验证 graph 机理再上插件；P4 capture-sizes 显式化保留 | **高 → 先测** |
| R3 | **CPU proxy 负载** | 87 次/step × LL flag 轮询 + proxy，NCCL 绑核 8-9 利用率爆表 | 第 2 关打点 pcpu；超阈值则 tuner 只切 ≤16KB（减少 LL call 数）或放弃 | 中 |
| R4 | **阈值边界** | 40KB 边界若实际翻转点偏移，16-40KB 档 LL 可能劣化 | 边界定 40KB（安全余量 16KB 到 56KB 翻转点）；1KB/2KB 补测；**严禁 ≥56KB 走 LL** | 中 |
| R5 | **env 交互（NCCL_PROTO 未删）** | 插件失效，per-size 选择不生效（静默） | 部署 diff 明确删除；启动后 env 检查 + TUNING 日志确认选 LL | 低（流程） |
| R6 | **插件加载失败静默回退** | 不崩但无收益（回内部 tuner） | `NCCL_DEBUG=INFO` 看 "Successfully loaded tuner external plugin" 锚点；`nm -D` 预检 | 低（流程） |
| R7 | **正确性（fp8 数值）** | LL vs Simple 归约路径不同，fp8 数值漂移 | 第 1/2 关逐元素 A/B；dspark 投机路径数值复验 | 中 |
| R8 | **LL128 可用性** | 若想加第二条带（16-48KB LL128），跨机 RoCE 上需 128B 原子 + PATH_PXN——DGX Spark 单 GPU 无 PXN | **默认放弃 LL128 双带**；用 `NCCL_DEBUG=INFO` 看 init 日志是否 "LL128 not supported"；不支持则单边界 LL/Simple 即全部故事 | 低（不做即无此风险） |
| R9 | **回滚** | 生产回归需快速恢复 | 回滚 = 还原脚本（删插件 env + 恢复 NCCL_PROTO=Simple）+ 重启；.bak 锚点；比重编安全 | 低 |
| R10 | **收益折减** | decode 通信可能被计算隐藏（历史 Simple→LL E2E 仅 -2.7%~-9.8%） | 不承诺未经实测的 E2E 数字；第 3 关 A/B 定标；通信 5.2→4.2ms 即便部分暴露也是净赚 | 预期管理 |

---

## 7. 实施清单与工时

| 阶段 | 动作 | 工时 | 依赖 |
|---|---|---|---|
| S0 | 静态确认（nm/ldd/gcc） | 0.1 人日 | — |
| S1 | 1KB/2KB LL 补测 + 编译插件 + 容器 mock 四机 bench | 0.5 人日 | S0 |
| S2 | CUDA graph 前置专项（先全局 LL 后插件） | 0.5-1 人日 | S1 通过 |
| S3 | vLLM TP4 A/B（32K + 131K） | 0.5-1 人日 | S2 通过 |
| S4 | 生产窗口 AB + 回滚演练 | 0.5-1 人日 | S3 通过 |
| **合计** | | **~3-4 人日** | 关卡递进 |

**决策门**：S1 中 1KB/2KB LL 若反而劣化（低端不稳）→ 阈值上限保留但检查低端边界是否需 ≥2KB 才切 LL（per-size 边界可加下界，插件加一行）；S2 若 graph 不兼容 → 停止并评估 P1 2-hop kernel（届时需开发资源）。**S1/S2 是硬关卡，不通过不进入 S3/S4。**

---

## 8. 数据来源

- 本地：nccl-small-msg-trtllm-bypass-architect-2026-08-16 / nccl-proto-threshold-scan-2026-08-16 / nccl-p0-scan-results-2026-08-16 / findings-raw-2026-08-15 / nccl-latency-head-balance-architect-2026-08-16 / nccl-maxch16-ab-window-sop-2026-08-16
- Web（本轮核实）：
  - NCCL DeepWiki：Tuner Plugin API（v6 结构体 getCollInfo 签名、装载器版本握手、NCCL_TUNER_PLUGIN 加载策略、cost table 覆盖模式）；Performance Tuning and Algorithm Selection（LL 50% 带宽限制、LL128 PATH_PXN 要求、env 与插件交互）
  - NVIDIA Official Blog：Understanding NCCL Tuning（tuner 插件推荐、env 覆盖警告 "While those overrides are in place, any default choices by NCCL are ignored"）
  - NCCL 官方 env 文档（NCCL_TUNER_PLUGIN / NCCL_ALGO / NCCL_PROTO 取值与优先级）
  - vLLM 源码：communication_op.py（tensor_model_parallel_all_reduce 结构 + graph_capture_mode 分层约束表）、custom_all_reduce.py（同节点/NVLink 硬性要求）
  - 社区：gitcode《NCCL算法与协议组合的强制选择机制解析》（env vs 插件优先级实证）

---

## 附：与既往文档的衔接

| 既往文档 | 本报告的承接 |
|---|---|
| TRT-LLM bypass §8.6（路径定案：tuner 插件） | 本报告细化为实施级（接口签名/编译/部署/验证 SOP） |
| 阈值扫描 §3（阈值 40KB 待 Archi 确认） | **定案 40KB 单边界**，新增 1KB/2KB 补测项 |
| head-balance P2-2（per-size 协议混合） | 正式落地为 tuner 插件（v6 getCollInfo） |
| MAX_CH16 SOP | 生产窗口 AB 复用其停机/回滚框架 |
