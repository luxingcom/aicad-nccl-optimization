# src/ — 源码与实验脚本（可复现参考）

> **说明**：本目录只包含**轻量文本源码/脚本**（实验与参考用），**不包含**完整 NCCL 源码树与编译产物。
> 生产库二进制不随资料包分发；完整源码树 + git bundle 见服务器归档（§3）。

## 文件清单

### tuner 插件源码（ADR-014 基线，未部署）
| 文件 | 说明 |
|---|---|
| `tuner_per_size.c` | per-size tuner 插件（外部插件形式）。S1 实测阻断后转为内部 tuning.cc 双带实现；此源码留档为未来 0.27 评估 B 选项的 cost-table 访问范式参考 |
| `tuner_noop.c` | no-op 插件（S1 阻断对照实验用） |
| `spcx_stub_tuner.c` | SPCX 劫持模拟 stub（验证 StageB 双分支加固，S1.12） |

### 2-hop 实验脚本（已 D 收尾归档，仅复现）
| 文件 | 说明 |
|---|---|
| `twohop_algo.py` | 2-hop bilateral 算法原型（gather→direct→reduce 相位） |
| `twohop_bench.py` | 2-hop 基准 runner |
| `bilateral_micro.py` / `p0_inversion.py` / `cudagraph_test.py` | 微观基准 / P0 反转诊断 / CUDA graph 对照 |
| `run_p0.sh` | P0 诊断运行脚本（含脱敏凭据占位符） |

## 2-hop 结论（必须阅读后再复现）

- 2-hop bilateral 在当前 NCCL ring 原语框架内被**干净否定**（SIMPLE 双 Primitives illegal memory access 崩溃；LL/LL128 价值区不可触及）。
- 终审：`docs/reports/2hop-s3-final-adjudication-2026-08-17.md`；归档：`docs/reports/2hop-archive-manifest-v1-2026-08-17.md`。
- 本目录脚本仅供追溯实验过程，**不作为生产路径**。

## 服务器归档路径（完整源码/构建）

| 内容 | 服务器路径 |
|---|---|
| 生产基线源码树（hardened） | `/opt/aicad-prod/backup/nccl-official-2307-hardened-20260816/` |
| StageB（pre-hardened）源码 | `/opt/aicad-prod/backup/nccl-official-2307-stageB-20260816/` |
| 2-hop 完整归档（源码 + git bundle + libs + failures + data） | `/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/` |
| 2-hop git bundle（自包含可 clone） | 同上 `git-bundle/nccl-2hop-proto-20260817.bundle` |

> 重建命令：`make -j src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE=-gencode=arch=compute_121,code=sm_121`（anemll 0.2.1 容器，glibc ≤2.34）。
