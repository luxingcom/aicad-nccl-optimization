# NCCL per-size 协议优化 · 复验与路径选型报告（更正版）

**日期**：2026-08-16（v2，更正早前 S1 BLOCKED 结论）
**执行**：Rex（SRE 工程师）
**性质**：容器 S1 复验（四机 sglang 26.07 + ring-only v3 lib）+ 退化路径 A 实施核查
**结论**：
1. **早前"外部插件破坏 ring-only net 连接"的 S1 BLOCKED 结论作废**——根因是测试容器被误配成 stock lib（start 脚本误删 LD_PRELOAD），非插件问题。
2. **外部插件（路径 B）在现网 v3 lib 上实测可用**：小消息 1-16KB p50 较基线降 **-21~-28%**（1KB 中位数 -28%，接近/达到 28-34% 目标）；正确性全对；368KB 轻微 +5~7%（需关注）；回滚=删 .so+还原 env，零重编。
3. **退化路径 A（改 enqueue.cc 双带补丁 + 重编）产出的 lib 在本机复验失败**（GID 错配），原因是 **backup 源码快照的 net.cc 与现网 v3 实际构建源码不一致**（strings 对比可证），非补丁本身问题。要重建 v3 需先取到真实 v3 源码。

---

## 0. 更正声明（重要）
早前 `nccl-tuner-s1-report-sre-2026-08-16.md` 判定"S1 BLOCKED：插件加载破坏 net 连接"**系测试环境误配导致**：
- `nccltune-a-rank0`（基线）含 `LD_PRELOAD=/opt/nccl-ringonly/libnccl.so.2`（ring-only v3），正常工作。
- `nccltune-b/n/s`（插件/noop/stock 测试）**缺失 LD_PRELOAD**，实际使用 sglang 容器自带 stock libnccl（无 P2 补丁），stock lib 在本环网拓扑无法正确选路 → GID 错配。
- 更正后（cfg=b 容器补齐 LD_PRELOAD=ring-only + NCCL_TUNER_PLUGIN）插件**工作正常**。

---

## 1. 路径 B（外部 tuner 插件）—— 现网 v3 lib 上可用 ✅

### 1.1 环境
- lib：现网 v3 `/opt/nccl-ringonly/libnccl.so.2.30.7`（md5 `b7784b49885659c27765e648884e4edd`），LD_PRELOAD 注入。
- 插件：`/opt/nccl-tuner-plugin/libnccl_tuner_persize.so`（md5 `0edd825c99d7180e2f7d00a9993c40e4`），v6 getCollInfo，≤40KB→LL、>40KB→Simple，不碰 nChannels，跳过 IGNORE。
- env：删 `NCCL_PROTO`，保留 `NCCL_ALGO=RING` + MIN/MAX_CH + IB env（逐机 NCCL_IB_PEER_HCA）。
- 加载日志：`Successfully loaded external tuner plugin` / `Using PerSizeLLSimple (v6)`（四机一致）。

### 1.2 多次运行 p50 中位数对比（µs）
| 消息 | 基线 Simple 中位数 | 插件 中位数 | 变化 |
|---|---|---|---|
| 1KB | ~54.5 | **~39.0** | **-28%** |
| 2KB | ~55 | **~40** | **-27%** |
| 4KB | ~55.5 | **~41** | **-26%** |
| 8KB | ~57 | **~44** | **-23%** |
| 16KB | ~61.5 | **~48** | **-22%** |
| 32KB | ~67 | **~53** | **-21%** |
| 40KB | ~69.5 | **~55** | **-21%**（≤40KB 仍 LL ✓）|
| 44KB | ~69 | ~69 | ~0%（>40KB 切 Simple ✓）|
| 368KB | ~170 | ~182 | **+5~7% ⚠️** |
| 1MB | ~166 | ~172 | +3.6% |
| 4MB | ~314 | ~315 | +0.3% |

- 正确性：全尺寸 `ok=True`（rank 各异值 allreduce 逐元素=sum）。
- 观测：1KB 命中 28-34% 目标下沿；2-16KB 略低于目标（-21~-27%）。运行间方差显著（1KB 插件 34.8-42.6µs、基线 53.7-55.8µs），采用多次中位数。
- **368KB 轻微回归（+5~7%）**：插件态（无 NCCL_PROTO，全 proto 开）的 Simple 配置与基线态（NCCL_PROTO=Simple，Simple-only）有细微差异（疑与 LL/LL128 连接建立或 nChannels 默认不同有关），需生产 A/B 验证接受度；若不可接受，可在插件态另验证 368KB 专项。

### 1.3 部署方式（路径 B，若采纳）
- 四机挂载 .so（`/opt/nccl-tuner-plugin/libnccl_tuner_persize.so`）。
- 生产 env diff：**删 `NCCL_PROTO=Simple`**，加 `NCCL_TUNER_PLUGIN=/opt/nccl-tuner-plugin/libnccl_tuner_persize.so`；保留 `NCCL_ALGO=RING`。
- 回滚：删 env + 还原 NCCL_PROTO=Simple，重启容器。零重编、零 lib 替换。

---

## 3. 路径 A（内部双带补丁 + 重编）—— backup 源码构建产物复验失败 ❌
- 已确认 `src/enqueue.cc` 存在 R14 双带补丁（+24 行，仅内部 tuner 分支，≤40960→LL/>40960→Simple，期望0.0/其余1e18/跳IGNORE/不碰nChannels；env NCCL_TUNER_THRESHOLD 可覆盖）。
- R14b 容器构建成功：`/opt/aicad-prod/backup/tp4-20260812/src/build/lib/libnccl.so.2.30.7`，md5 `fe5b6c88d05495921ca0f93087ab19dd`，含 "NCCL_TUNER_THRESHOLD"/"PerSizeTuner" 字符串（补丁已编译入）。
- 用该 lib（LD_PRELOAD 指向、无 NCCL_PROTO、无插件）四机复验：**首个 allreduce 即 GID 错配失败**（`ibv_modify_qp failed ... local 136.1(01-f1) remote 138.2(03-f1)`）。
- **对照实验证明不是补丁问题，是 backup 源码与 v3 不一致**：
  - cfg=r（原 v3 lib，无 NCCL_PROTO、无插件）✅ 工作。
  - cfg=p（backup 构建 lib，无 NCCL_PROTO、无插件）❌ GID 错配。
  - strings 对比：backup 构建 lib 含 `RING-ONLY: peer %d -> net dev %d (%s), was %d`（net.cc 的 INFO 日志），现网 v3 lib **不含**该串 → 两者 net.cc 源码版本不同。
- **结论**：backup `tp4-20260812` 快照并非现网 v3 的真实构建源码（net.cc P2 补丁版本有差异）。路径 A 若坚持，必须先取得 v3 真实源码（或逐项 diff net.cc），再重建复验。补丁逻辑本身（cost 双带覆盖）与路径 B 插件逻辑一致，理论可行。

---

## 4. 方差与测量说明
- 单次 bench（warmup20+iter100）方差大（1KB 插件 34.8~42.6、368KB 基线 130~177）。构建期间负载污染尤其严重。
- 建议后续判据采用 **≥3 次运行 p50 中位数**，避免单次误判。
- 早前"368KB 插件 +8.6% 劣化"实为噪声（同区间基线自身波动）。

---

## 5. 结论与建议
1. **推荐路径 B（外部插件）**：在现网 v3 lib 上工作、零重编、回滚瞬时，实测小消息收益达标的接近档。部署+生产 A/B 成本最低。
2. 368KB +5~7% 需生产窗口 A/B 判定接受度；若超限，可考虑插件态对 368KB 单档专项优化（不在此轮）。
3. 路径 A 若走，前提是先还原 v3 真实构建源码（backup 快照不可靠），再重编复验；补丁逻辑可复用。
4. S2（CUDA graph 专项）需在路径定案后重新立项。

## 6. 产物留档
- 插件：`/opt/nccl-tuner-plugin/tuner_per_size.c` + `libnccl_tuner_persize.so`（md5 `0edd825c99d7180e2f7d00a9993c40e4`）
- 路径A lib：`/opt/nccl-tuner-plugin/lib/libnccl.so.2.30.7`（md5 `fe5b6c88d05495921ca0f93087ab19dd`，复验失败留档）
- 对比数据：`logs/v-base*.log`（基线）、`logs/v-plugin*.log`（插件 4 次）、`logs/v-pathA.log`（路径A失败）
- 补丁：`src/enqueue.cc.bak-20260816`（备份） + enqueue.cc（R14 补丁），源码位于 `/opt/aicad-prod/backup/tp4-20260812/src/`
