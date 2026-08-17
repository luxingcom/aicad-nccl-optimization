# 生产 NCCL 环境参数基线（start_tp4_head.sh 关键行）

> 采集：<node1> 生产启动脚本 `/opt/aicad-prod/scripts/start_tp4_head.sh`（2026-08-17 现场实测）
> 对应最终基线文档：`docs/benchmarks/00-FINAL-BASELINE-v3-2026-08-17.md` §1.3

## 1. 容器启动 NCCL 相关（docker run -e）

```bash
# 双库 LD_PRELOAD（ncclpin shim + ring-only 定制库）
-e 'LD_PRELOAD=/opt/libncclpin.so /opt/nccl-ringonly/libnccl.so.2'

# === 算法 ===
-e 'NCCL_ALGO=RING'                     # 环邻过滤后的 RING-only（库内硬编码）

# === 通道/缓冲（T1aM4 + B1 组合；B1 于 2026-08-17 固化：MAX_CH 16→4）===
-e 'NCCL_MIN_NCHANNELS=4'               # MIN_CH4
-e 'NCCL_MAX_NCHANNELS=4'               # MAX_CH4（B1：16→4，2026-08-17）
-e 'NCCL_BUFFSIZE=8388608'              # 8M 管道加深

# === per-size tuner（Stage B 双分支加固）===
-e 'NCCL_TUNER_THRESHOLD=40960'         # ≤40KB→LL / >40KB→Simple（仅 allreduce）
-e 'NCCL_NET_PLUGIN=none'               # SPCX tuner 劫持防护（tuner 生效前提）
# 注意：无 NCCL_PROTO 覆盖（Stage B 唯一移除项，env 优先级高于 tuner）

# === IB 设备/网络 ===
-e 'NCCL_NET=IB'
-e 'NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1'  # 4 twin 口全暴露
-e 'NCCL_IB_GID_INDEX=3'
-e 'NCCL_IB_TIMEOUT=1000'
-e 'NCCL_IB_RETRY_CNT=7'
-e 'NCCL_IB_TOS=46'
-e 'NCCL_IB_MERGE_NICS=0'
-e 'NCCL_IB_SUBNET_AWARE_ROUTING=1'
-e 'NCCL_CROSS_NIC=1'
-e 'NCCL_SOCKET_IFNAME=enP7s7'
-e 'NCCL_IGNORE_CPU_AFFINITY=1'
-e 'NCCL_DEBUG=INFO'
-e 'NCCL_DEBUG_FILE=/var/log/vllm/nccl-%h.log'
-e 'NCCL_SET_THREAD_NAME=1'

# === 其他 vLLM ===
-e 'VLLM_DISABLE_PYNCCL=1'
-e 'VLLM_USE_B12X_MOE=1'
-e 'VLLM_USE_BREAKABLE_CUDAGRAPH=1'
-e 'VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096'
-e 'VLLM_USE_FLASHINFER_SAMPLER=1'
-e 'VLLM_DSPARK_LOCAL_ARGMAX=1'
-e 'VLLM_TRITON_MLA_SPARSE=1'
-e 'VLLM_ALLOW_LONG_MAX_MODEL_LEN=1'
-e 'VLLM_ENGINE_READY_TIMEOUT_S=600'
-e 'VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800'
```

## 2. 参数含义与历史对照

| 参数 | 值 | 说明 | 决策/文档 |
|---|---|---|---|
| `NCCL_MIN_NCHANNELS` | 4 | 减少小消息通道数，配合 8M buffer 降低延迟 | T1aM4（ADR 链） |
| `NCCL_MAX_NCHANNELS` | **4** | **B1（2026-08-17）：16→4，大消息延迟更优**（112KB -34% / 224KB -46%，nccl-tests）；历史 16 为 MAX_CH16 上线值 | ADR-015 S1.14 / B1 窗口 |
| `NCCL_BUFFSIZE` | 8388608 | 8MB 管道缓冲 | T1aM4 |
| `NCCL_TUNER_THRESHOLD` | 40960 | per-size tuner 边界 40KB | ADR-014 / S1.11 |
| `NCCL_NET_PLUGIN` | none | 禁用外部 tuner 插件防劫持 | S1.12 双分支加固 |
| `NCCL_IB_HCA` | 4 口 | 双口 × 2（roceP2p1s0f* 为 P2 口） | v3 验证 |
| `NCCL_IB_PEER_HCA` | —（已移除） | P1 治理已从脚本删除（库内硬编码 per-peer 映射替代） | ADR-015 / S1.13 §附带 |

## 3. 生产库 md5 快照

| 角色 | 文件 | md5 |
|---|---|---|
| 生产（当前） | `/opt/nccl-ringonly/libnccl.so.2.30.7` | `2be94172c1172734d00dee9ff7d788bd` |
| 备份（stageB hardened 前） | `/opt/nccl-ringonly/libnccl.so.2.30.7.bak-hardened-20260816` | 3d9cf539（阶段B glibcfix） |
| 归档 | `/opt/aicad-prod/backup/nccl-official-2307-*` | 见各归档 MD5-RECORD.txt |

> ⚠️ 生产库二进制不随资料包分发；重建指引见 `patches/README.md`。
