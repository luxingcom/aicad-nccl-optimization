# NCCL per-size tuner 插件 · S1 容器验证报告（BLOCKED）

**日期**：2026-08-16
**执行**：Rex（SRE 工程师）
**性质**：S1 硬关卡容器验证（四机 torch.distributed bench，sglang 26.07 容器 + ring-only lib）
**结论**：**S1 未通过 —— 外部 tuner 插件机制与 ring-only P2 lib 的 net 连接不兼容（硬阻断）**。插件本体已实现/编译/加载成功，但插件一旦加载即破坏 net 连接的 GID 配对（与插件逻辑无关，no-op 插件同样复现）。**不进入 S2**。推荐走设计文档 §2.6 退化路径（改 `tuning.cc` 内部重编），需主理人/架构师批准。

---

## 0. TL;DR

| 项 | 结果 |
|---|---|
| 插件源码 + 编译 | ✅ 完成，`ncclTunerPlugin_v6` 导出，aarch64 .so |
| 插件加载 | ✅ `Successfully loaded external tuner plugin`（四机一致） |
| getCollInfo 生效 | ✅ 已进入回调；修复一处 cost-table 二维数组索引 bug（崩溃根因） |
| 基线（无插件 Simple） | ✅ 正确性 ok=True，368KB≈170µs，小消息 55-62µs |
| **插件路径 allreduce** | ❌ **net 连接 GID 配对错误 → 失败**（no-op 插件同样失败） |
| **决策门** | **S1 BLOCKED，不进入 S2** |

---

## 1. 已完成产物

### 1.1 插件源码（最终版，已修复 cost-table 索引 bug）
`/opt/nccl-tuner-plugin/tuner_per_size.c`（约 140 行，镜像留档 `nccl-tuner-plugin/tuner_per_size.c`）
- 导出 `ncclTunerPlugin_v6`，仅实现 v6。
- `getCollInfo`：仅干预 allreduce；≤40KB（`NCCL_TUNER_THRESHOLD` 可覆盖）期望 LL，>40KB 期望 Simple；可选 `NCCL_TUNER_LL_MIN` 下界；不碰 nChannels。
- **关键修复**：NCCL 以 `float**` 传入的 `collCostTable` 实为**连续 `float[numAlgo][numProto]` 数组**，必须 cast 为 `float (*)[NCCL_NUM_PROTOCOLS]` 再按 `table[a][p]` 访问（参考 enqueue.cc 与官方 example）。**直接 `collCostTable[a][p]` 会把数组元素当指针解引用 → 段错误/核心转储**（第一版崩溃根因）。
- 改表策略：期望协议在各非 IGNORE algo 行置 `0.0f`，其余协议保留 NCCL 自算成本（正值）；跳过 IGNORE 组合。

编译（容器内）：
```bash
gcc -O2 -fPIC -shared -o libnccl_tuner_persize.so tuner_per_size.c -I.
# 符号验证：nm -D libnccl_tuner_persize.so | grep ncclTunerPlugin_v6  → D ncclTunerPlugin_v6
```

### 1.2 编译产物
| 产物 | md5 | 大小 |
|---|---|---|
| `/opt/nccl-tuner-plugin/libnccl_tuner_persize.so` | `0edd825c99d7180e2f7d00a9993c40e4` | 70056 B |
| `/opt/nccl-tuner-plugin/libnccl_tuner_noop.so`（对照） | `97aecc126c40230316988d882df61311` | — |

### 1.3 环境/验证脚本（落盘 /opt/nccl-tuner-plugin/）
`tuner_per_size.c` / `tuner_noop.c` / `bench_scan.py`（字节尺寸、含正确性校验）/ `check_correct.py` / `mini_plugin_test.py` / `quick_init.py` / `start_one_nccltune.sh`（a=baseline,b=plugin,n=noop,s=stock 四配置）/ `run_full.sh` / `run_bench.sh` / 等。

---

## 2. 验证过程与证据

### 2.1 环境
- 四机 DGX Spark（GB10 UMA），SSH <node1>/02/04/03，rank 映射与生产一致（0=01,1=02,2=04,3=03）。
- 测试容器：sglang 26.07（gcc 13.3.0，nccl.h 于 /usr/include，torch 2.13），`LD_PRELOAD=/opt/nccl-ringonly/libnccl.so.2`（ring-only P2 lib）。
- env 复刻生产（T1aM4+MAX_CH16）：`NCCL_ALGO=RING, NCCL_NET=IB, NCCL_IB_GID_INDEX=3, NCCL_IB_TOS=46, NCCL_MIN_NCHANNELS=4, NCCL_MAX_NCHANNELS=16, NCCL_BUFFSIZE=8M, NCCL_SOCKET_IFNAME=enP7s7, NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1, NCCL_IB_SUBNET_AWARE_ROUTING=1, NCCL_IB_TIMEOUT=1000, NCCL_IB_RETRY_CNT=7`。
- **关键环境点**：`NCCL_IB_PEER_HCA` 为**逐机不同**的值（生产如此）：
  - rank0(01): `1=rocep1s0f1,roceP2p1s0f1;3=rocep1s0f0,roceP2p1s0f0`
  - rank1(02): `0=rocep1s0f1,roceP2p1s0f1;2=rocep1s0f0,roceP2p1s0f0`
  - rank2(04): `1=rocep1s0f0,roceP2p1s0f0;3=rocep1s0f1,roceP2p1s0f1`
  - rank3(03): `0=rocep1s0f0,roceP2p1s0f0;2=rocep1s0f1,roceP2p1s0f1`
  > 早前用 rank0 的值套全部节点会导致 GID 错配——这是本环境 ring-only P2 补丁的部署前提。

### 2.2 基线（cfg=a：无插件 + `NCCL_PROTO=Simple`）—— ✅ 通过
`/opt/nccl-tuner-plugin/bench-out/a-rank0-20260816_013821.log`
```
S   1024 avg= 73.7 p50= 54.5 ok=True
S   2048 avg=104.1 p50= 55.1 ok=True
S   4096 avg= 87.9 p50= 57.8 ok=True
S   8192 avg= 66.6 p50= 58.8 ok=True
S  16384 avg= 62.6 p50= 62.4 ok=True
S  40960 avg= 72.0 p50= 70.7 ok=True
S 368640 avg=161.5 p50=170.5 ok=True   # 368KB 主档 ≈ 设计 173µs ✅ 不劣化
S 1048576 avg=191.6 p50=166.1 ok=True
S 4194304 avg=334.3 p50=311.2 ok=True
```
正确性 `ok=True`（逐元素=sum(ranks)，多轮可复现）。所有尺寸全对。

### 2.3 插件加载（cfg=b：`NCCL_TUNER_PLUGIN=/opt/nccl-tuner-plugin/libnccl_tuner_persize.so`，无 NCCL_PROTO）—— ✅ 加载成功
`NCCL_DEBUG=INFO` 四机日志锚点：
```
NCCL INFO NCCL_TUNER_PLUGIN set by environment to /opt/nccl-tuner-plugin/libnccl_tuner_persize.so
NCCL INFO TUNER/Plugin: Using PerSizeLLSimple (v6)
NCCL INFO Successfully loaded external tuner plugin /opt/nccl-tuner-plugin/libnccl_tuner_persize.so
```

### 2.4 插件路径 allreduce —— ❌ 阻断
首个 allreduce（1KB，插件选 LL）即失败，核心错误为 net 连接 GID 错配：
```
Call to ibv_modify_qp failed with 110 Connection timed out, on dev rocep1s0f1:1,
local GID ::ffff:<NFS-IP> (01-f1), remote GID ::ffff:<NFS-IP> (03-f1)
```
即 01 的 f1 口尝试连 03 的 f1 口；物理上 01-f1 应连 02-f1、01↔03 应走 f0。**P2 补丁的逐 peer HCA 覆盖在该连接上未生效/错位**。

### 2.5 隔离实验（确认与插件逻辑无关、与协议无关）
| 配置 | 插件 | NCCL_PROTO | 结果 |
|---|---|---|---|
| cfg=a | 无 | Simple（容器 env） | ✅ allreduce 正常 |
| cfg=b | per-size 插件 | 无（默认全 proto 开） | ❌ GID 错配 |
| cfg=b + `NCCL_TUNER_THRESHOLD=0` | per-size 插件（强制全 Simple） | 无 | ❌ GID 错配 |
| cfg=n | **no-op 插件（不碰 cost table）** | 无 | ❌ GID 错配 |
| cfg=n + `NCCL_PROTO=Simple` | no-op 插件 | Simple（exec env） | ❌ GID 错配（矩阵已收缩为 Simple-only，仍失败） |
| cfg=s | 无 | 无 | ❌ stock lib 无 P2 补丁，本拓扑连不上（对照） |

**结论：任何外部 tuner 插件一旦被加载，ring-only P2 lib 的 collective net 连接即错乱**（no-op 插件亦复现；矩阵、协议、env 均不相关）。基线（无插件）唯一可用。

---

## 3. 根因分析（证据级）

1. **P2 补丁修改点**：`src/transport/net.cc` 新增 `ncclIbPeerHcaOverride()`，在 `sendSetup/recvSetup` 里按 `NCCL_IB_PEER_HCA` 逐 peer 覆盖 `req.netDev`（backup 源码 295-410 行）。外部插件加载后，collective 的 net 连接（proxy `sendProxyConnect`/`ncclIbConnectImpl`）走该路径时 GID 配对错位。
2. **矩阵差异**：
   - cfg=a（NCCL_PROTO=Simple）：`AllReduce | LL=0 LL128=0 Simple=1`（仅 Simple）。
   - cfg=b/n（无 NCCL_PROTO）：`AllReduce | LL=1 LL128=2 Simple=1`（全 proto 开）。
   - 但 cfg=n+`NCCL_PROTO=Simple` 矩阵已收缩为 Simple-only 仍失败 → **非"多 proto 连接冲突"单一原因**；更可能是插件加载本身改变了 NCCL 的 net 连接建立流程/时序，使 `ncclIbPeerHcaOverride` 的 peer 上下文错位。
3. **设计假设 vs 实测**：设计 §2.6 称"net.cc 是传输层，tuner 是调度层，二者解耦"——**实测被证伪**。ring-only 定制库的 net 连接与 tuner 路径存在耦合，外部插件会破坏之。

---

## 4. 建议（需主理人/架构师批准）

- **S1 判为 BLOCKED**，不进入 S2（CUDA graph 专项）——当前插件形态无法产出有效 per-size 数据。
- **主推退化路径（设计 §2.6 已备）**：改 `src/graph/tuning.cc`/`enqueue.cc` 内部 tuner 逻辑，按 nBytes 强制协议（≈10 行），重编 ring-only lib（已有 build 路径），四机替换。该路径**不加载外部插件**，走的正是基线已验证可用的内部 tuner 路径，理论上可绕过本阻断。但属生产库级变更 + 需停机窗口，须架构师评估后执行。
- **备选**：修复 ring-only P2 lib 的 `ncclIbPeerHcaOverride` 与外部 tuner 的交互（NCCL 级开发，工作量较大）。
- 若走退化路径，S1 的验证判据不变（小消息 LL 28-34% 收益、368KB 不劣化、正确性 ok），验证脚本已就绪可复用。

---

## 5. 风险/提示

- 测试容器（nccltune-a/b/n/s-rank{0,1,2,3}）仍运行于四机（sleep 驻留，低占用）。如不再需要可 `bash /opt/nccl-tuner-plugin/cleanup_containers.sh <cfg>` 清理。
- 未触碰任何生产资源（vllm-tp4-rank* 容器、/opt/aicad-prod/scripts、生产 env）。
- 插件 .so 已四机同 md5；若后续改源码需同步重编重分发。

## 6. 关键日志/产物留档
- 源码：`/opt/nccl-tuner-plugin/tuner_per_size.c`、`tuner_noop.c`
- 基线数据：`/opt/nccl-tuner-plugin/bench-out/a-rank0-20260816_013821.log`
- 插件加载日志：运行期 `NCCL_DEBUG=INFO` 抓取（四机均现锚点）
- 阻断证据：`/tmp/dbg-r*.log`（插件 GID 错配）、`/tmp/full-r*.log`（no-op+Simple 仍失败）
