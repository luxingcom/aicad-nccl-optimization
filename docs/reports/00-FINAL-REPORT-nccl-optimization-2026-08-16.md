# DGX Spark 四机 TP4 NCCL 通信优化最终报告

**日期**：2026-08-16
**状态**：✅ Stage B 已上线生产（per-size tuner 最终落地）
**评审**：EngineeringAssuranceTeam（Archi 架构 / Rex SRE / Tessa QA）

---

## 1. 项目概览

- **硬件**：4×DGX Spark（GB10，UMA 121.6GiB），环网 4 边双 200G RoCE 直连（无交换机），每机 1×ConnectX-7 双口
- **软件**：vLLM 0.26 TP4（DeepSeek V4 Flash 0731），NCCL 2.30.7 ring-only 定制
- **核心瓶颈**：decode 每 step 87 次小 allreduce（1-16KB）+ prefill 大 allreduce（368KB 主档）
- **优化目标**：降低 allreduce 延迟 → 提升端到端 PR/DE/TTFT

## 2. 优化历程（三阶段）

| 阶段 | 配置 | 368KB allreduce | 端到端 32K | 端到端 131K | 状态 |
|---|---|---|---|---|---|
| A0 原始 | 默认 64 通道 | 923µs | PR 2110/DE 96 | PR 1809/TTFT 63s | 基线 |
| **T1aM4** | Simple+MIN_CH4+BUFFSIZE 8M | 410µs (-56%) | PR 2272/DE 94 | wave1 +11.3% | ✅ 已上线 |
| **+MAX_CH16** | +16CH | 173µs (-58%→-81%) | PR 2397/DE 100 | PR 2203/TTFT 52s | ✅ 已上线 |
| **+Stage B** | per-size tuner（≤40KB→LL） | 173µs（Simple 保持） | PR 2420-2423/DE 98.7-99.9 | PR 2197-2204/DE 96.7-100.6 | ✅ **本次上线** |

## 3. Stage B（per-size tuner）实施摘要

### 3.1 目标与机制
- decode 小消息（1-16KB）当前 Simple 下 55-80µs/call → 走 LL 协议可降 19-27%
- 阈值扫描实测：≤32KB LL 快 9-34%，翻转点 ~40KB，≥48KB Simple 必须（LL 大消息爆炸 20×）
- **40KB 单边界**：≤40KB→LL / >40KB→Simple（仅 allreduce）

### 3.2 实施路径（关键决策演进）
1. **外部 tuner 插件**（NCCL_TUNER_PLUGIN）→ S1 实测**阻断**（插件加载破坏 ring-only P2 net 连接）
2. **内部 tuning.cc 双带** → 备份树**源码漂移**（v2 快照 vs 生产 v3 二进制，v3 源码未归档）
3. **官方源码干净重建**（Stage A）：NCCL 2.30.7-1 + v1 环邻过滤 + v4 硬编码 per-peer 映射（ADR-015）
4. **Stage B**：enqueue.cc 双带 tuner（PerSizeTuner），40KB 阈值

### 3.3 关键教训
- 测试库必须带 `libnccl.so.2` 符号链接（否则 fallback 系统库，全部测试无效）
- 生产镜像 glibc ≤2.34，编译工具链必须匹配（9cdb26dc 因 GLIBC_2.38 阻断，3d9cf539 重编通过）
- `NCCL_NET_PLUGIN=none` 是 tuner 生效前提（SPCX tuner 劫持防护）
- `NCCL_PROTO=Simple` env 优先级高于 tuner，必须移除

### 3.4 容器 A/B 验证（GLIBC 修复版 3d9cf539）
| 字节 | tuner(LL) | 全 Simple | 收益 |
|---|---|---|---|
| 4KB | 42.7 | 58.3 | **-27%** |
| 8KB | 44.4 | 57.0 | **-22%** |
| 16KB | 48.7 | 61.4 | **-21%** |
| 32KB | 54.7 | 67.8 | **-19%** |
| 368KB | 193.2 | 176.2 | 持平 |
| 1MB | 294.5 | 293.9 | 持平 |

## 4. 生产部署与端到端验证

### 4.1 部署执行（2026-08-16 15:3x）
- 四机备份：库 `.bak-stageB-prod-20260816` + 脚本 `.bak-stageB-prod-20260816`
- 部署库：3d9cf539（GLIBC_2.34 兼容）
- env 变更：**移除 NCCL_PROTO=Simple**（唯一必需）；保留 ALGO=Ring / NET_PLUGIN=none / MIN_CH4 / MAX_CH16 / BUFFSIZE 8M
- 重启：worker 02/04/03 → head 01
- 确认：四机 healthy + /v1/models 200 + 无 110 + 容器加载库 md5=3d9cf539

### 4.2 端到端性能（全量测试，纯净窗口，0 错误）

**四档 FULLTEST 实测**（concurrency 1 / coding / rounds 3，与三级基线同参）：

| 档位 | PR | DE | TTFT | Total |
|---|---|---|---|---|
| FULL32K_A | 2425.93 | 98.06 | 11.89s | 16.88s |
| FULL32K_B | 2424.15 | 99.07 | 11.96s | 17.12s |
| FULL131K_A | 2217.81 | 96.72 | 51.91s | 56.92s |
| FULL131K_B | 2182.11 | 92.21 | 53.25s | 58.79s |

稳定性：32K 三指标 Δ<1.1% 高度稳定；131K PR/TTFT Δ<2.6% 稳定，DE Δ4.9%（completion 短窗口样本方差）。

**三级基准比较**（Stage B A/B 均值）：
| 基线 | 32K PR/DE/TTFT | 131K PR/DE/TTFT |
|---|---|---|
| vs A0 原始（2110/96/13.6；1809/101.94/63.2） | **+14.93%** / +2.7% / **-12.32%** | **+21.61%** / -7.3% / **-16.80%** |
| vs T1aM4（2272/93.84/12.56；2014/91.99/57.4） | **+6.73%** / **+5.03%** / **-5.06%** | **+9.23%** / **+2.69%** / **-8.40%** |
| vs MAX_CH16（2396.73/99.97/12.06；2202.66/99.85/52.33） | +1.18% / -1.41% / -1.12% | -0.12% / -5.39%* / +0.48% |

*131K DE 边缘项判定（Tessa）：非系统性回归——合并 STAGEB 预跑 4 样本均值 96.57 → Δ-3.29% 未破 -5% 线；MAX_CH16 的 99.85 为单点高值样本；相对 T1aM4 反而 +2.69% 改善。

**判读结论（Tessa）**：🟢 **Stage B 保留生产（放行），不触发回滚**。32K 主判据 vs 紧邻基线三绿（PR 2425>2045 / DE 98.6>84.5 / TTFT 11.9<13.8）；131K PR 2200>1629 / TTFT 52.6<69.5；vs 直接前任 T1aM4 全面改善；小消息 LL 收益已在 decode 侧兑现（32K DE +5.03%）。

### 4.3 累计收益（vs A0 原始基线）
- 368KB allreduce：923µs → **173µs（-81%）**
- 32K：PR 2110 → **~2420（+15%）**、DE 96 → **~99（+3%）**
- 131K：PR 1809 → **~2200（+22%）**、TTFT 63s → **~52s（-17%）**

## 5. 源码存档与文档清单

### 5.1 源码存档
- 官方源码：`/tmp/nccl-official-2307`（git tag `nccl-2307-stageB-v1` + `nccl-2307-stageB-glibcfix`）
- 归档：`/opt/aicad-prod/backup/nccl-official-2307-stageB-glibcfix-20260816/`（295M）
- patches：`v1-ring-only.patch` / `v4-netdev-hardcode.patch` / `stageB-tuner-two-band.patch`
- 库 md5 记录：v3=`b7784b49` / Stage A=`0d83f945` / Stage B=`9cdb26dc`（GLIBC 阻断）/ Stage B prod=`3d9cf539` / **Stage B hardened prod=`2be94172`（当前，2026-08-16 09:22 上生产）**

### 5.2 文档清单（23 份 8/16，本地+服务器双份）
- 验证报告：t1am4-e2e / maxch16-e2e / maxch16-large-msg / stageb（Rex）/ ab-results / stageb-fulltest（Tessa 判读）/ **followup-tests（Tessa 遗留复测）**
- 扫描数据：p0-scan / proto-threshold / large-msg-nonmonotonic
- Archi 报告：latency-head-balance / small-msg-trtllm-bypass / tuner-implementation / allreduce-offload-research / large-msg-nonmonotonic / stageA-recheck / **tree-algo-feasibility（P2-3 评估）**
- ADR：tuner-internal-vs-plugin / tuner-netdev-hardcode（S1.5-S1.11）
- SRE 报告：tuner-s1-report / tuner-s1-reverify
- SOP：maxch16-ab-window
- **最终报告：nccl-optimization-final-report（本文件）**

## 6. 回滚预案
- 库还原：`/opt/nccl-ringonly/libnccl.so.2.30.7.bak-stageB-prod-20260816`（= v3 b7784b49）
- 脚本还原：`start_tp4_head/worker.sh.bak-stageB-prod-20260816`（恢复 NCCL_PROTO=Simple）
- 重启即回滚（瞬时）

## 7. 遗留项攻关结论（2026-08-16 17:00）

| 遗留项 | 结论 | 证据 |
|---|---|---|
| ① 131K decode 低噪复测 | 🟢 **无真实回归**（稳态 131K DE ≈102 tok/s，高于基线估计） | 长窗口（ignore_eos 强制 2048 tokens）CV 收窄 28%、mean +8.15% vs 短窗基线；12 样本合并 96.65 全部 >90 |
| ② 并发 c>1 LL 收益放大 | 🟢 **成立**（agg decode c4 +96.4% / c8 +499.9%） | 87 次小 allreduce/步并发下跨请求重叠分摊，LL 批处理收益端到端首次验证；prefill 侧饱和（compute-bound） |
| ③ PerSizeTuner 双分支加固 | ✅ **已上生产**（2be94172 替换 3d9cf539） | if/else 双分支强制覆盖；SPCX 三场景复验：B 加固生效（性能与无 SPCX 相当）、C 旧库被带偏 LL128（368KB 227→619µs 劣化 2.7×）实证静默失效风险被消除 |
| ④ Tree 算法使能（P2-3） | ❌ **关闭**（不值得做） | 三层硬墙：无交换机 tree 图搜索失败 + v1 环邻过滤丢弃 tree peer + 4 环缺对角线物理不可行；大消息带宽饱和 tree 无增益。预算转投 **P1 2-hop kernel** |

**后续建议（更新）**：
- **P1 2-hop kernel（GDAKI/NVSHMEM）**：小/中消息延迟的正确投资（优于 tree 的 4 步，2 相位）
- **P2 交换机拓扑**：大消息带宽结构性提升（4×Spark 交换机实测 21.3GB/s vs 本环境 13.7GB/s）
- **双分支加固库上生产**：待四机复验通过后替换 3d9cf539
- **0.27 升级**：官方源码干净基线 + 补丁可直接移植（含加固）

---
*报告生成：2026-08-16 16:3x（Stage B 生产上线当日 + 全量测试判读完成）*
