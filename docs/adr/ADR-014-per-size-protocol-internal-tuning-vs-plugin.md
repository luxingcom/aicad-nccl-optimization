# ADR-014: per-size 协议控制——内部 tuning.cc 改码 vs 外部 tuner 插件（S1 阻断后决策）

**状态:** Accepted（S1 硬关卡阻断后裁决）
**日期:** 2026-08-16
**作者:** Archi（系统架构师）

---

## 背景

S1 容器验证（nccl-tuner-s1-report-sre-2026-08-16）实测证伪了 tuner 实施文档 §2.6 的"tuner 与 net.cc 解耦"假设：

- **任何外部 tuner 插件被加载即破坏 ring-only P2 lib 的 collective net 连接**（`ibv_modify_qp 110`，GID 配对错误：01-f1 误连 03-f1）；no-op 插件同样复现；Simple-only 矩阵仍失败。
- 耦合点位于 P2 补丁 `src/transport/net.cc::ncclIbPeerHcaOverride()`（sendSetup/recvSetup 逐 peer 覆盖 netDev）与外部 tuner 加载路径的交互。
- 基线（无插件、内部 tuner、`NCCL_PROTO=Simple`）唯一可用；外部插件机制在本定制库上不可用。

**约束不变**：目标仍是"小消息（≤40KB）走 LL、大消息（>40KB）走 Simple"的 per-size 协议混合，保住 prefill（368KB/1MB/16MB 不劣化）同时把 decode 87 次小 allreduce 从 55-80µs 压到 44.6-54.3µs。

---

## 选项分析

### 选项 A：改 `src/graph/tuning.cc` 内部默认 tuner，重编 ring-only lib（退化路径，设计 §2.6 已备）

- 不加载外部插件，走基线已验证可用的内部 tuner 路径。
- 修改点：内部默认 tuner 的 `getCollInfo`（v6 接口，位于 tuning.cc），按 `collType==AllReduce && nBytes` 做**双带 cost 覆盖**（≤40KB→LL / >40KB→Simple），其余 collective 与尺寸交回 NCCL 默认。
- 工作量：~15-20 行 + 重编 + 四机替换 + S1 复验 ≈ 0.5-1 人日。风险：低-中（生产库级变更，回滚=还原 .bak）。

### 选项 B：修 P2 net.cc 与 tuner 交互根因，保留外部插件

- 需定位"插件加载改变 NCCL net 连接建立流程/时序→`ncclIbPeerHcaOverride` peer 上下文错位"的精确机制（疑通道数/连接序/全局 tuner 指针变化），再打 NCCL 级补丁。
- 工作量：3-7 人日（NCCL 内部调试 + 每轮重建 + 4 机验证周期），**收敛性不确定**。风险：高。且即使修复，生产多了"插件 .so 四机分发/版本同步"一个移动部件。

### 选项 C：先 A 后 B（推荐组合）

- 以 A 立即解锁 S1/S2，拿到 per-size LL 收益；B 降级为可选的 NCCL 级专项（仅在 0.27 后确有动态调优需求时再评估）。

---

## 决策

**采用选项 A（内部 tuning.cc 双带协议覆盖），外部插件本轮不上线；选项 B 挂起为长期可选项。**

理由：
1. **复用唯一已验证可用路径**：内部 tuner → net.cc P2 override 的组合正是基线（cfg=a）路径，只改"内部 tuner 选什么协议"，不碰 net.cc、不加载插件，理论上完全绕开阻断耦合。
2. **工作量/风险最小**：~15-20 行 + 既有 build 路径；回滚即还原 `.bak` v3（b7784b49），比重编/打镜像安全。
3. **收益完全一致**：双带 cost 覆盖等价于插件逻辑（甚至更少一层间接），阈值 40KB 复用阈值扫描结论。
4. **可持续性更优（对 0.27）**：ring-only lib 本就随版本重编（P1/P2 同源维护），把 ~15 行 tuning.cc diff 并入既有 build 流程的增量成本几乎为零；外部插件则需每次验证"插件 vs 新 libnccl 接口 v6/v7 兼容 + 与本库 net.cc 耦合不复发"，反而更脆。
5. **排除环境变量回归**：退化路径同样要求移除 `NCCL_PROTO=Simple`（env 优先级高于内部 tuner），与插件路径一致；双带覆盖保证移除后大消息仍强制 Simple（见下文关键约束）。

---

## 影响（变容易/变困难）

- **变容易**：S1/S2 解锁；per-size 协议混合落到与 P1/P2 同源的 ring-only 构建体系内；回滚路径清晰。
- **变困难**：每改一次协议策略需重编 lib 四机替换（丧失"插件即改即生效"灵活性）——对本项目可接受（策略已定案 40KB，改动频率极低）。
- **需重新审视**：0.27 升级时 flashinfer 阻塞解除后，ring-only lib 重编需把本 diff 与新 NCCL 源码对齐；届时再评估是否值得回头修 B（若新版本接口更稳）。
- **产物**：插件源码（tuner_per_size.c）四机留档 `/opt/nccl-tuner-plugin/`，作为未来 B 选项的基线与 cost-table 访问范式（连续 `float[numAlgo][numProto]` 需 cast `float(*)[NCCL_NUM_PROTOCOLS]`）参考，**不部署**。

---

## 关键实现约束（写进实施单）

1. **双带覆盖，不是单带**：必须同时强制"≤40KB→LL"与">40KB→Simple"（仅 allreduce）。若只做小消息带而移除 `NCCL_PROTO=Simple`，内部 tuner 对 368KB/1MB 可能重选 LL128 → 复现 T1aM4 前的历史回归（923µs，64ch 时代；当前 MAX_CH16 下仍应避免）。
2. **只动 allreduce**：logits allgather/其余 collective 交回 NCCL 默认（避免误伤）。
3. **跳过 IGNORE 组合**：LL 对 Ring+allreduce 在本库已由阈值扫描证实可用；实现时仍以"非 IGNORE 才覆盖"为防御。
4. **阈值 40960 可配**：读 env `NCCL_TUNER_THRESHOLD`（默认 40960），保留调参口。
5. **不碰 nChannels**：MIN_CH4/MAX_CH16/BUFFSIZE=8M 保持生产现状。
6. **env 纪律**：生产/测试移除 `NCCL_PROTO=Simple`；`NCCL_ALGO=RING` 可保留（库本就只有 ring）。
7. **验证判据不变**：S1 复验（小消息 LL 28-34% 收益、368KB ~170µs 不劣化、正确性 ok）+ S2 CUDA graph 专项（fix72 教训），脚本已就绪可复用。

---

## 构建/部署/回滚要点（实施单，路径待现场核实）

- 源码：`backup/tp4-20260812/src`（ring-only P2 快照，含 net.cc 补丁与现网 v3 同源）
- 构建容器：NGC 26.07（CUDA 12.1a / sm_121 / gcc 13.3，aarch64）
- 构建：`make src.build CUDA_HOME=<cuda> NVCC_GENCODE=sm_121`，产物 libnccl.so → 安装为 `/opt/nccl-ringonly/libnccl.so.2`
- 部署：四机同 md5 替换；现网 v3（md5 b7784b49…）先存 `.bak` 再覆盖
- 回滚：还原 `.bak` + 重启 vllm-tp4 容器；比重编安全
- 复验：`bench_scan.py`（已就绪）跑 S1 判据 + `NCCL_DEBUG_SUBSYS=TUNING` 确认小消息选 LL / 大消息选 Simple
