# AICAD DGX Spark 四机 TP4 · NCCL 通信优化资料包

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-%E4%BB%85%E5%AD%A6%E4%B9%A0%E4%BA%A4%E6%B5%81-orange)

> ⚠️ **免责声明 / Disclaimer**：本项目仅用于**学习、研究与交流**，不构成生产级软件，
> 作者不对任何直接或间接损失承担责任。生产环境使用前须自行完成完整验收。
> **For learning, research, and technical exchange only — not for production use.**
> See [LICENSE](LICENSE) (Apache-2.0) and [NOTICE](NOTICE).

> **项目**：DGX Spark 四机环网 TP4 vLLM（DeepSeek V4 Flash 0731）NCCL allreduce 延迟优化
> **团队**：工程保障团队（Archi 架构 / Rex SRE / Tessa QA）
> **周期**：2026-08-15 ~ 2026-08-17（资料包定版）；**v1.1 组件化（2026-09-19）**；**v1.2 服务器资料并档（2026-09-19）**
> **状态**：✅ 生产终态定版（Stage B hardened `2be94172` → **V5-ar2 模块 2026-09-04 晋升生产**，在役 libnccl `51e36db5` + libar2 `343bea89`）；2-hop 实验 S1→S3 完整闭环后机制级否定归档（非未完成）
> **v1.1 变更**：依据客户部署实录将「资料包」升级为「可部署组件」——新增 v5 可配置补丁（ADR-016，换拓扑免重编库）、部署指南、排障手册、预检/探针/doctor 工具链、deploy 模板；修复 v4 补丁 hunk 行数缺陷与全部补丁 CRLF 问题
> **v1.2 变更**：服务器取证并档（dgxspark01）——①收录 **V5-ar2 模块**全套（ar2 引擎源码 + hook 补丁 + 文档十九件 + A/B 结果 + md5 血统；2026-09-04 已晋升生产）；②2-hop 执行层增量补齐（10 份报告 + git-bundle 复现包 + lib md5 血统 + S3 门数据 + 失败日志）；③新增 `docs/VERSION-LANDSCAPE.md` 版本链总览与三个 "V5" 语义消歧；④StageB 加固档案（MD5-RECORD + SPCX 劫持验证计划 + stub tuner 源码）

---

## 0. 我要部署（新用户从这里开始）

```
第 1 步  读 docs/deployment/DEPLOYMENT-GUIDE.md（步骤化，每步带验证命令）
第 2 步  跑 tools/precheck.sh      —— 四机一致性预检（fail-closed）
第 3 步  接线 + tools/probe_ring_topology.sh 实测拓扑（物理层优先！）
第 4 步  python3 tools/gen_devmap.py --topology topology.json   → 生成设备映射
第 5 步  按 patches/README.md §2 重建库（v5 补丁栈），deploy/ 模板落组件
第 6 步  起栈 → tools/doctor.sh → deploy/ACCEPTANCE-CHECKLIST.md 逐项验收
出问题时  docs/ops/troubleshooting-playbook.md（症状 → 根因 → 修复 → 验证）
```

---

## 1. 成果摘要（vs A0 原始基线）

| 指标 | 原始 (A0) | 优化后 | 提升 |
|---|---|---|---|
| **368KB allreduce** | 923µs | **173µs** | **-81%** |
| **32K PR** | 2110 | **~2420** | **+15%** |
| **131K PR** | 1809 | **~2200** | **+22%** |
| 131K TTFT | 63s | **~52s** | **-17%** |
| 32K DE | 96 | ~99 | +3% |
| **自恢复** | 手动重启 | **head 重启 ≈7min、三场演练 5min11s** | ✅ 达标（≤20min 优） |

关键里程碑：`T1aM4（-56%）→ +MAX_CH16（-81%）→ Stage B per-size tuner（32K PR +15%）→ 双分支加固 2be94172（防 SPCX 劫持）→ B1 通道数 16→4（2026-08-17 固化，112KB -34% / 224KB -46%）→ P1 自愈治理（四机重启 7min11s）`。

---

## 2. 目录导航

```
github-repo/
├── README.md                 # 本文件（项目总览/成果/复现指引）
├── docs/                     # 全部分析文档（见 docs/README.md 索引）
│   ├── VERSION-LANDSCAPE.md  # ★ 版本链总览与「V5」消歧（必读入口）
│   ├── adr/                  # ADR-014 / ADR-015 / ADR-016（含 S1.1-S1.13 决策演进）
│   ├── deployment/           # ★ 部署指南（DEPLOYMENT-GUIDE.md，步骤化+验证命令）
│   ├── v5-ar2/               # ★ V5-ar2 模块文档（DELIVERY + 十九件，已晋升生产）
│   ├── 2hop-archive-extras/  # ★ 2-hop 执行层增量报告（10 份 + README）
│   ├── stageB-hardening/     # ★ StageB 加固档案（MD5-RECORD + SPCX 验证计划）
│   ├── reports/              # 最终报告 + 各阶段分析/验证/审计 + 2-hop 归档
│   ├── benchmarks/           # 最终性能基线 v3 + v2 基准协议（10 份）
│   └── ops/                  # 部署/自恢复/治理/审计 ＋★ troubleshooting-playbook.md
├── patches/                  # NCCL 定制补丁（v5 可配置版 + V5-ar2 hook）+ 2-hop 归档补丁与脚本
├── config/                   # 环境参数基线（NCCL env / daemon.json / systemd / healthcheck）
├── deploy/                   # ★ 部署组件模板（netplan / systemd / env / 验收清单）
├── src/                      # tuner 插件源码 + ★ ar2 引擎源码（V5-ar2）+ spcx stub tuner
├── archive/2hop-proto/       # ★ 2-hop 复现包（git-bundle + SHA 映射 + lib md5 血统 + 门数据 + 失败日志）
├── results/v5-ab-window/     # ★ V5-ar2 同窗 A/B 结果（PR 20 档 + DE 12 档）
└── tools/                    # 部署工具链（precheck / probe / doctor / gen_devmap）+ ar2 工具
```

**快速入口**
| 想了解 | 读 |
|---|---|
| **我要部署** | `docs/deployment/DEPLOYMENT-GUIDE.md` ★ |
| **出问题怎么查** | `docs/ops/troubleshooting-playbook.md` ★ |
| **版本链 / 三个 V5 是什么** | `docs/VERSION-LANDSCAPE.md` ★ |
| **V5-ar2 模块（生产在役）** | `docs/v5-ar2/DELIVERY.md` |
| **2-hop 完整闭环** | `docs/reports/2hop-s3-final-adjudication-2026-08-17.md` + `docs/2hop-archive-extras/` + `archive/2hop-proto/` |
| 整体结论 | `docs/reports/00-FINAL-REPORT-nccl-optimization-2026-08-16.md` |
| 性能基线数据 | `docs/benchmarks/00-FINAL-BASELINE-v3-2026-08-17.md` |
| 为什么这么做 | `docs/adr/ADR-014-*.md` + `ADR-015-*.md` + `ADR-016-*.md` |
| 补丁与重建 | `patches/README.md` |
| 当前生产参数 | `config/production-nccl-env.md` |
| 部署组件模板 | `deploy/`（netplan / systemd / env / 验收清单） |
| 自恢复方案 | `docs/ops/production-self-healing-plan-architect-2026-08-17.md` |

---

## 3. 技术路线（一句话）

**在 4×DGX Spark 环网（无交换机）上，用官方 NCCL 2.30.7 源码干净重建 ring-only 定制库：**
1. **v1 环邻过滤**：`ncclTransportP2pConnect` 只连接环邻 peer（消除非环邻连接开销）；
2. **v4 硬编码 per-peer netDev 映射**：静态 `(rank, peerRank)→(devA, devB)` 表替代 `NCCL_IB_PEER_HCA` env 解析（消除源码漂移脆弱点，ADR-015）；
3. **Stage B per-size tuner**：≤40KB→LL / >40KB→Simple（仅 allreduce），decode 小消息延迟降 19-27%，prefill 大消息不劣化；
4. **双分支加固**：override 在 tuner 存在/不存在两分支均生效，防外部 tuner（SPCX）劫持静默失效；
5. **P1 自愈治理**：systemd 自愈 + healthcheck 主动重建 + 日志/密钥/镜像治理，整机重启 ≈7min 达标。

**2-hop 实验结论**：项目 S1→S2→S3 **完整开发并闭环**（非未完成）——P0 根因闭环（device kernel table 未注册 2HOP + nAlgos 溢出，lib `d3fc78a4` 修复后 ok=True）、随后机制级否定（SIMPLE 双 Primitives 在 form C 与 carry 两套设计下同样 illegal memory access；LL/LL128 价值区编译期隔离不可触及），D 收尾归档。完整执行层证据：`docs/2hop-archive-extras/` + `archive/2hop-proto/`（git-bundle 可复现）。

---

## 4. 复现指引

### 4.1 环境
- 硬件：4×DGX Spark（GB10，UMA 121.6GiB），环网 01-02-04-03，4 边双 200G RoCE 直连（无交换机），每机 ConnectX-7 双口
- 软件：vLLM 0.26 TP4（DeepSeek V4 Flash 0731），CUDA 13.0.2，NCCL 2.30.7 ring-only
- 构建容器：`anemll/dspark-vllm-gx10:0.2.1-v026.0`（glibc 2.35，CUDA 13.0）

### 4.2 重建生产库（v5 补丁栈；生产 v4 库 md5 2be94172 的重建见 patches/README.md §5）
```bash
git clone https://github.com/NVIDIA/nccl -b v2.30.7-1 nccl-2307
cd nccl-2307
git apply ../patches/v1-ring-only.patch
git apply ../patches/v5-netdev-configurable.patch   # ADR-016：内建默认表=v4，支持 NCCL_RING_DEV_MAP* 覆盖
git apply ../patches/stageB-tuner-two-band.patch
git apply ../patches/stageB-hardened-two-branch.patch
make -j src.build CUDA_HOME=/usr/local/cuda \
  NVCC_GENCODE=-gencode=arch=compute_121,code=sm_121
# 部署：四机同 md5 安装为 /opt/nccl-ringonly/libnccl.so.2；md5 同步登记 config/production-nccl-env.md §3
```

### 4.2b V5-ar2 模块重建（hook 集成形态，已在生产）
```bash
# 基座：上一步 hardened 库（或服务器 git 0dd44cd 树 ~/sparkring-kit/nccl-ringonly-v5/）
git apply ../patches/nccl-ringonly-v5-hook.patch
# 另需 ar2 引擎：源码 src/ar2-engine/（CMake 构建 → libar2.so.1）
# 构建与验收流程：docs/v5-ar2/BUILD-TEST.md；回滚：env AR2_V5=0 一键全原生
```

### 4.3 跑基准（32 档）
```bash
export VLLM_API_KEY=<your-key>          # 从 secrets/vllm.env 获取（资料包不含明文）
bash tools/run_benchv2_full.sh          # 生产空闲窗口，约 2h
# 判读协议见 docs/benchmarks/nccl-benchmark-v2-plan-qa-2026-08-16.md
```

### 4.4 验证自恢复
```bash
bash tools/healthcheck.sh --role head   # 只读探针
# 主动重建（破坏性）：bash tools/healthcheck-rebuild.sh --role head --cooldown 1800
```

---

## 5. 生产配置快照（2026-08-18 对标调优终态）

| 项 | 值 |
|---|---|
| 引擎 | vLLM TP4 · max-num-seqs **12** · util **0.80** · Prefix KV · **600k** · capture **96** · bt **4096** |
| 投机 | dspark **k=7** 静态（无 ladder）；接受率 0.94/0.86/0.77/0.69/0.61/0.49/0.35 平滑衰减 |
| ulimit | nofile **1048576**（8/18 由默认 1024 上调） |
| NCCL | ring-only 2.30.7 hardened `2be94172`（08-16 锚点）→ **V5-ar2 hook 晋升后容器内在役 libnccl `51e36db5` + libar2 `343bea89`（09-04 起，详见 docs/v5-ar2/DELIVERY.md）**；ALGO=RING；MIN_CH4/**MAX_CH4（B1：16→4，2026-08-17）**/BUFFSIZE 8M |
| tuner | `NCCL_TUNER_THRESHOLD=40960`（≤40KB→LL />40KB→Simple）+ `NCCL_NET_PLUGIN=none` |
| IB | HCA 4 口；GID=3；MERGE_NICS=0；TOS=46；硬编码 per-peer 映射 |
| systemd | Restart=always；StartLimit 1800s/20；healthcheck timer 60s |
| 编排 | `start_tp4_cluster.sh`（head-first 幂等）；worker 先启→head 后启 |

> 8/18 变更：k5+ladder→k7 无 ladder、gmu 0.65→0.80、seqs 6→12、capture 64→96、max-model-len 400k→600k、ulimit 1048576；bt 8264 曾致 c6 prefill 退化已回退 4096。完整参数见 `config/production-nccl-env.md`；权限：`config/` 为服务器快照，权威源在服务器 `/opt/aicad-prod/`。

---

## 6. 安全与脱敏声明

- ✅ **本资料包不含**：生产库二进制（libnccl.so）、模型权重、`secrets/vllm.env`、任何完整密码/API key。
- 文档中凭据一律脱敏：sudo 密码 `AS12<REDACTED>`、API key `c3b4<REDACTED>4594`。
- 补丁均为文本 diff 可直接审阅；编译产物不随包分发，重建指引见 `patches/README.md` §5。
- 服务器归档含 git bundle 与完整源码树（`/opt/aicad-prod/backup/nccl-*`），体积大不随 GitHub 分发。

---

## 7. 相关文档集

- 权威运维文档（服务器）：`/opt/aicad-prod/docs/`（01/02 双机镜像）
- 本地交付：`deliverables/engineering-assurance/`（全部 8/16-8/17 报告）
- 2-hop 归档：服务器 `/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/`

---

## 8. 许可与第三方组件

- 本仓库（补丁、脚本、文档）以 **Apache License 2.0** 发布，见 [LICENSE](LICENSE)。
- 第三方组件与商标归属见 [NOTICE](NOTICE)：NCCL（BSD-3-Clause，Copyright NVIDIA）、
  vLLM（Apache-2.0）。patches/ 仅分发补丁文本；应用补丁后的 NCCL 衍生构建受
  NCCL 原许可约束，本项目不随包分发 NCCL 源码或二进制。
- 贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 9. 免责声明（仅学习交流用途）

> **本项目按"现状"提供，仅用于学习、研究与交流目的，不得用于生产环境。**

1. 本项目修改的是 NCCL 集合通信库的深层行为。构建或部署不当可能导致**数据静默损坏、
   分布式任务崩溃或性能劣化**。使用本项目产生的任何后果由使用者自行承担。
2. 作者与贡献者**不对**本项目作任何明示或默示的担保，包括但不限于适销性、
   特定用途适用性与不侵权（详见 LICENSE 第 7 条）。
3. 在任何场景下，作者与贡献者均不对因使用或无法使用本项目而产生的任何
   直接、间接、附带、特殊、惩戒性或后果性损害承担责任（详见 LICENSE 第 8 条）。
4. 项目中出现的性能数字均为特定硬件/软件/拓扑组合下的实测记录，
   **不构成对任何其他环境的性能承诺**。
5. 若将本项目或其衍生物用于公开发布，请自行核实第三方组件（NCCL/vLLM）
   许可的合规性，并保留 NOTICE 文件中的归属声明。
6. DGX Spark、NCCL、ConnectX、CUDA 等为 NVIDIA 的商标；本项目与 NVIDIA
   无隶属或背书关系。

---

*资料包整理：Archi（系统架构师）· 2026-08-17 · 提交至 GitHub（任务二）· Apache 规范化 2026-09-20*
