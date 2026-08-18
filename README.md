# AICAD DGX Spark 四机 TP4 · NCCL 通信优化资料包

> **项目**：DGX Spark 四机环网 TP4 vLLM（DeepSeek V4 Flash 0731）NCCL allreduce 延迟优化
> **团队**：工程保障团队（Archi 架构 / Rex SRE / Tessa QA）
> **周期**：2026-08-15 ~ 2026-08-17
> **状态**：✅ 生产终态定版（Stage B hardened `2be94172` 已上线），2-hop 实验 D 收尾归档

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
├── docs/                     # 全部分析文档（35+19 份，见 docs/README.md 索引）
│   ├── adr/                  # ADR-014 / ADR-015（含 S1.1-S1.13 决策演进）
│   ├── reports/              # 最终报告 + 各阶段分析/验证/审计 + 2-hop 归档（35 份）
│   ├── benchmarks/           # 最终性能基线 v3 + v2 基准协议（10 份）
│   └── ops/                  # 部署/自恢复/治理/审计（19 份）
├── patches/                  # 6 个 NCCL 定制补丁 + 2-hop 归档补丁 + 应用脚本（README 含重建指引）
├── config/                   # 环境参数基线（NCCL env / daemon.json / systemd / healthcheck）
├── src/                      # tuner 插件源码 + 2-hop 实验脚本（轻量参考，不含二进制）
└── tools/                    # 运维/测试脚本（bench_v2 / healthcheck / clean_tmp / mirror）
```

**快速入口**
| 想了解 | 读 |
|---|---|
| 整体结论 | `docs/reports/00-FINAL-REPORT-nccl-optimization-2026-08-16.md` |
| 性能基线数据 | `docs/benchmarks/00-FINAL-BASELINE-v3-2026-08-17.md` |
| 为什么这么做 | `docs/adr/ADR-014-*.md` + `docs/adr/ADR-015-*.md` |
| 补丁与重建 | `patches/README.md` |
| 当前生产参数 | `config/production-nccl-env.md` |
| 自恢复方案 | `docs/ops/production-self-healing-plan-architect-2026-08-17.md` |

---

## 3. 技术路线（一句话）

**在 4×DGX Spark 环网（无交换机）上，用官方 NCCL 2.30.7 源码干净重建 ring-only 定制库：**
1. **v1 环邻过滤**：`ncclTransportP2pConnect` 只连接环邻 peer（消除非环邻连接开销）；
2. **v4 硬编码 per-peer netDev 映射**：静态 `(rank, peerRank)→(devA, devB)` 表替代 `NCCL_IB_PEER_HCA` env 解析（消除源码漂移脆弱点，ADR-015）；
3. **Stage B per-size tuner**：≤40KB→LL / >40KB→Simple（仅 allreduce），decode 小消息延迟降 19-27%，prefill 大消息不劣化；
4. **双分支加固**：override 在 tuner 存在/不存在两分支均生效，防外部 tuner（SPCX）劫持静默失效；
5. **P1 自愈治理**：systemd 自愈 + healthcheck 主动重建 + 日志/密钥/镜像治理，整机重启 ≈7min 达标。

**2-hop 实验结论**：bilateral 双 Primitives 在当前 NCCL ring 原语框架内被干净否定（SIMPLE 下 illegal memory access；LL/LL128 价值区不可触及），项目 D 收尾归档，预算转投 P2 交换机 / 0.27 升级。

---

## 4. 复现指引

### 4.1 环境
- 硬件：4×DGX Spark（GB10，UMA 121.6GiB），环网 01-02-04-03，4 边双 200G RoCE 直连（无交换机），每机 ConnectX-7 双口
- 软件：vLLM 0.26 TP4（DeepSeek V4 Flash 0731），CUDA 13.0.2，NCCL 2.30.7 ring-only
- 构建容器：`anemll/dspark-vllm-gx10:0.2.1-v026.0`（glibc 2.35，CUDA 13.0）

### 4.2 重建生产库（md5 2be94172）
```bash
git clone https://github.com/NVIDIA/nccl -b v2.30.7-1 nccl-2307
cd nccl-2307
git apply patches/v1-ring-only.patch
git apply patches/v4-netdev-hardcode.patch
git apply patches/stageB-tuner-two-band.patch
git apply patches/stageB-hardened-two-branch.patch
make -j src.build CUDA_HOME=/usr/local/cuda \
  NVCC_GENCODE=-gencode=arch=compute_121,code=sm_121
# 部署：四机同 md5 安装为 /opt/nccl-ringonly/libnccl.so.2
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
| NCCL | ring-only 2.30.7 hardened **2be94172**；ALGO=RING；MIN_CH4/**MAX_CH4（B1：16→4，2026-08-17）**/BUFFSIZE 8M |
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

*资料包整理：Archi（系统架构师）· 2026-08-17 · 提交至 GitHub（任务二）*
