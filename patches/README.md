# patches/ — NCCL 2.30.7 ring-only 定制补丁集

> 本目录为 **AICAD DGX Spark 四机 TP4 NCCL 优化** 的全部补丁与归档脚本。
> 所有补丁均为文本 diff，可直接审阅；**不包含**编译产物与生产库二进制。
> 重建指引见本文件 §5。

## 1. 补丁清单

| 补丁 | 文件 | 用途 | 对应 ADR/决策 | 适用版本 | 状态 |
|---|---|---|---|---|---|
| **v1 环邻过滤** | `v1-ring-only.patch` | `src/transport.cc`：`ncclTransportP2pConnect` 跳过非环邻跨节点 peer，实现 RING-only 拓扑 | ADR-015（Stage A 起点） | NCCL 2.30.7（官方源码干净重建） | ✅ 已上线 |
| **v4 硬编码 per-peer 映射** | `v4-netdev-hardcode.patch` | `src/transport/net.cc`：静态 `(myRank, peerRank)→(devA, devB)` 表替代 `NCCL_IB_PEER_HCA` env 解析 | ADR-015 | NCCL 2.30.7 | 🗄️ 归档（被 v5 取代；内建表即 v5 默认表） |
| **v5 可配置 per-peer 映射** | `v5-netdev-configurable.patch` | `src/transport/net.cc`：内建默认表（=v4 生产表）+ `NCCL_RING_DEV_MAP`/`NCCL_RING_DEV_MAP_FILE` 运行期覆盖；非法配置 WARN+回退默认表。换拓扑免重编库 | ADR-016（2026-09-19） | NCCL 2.30.7 | 🧪 新增（真机编译/四机验证待维护窗口） |
| **Stage B tuner（双带）** | `stageB-tuner-two-band.patch` | `src/enqueue.cc`：per-size tuner（≤40KB→LL / >40KB→Simple，仅 allreduce） | ADR-014 / S1.11 | NCCL 2.30.7 | ✅ 已上线（3d9cf539） |
| **Stage B 双分支加固** | `stageB-hardened-two-branch.patch` | 提取 override 为 `ncclPersizeTunerOverride()`，在 tuner!=NULL / tuner==NULL 双分支均生效，防 SPCX 外部 tuner 劫持静默失效 | ADR-014 / S1.12 | NCCL 2.30.7 | ✅ 已上线（**生产 2be94172**） |
| **2-hop proto host plumbing** | `2hop-proto-host-plumbing.patch` | `tuning.cc`/`tuner_v5.h`/`device.h` 等：2HOP 算法注册与常量（**实验性质，已 D 收尾归档**） | S1.13 / 2-hop 终审 | NCCL 2.30.7（2hop-proto 分支） | ⛔ 归档（否定结论） |
| **2-hop proto kernel** | `2hop-proto-kernel.patch` | `src/device/all_reduce.h` 等：2HOP kernel 实现（bilateral，**实验性质**） | S1.13 / 2-hop 终审 | NCCL 2.30.7（2hop-proto 分支） | ⛔ 归档（否定结论） |

> ⚠️ **2026-09-19 修订**：v4 补丁第 4 个 hunk 的行数声明（`+382,7`）与实际行数不符（尾部幻影空行），`git apply` 可能因 hunk 漂移失败——已在本次修订清理为规范 LF 格式并通过 hunk 自洽校验。v5 补丁由官方 2.30.7-1 原件真实 diff 生成并做了往返逐字节验证。
> ⚠️ **行尾纪律**：所有 `.patch` 必须为 **LF** 行尾（本仓库 `.gitattributes` 已强制 `*.patch text eol=lf`）。经 Windows/其他渠道传输后若 `git apply` 报 phantom context 错误，先 `dos2unix patches/*.patch`。

## 2. 补丁依赖关系（按顺序应用）

生产路径（Stage A → Stage B → 加固）：

```bash
# 1. 官方源码干净重建（Stage A）
git clone https://github.com/NVIDIA/nccl -b v2.30.7-1 nccl-2307
cd nccl-2307
git apply patches/v1-ring-only.patch
# 2. per-peer 映射：v5（可配置，ADR-016）或 v4（纯硬编码，归档基线）
git apply patches/v5-netdev-configurable.patch    # 推荐；运行期可用 NCCL_RING_DEV_MAP* 覆盖
# （等价旧路径：git apply patches/v4-netdev-hardcode.patch）
# 3. Stage B tuner（S1.11 上线）
git apply patches/stageB-tuner-two-band.patch
# 4. 双分支加固（S1.12 生产终态）
git apply patches/stageB-hardened-two-branch.patch
```

2-hop 归档路径（仅复现实验，勿用于生产）：

```bash
git apply patches/2hop-proto-host-plumbing.patch
git apply patches/2hop-proto-kernel.patch
# 或使用自动化脚本（会处理两个补丁 + 记录 md5）
python3 patches/apply_2hop_patch.py --help
```

## 3. 辅助脚本

| 文件 | 用途 |
|---|---|
| `apply_2hop_patch.py` | 2-hop 补丁应用脚本（检查前置/冲突、应用、记录 build 前 md5） |
| `record_2a.sh` / `record_2b.sh` | 2-hop Step2a/2b 结果记录脚本（归档用） |

## 4. 对应决策文档索引

| 补丁 | 决策文档 |
|---|---|
| v1/v4 / StageB | `docs/adr/ADR-015-ringonly-netdev-hardcode-S1-S1.13.md`、`docs/adr/ADR-014-per-size-protocol-internal-tuning-vs-plugin.md` |
| **v5（可配置）** | `docs/adr/ADR-016-ring-devmap-runtime-configurable-v5.md`；工具链 `tools/gen_devmap.py` / `tools/probe_ring_topology.sh` |
| StageB tuner | `docs/reports/00-FINAL-REPORT-nccl-optimization-2026-08-16.md` §3 |
| 2-hop | `docs/reports/2hop-s3-final-adjudication-2026-08-17.md`、`docs/reports/2hop-archive-manifest-v1-2026-08-17.md` |

## 5. 重建指引（不含编译产物）

生产库 `2be94172` 重建（anemll/dspark-vllm-gx10:0.2.1-v026.0 容器，glibc 2.35 / CUDA 13.0）：

```bash
# 源码：/opt/aicad-prod/backup/nccl-official-2307-hardened-20260816/（服务器归档）
make -j src.build CUDA_HOME=/usr/local/cuda \
  NVCC_GENCODE=-gencode=arch=compute_121,code=sm_121
# 产物：build/lib/libnccl.so.2.30.7
# 部署：安装为 /opt/nccl-ringonly/libnccl.so.2，四机同 md5
```

> 约束：生产镜像 glibc ≤2.34，编译工具链必须匹配（9cdb26dc 曾因 GLIBC_2.38 阻断）。
> 完整 md5 记录见服务器各归档 `MD5-RECORD.txt` 与 `config/production-nccl-env.md` §3。

## 6. 服务器归档路径（源）

- 生产基线源码 + 补丁：`/opt/aicad-prod/backup/nccl-official-2307-hardened-20260816/`（patches/ 目录）
- StageB（pre-hardened）：`/opt/aicad-prod/backup/nccl-official-2307-stageB-20260816/`
- 2-hop 归档：`/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/`
- 生产库 md5 记录：`/opt/nccl-ringonly/MD5-RECORD.txt`（服务器）
