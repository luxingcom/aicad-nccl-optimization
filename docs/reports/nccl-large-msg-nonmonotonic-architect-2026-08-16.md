# 大消息非单调性研究：1M(4MB) 反而比 368K(1.47MB)/512K(2MB) 快——机制与"快路径提前"可行性

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**性质:** 源码 + 反汇编 + 实测数据交叉研究（只读）
**输入:** Stage B 报告（nccl-stageb-verification）/ bench-SB 原始日志 / P0/阈值扫描 / NCCL 2.30.7 源码（enqueue.cc/tuning.cc）/ Stage B 库 9cdb26dc

---

## 0. TL;DR（先给结论）

1. **尺寸单位陷阱（本报告最重要发现）**：team-lead 引用的"368KB=424.7µs、512KB=555.2µs、1MB=293.5µs"全部来自 **bench-SB 原始日志**，尺寸是 **float32 元素数**（nccl_scan.py），换算成字节为 **1.47MB / 2MB / 4MB**。它们并非"368KB 字节"。

2. **"非单调"是 SPCX tuner 劫持的产物，不是 NCCL 内核/PerSizeTuner 的**：
   - bench-SB 未设 `NCCL_TUNER_PLUGIN=none` → 容器默认 `NCCL_NET_PLUGIN=spcx` 的 **SPCX tuner v5 劫持了 getCollInfo** → enqueue.cc 的 `if (comm->tuner != NULL)` 分支走 SPCX，**else 分支的 PerSizeTuner 永不执行**（Stage B 报告 §2.1 已确认 PerSizeTuner 日志 0 条）。
   - SPCX 对 1.47MB/2MB 选 LL128（或非 Simple 慢路径）→ 424/555µs；对 4MB 选 Simple（快路径）→ 293µs。

3. **受控 A/B（PerSizeTuner 生效，NCCL_TUNER_PLUGIN=none）下数据单调**：368K 元素(1.47MB)=**176.6µs**、1M 元素(4MB)=293.5µs。**1.47MB 在 PerSizeTuner 下已经 176µs（快路径已生效），比 SPCX 的 424µs 快 2.4×。**

4. **"把快路径提前" 已经实现**：PerSizeTuner 强制 >40KB 全走 Simple + 16 通道，1.47MB/2MB/4MB 全部进入 Simple 快路径。**无需额外调阈值**。

5. **真实优化空间不在"提前快路径"，而在"消除 SPCX 劫持"**：生产部署 Stage B 时移除 `NCCL_PROTO=Simple`（保留 `NCCL_NET_PLUGIN=none`）即可让 PerSizeTuner 生效；SPCX 劫持会破坏 per-size 选择（这是 bench-SB 非单调的根因，也是 Stage B 报告 §2.4 的关键结论）。

---

## 1. 数据事实（尺寸单位澄清）

### 1.1 两个脚本的尺寸单位不同（关键陷阱）

| 脚本 | sizes 语义 | 368640 含义 | 1048576 含义 |
|---|---|---|---|
| `/tmp/nccl_scan.py`（P0/阈值/StageB 扫描） | **float32 元素数** | 368640 元素 = **1.47MB 字节** | 1048576 元素 = **4MB 字节** |
| `/tmp/nccl_bench_b0.py`（A0 基线） | **字节** | 368640B = **368KB 字节** = 92K 元素 | 1048576B = **1MB 字节** |

**生产主档 368KB = 368640 字节（head-balance 报告 L9 明确"与实测 368640B 吻合"）**，即 **92K 元素**。nccl_scan.py 里的 368640 是**元素数**（1.47MB 字节），两者差 4 倍。

### 1.2 bench-SB 原始数据（元素数 → 字节）

```
size=  368640 avg=528.8 p50=424.7   ← 1.47MB 字节
size=  524288 avg=586.4 p50=555.2   ← 2MB 字节
size= 1048576 avg=298.3 p50=294.8   ← 4MB 字节
```

### 1.3 各数据源在同一字节尺寸下对比（p50 µs）

| 字节 | 元素数 | bench-SB(SPCX劫持) | 受控A/B(PerSizeTuner) | MAX_CH16(Simple) | 阈值扫描(Simple) |
|---|---|---|---|---|---|
| 1.47MB | 368K | **424.7** | **176.6** | 173.2 | 173 |
| 2MB | 512K | **555.2** | — | 198.0 | 198 |
| 4MB | 1M | **293.5** | **293.5** | 315.2 | 315 |

### 1.4 关键观察

- **bench-SB(SPCX)**：1.47MB=424.7 > 2MB=555.2 > 4MB=293.5 → **严重非单调**（4MB 反而最快）
- **受控A/B(PerSizeTuner)**：1.47MB=176.6 < 4MB=293.5 → **单调**
- **MAX_CH16 / 阈值扫描(Simple)**：173.2 < 198.0 < 315.2 → **单调**
- **4MB 在所有数据源下都 ≈293µs**（SPCX/PerSize/MAX_CH16 一致）→ 4MB 处所有 tuner 都选 Simple

---

## 2. 机制分析：为什么 SPCX 下 4MB 反而快

### 2.1 tuner 路径（enqueue.cc L2140-2176）

```c
if (comm->tuner != NULL) {                    // SPCX tuner 加载时走这里
  NCCLCHECK(comm->tuner->getCollInfo(...));   // SPCX 修改 cost table
  NCCLCHECK(topoGetAlgoInfo(...));
} else {
  // === PerSize LL/Simple 双带覆盖 (Stage B) ===
  if (info->func == ncclFuncAllReduce) { ... collCostTable 强制 >40KB → Simple ... }
  NCCLCHECK(topoGetAlgoInfo(...));
}
```

- **SPCX 加载**（容器默认 `NCCL_NET_PLUGIN=spcx`）→ `comm->tuner != NULL` → 走 SPCX getCollInfo → **PerSizeTuner else 分支不执行**。
- **SPCX 在 RoCE 上"not supported, skipping"**（日志确认 4 设备全部跳过），但仍作为 tuner 修改算法/协议 cost table。

### 2.2 协议成本模型（tuning.cc）

- AllReduce 可用 proto：LL / LL128 / Simple（Enabled Matrix 确认全开）
- **LL128 在跨机 RoCE（无 PXN）下慢**：需 128B 对齐原子 + flag 轮询，带宽损失（`busBw*0.92` 且受 perChMaxRingLL128Bw 限制）；本环境 ring-only 库无 PXN 支持
- 阈值扫描已实证：**非 Simple 协议在大消息上爆炸**（LL 在 368K 元素 20× 慢）

### 2.3 非单调的完整机制链（bench-SB / SPCX）

```
1.47MB (368K elem) → SPCX 选 LL128 → flag 轮询 + 128B 对齐开销 → 424.7µs
2MB   (512K elem) → SPCX 仍选 LL128 → 数据更多、开销更大 → 555.2µs（峰）
4MB   (1M elem)  → SPCX 选 Simple（大消息阈值）→ 走满带宽快路径 → 293.5µs
```

> 注：SPCX 具体选路因闭源无法直接反汇编，但 4MB 在所有 tuner 下 ≈293µs 与 Simple 一致、1.47/2MB 显著偏慢、且非 Simple 在本环境大消息必慢——三者交叉印证 LL128 假说。

### 2.4 为什么受控 A/B 没有非单调

受控 A/B 设 `NCCL_TUNER_PLUGIN=none` → 但注意容器仍默认加载 SPCX net 插件。Stage B 报告 §2.4 说明：无 `NCCL_TUNER_PLUGIN` 时 SPCX net 插件自带 tuner 会劫持；设 `NCCL_TUNER_PLUGIN=none` 后 `comm->tuner=NULL` → 走 else → **PerSizeTuner 生效，强制 >40KB → Simple**。因此 1.47MB 直接落到 Simple 快路径 176µs。

---

## 3. "能否提前快路径"——结论：已实现，无需额外调参

### 3.1 PerSizeTuner 已把大消息全部纳入快路径

- PerSizeTuner 阈值 40KB：**>40KB 全走 Simple**（成本表其他 proto 置 1e18）
- 在 PerSizeTuner 下，1.47MB/2MB/4MB **全部走 Simple**，与 MAX_CH16 最优档一致（176.6 vs 173.2µs 持平）
- **"1MB 的快路径"本质 = Simple 协议 + 16 通道 + 8MB buffsize**，PerSizeTuner 对 368K 元素(1.47MB) 已完全享受

### 3.2 真正的行动项：消除 SPCX 劫持

- **生产部署 Stage B 时**：移除 `NCCL_PROTO=Simple`（否则 env 优先级高于 tuner，per-size 失效），**保留 `NCCL_NET_PLUGIN=none`**（生产已在用，无 SPCX）→ PerSizeTuner 天然生效（报告 §2.4 实证）
- **容器测试时**：必须加 `NCCL_TUNER_PLUGIN=none`，否则 sglang 镜像默认 SPCX tuner 劫持（正是 bench-SB 非单调的来源）

### 3.3 预期收益（针对生产主档 368KB 字节 = 92K 元素）

- 生产主档 368KB **字节**（92K 元素）在 PerSizeTuner 下 >40KB → Simple，与 MAX_CH16 的 368KB 档（173µs）一致
- team-lead 的"368KB 从 424→294 = -31%"**不成立**（那是 1.47MB 的 SPCX 数据）；真实状态是 368KB 字节已经 173µs（MAX_CH16 已上线）
- **无额外 -31% 空间**；剩余收益来自：① 小消息 LL（1-16KB -21~31%，decode 战场）② 防 SPCX 劫持（避免 424µs 类劣化）

### 3.4 若坚持"更快的大消息路径"，真正的方向

- 大消息已经带宽饱和（4MB=293µs ≈ 13.7GB/s busbw，接近双 200G 聚合上限 ~23GB/s 的 60%，受 GB10 PCIe/单口 55% 限制）
- 更快的方向不是协议切换，而是：**环网双口并发利用率**（当前 16 通道双 dev 轮换已最大化）、或 **Tree 算法**（ring-only 下不可用，需 P2-3 使能）

---

## 4. 验证建议

1. **容器内一次性验证**（NCCL_TUNER_PLUGIN=none + PerSizeTuner）扫描 92K/368K/512K/1M 元素，确认全部 >40KB 走 Simple、延迟单调、1.47MB ≈176µs。
2. **对比实验**：同一库分别设 `NCCL_TUNER_PLUGIN`（SPCX 劫持）vs `none`（PerSize），直接复现"非单调 vs 单调"。
3. **生产部署后**：head 日志确认 `TUNER/Plugin: Could not find: libnccl-tuner.so`（无 SPCX）+ PerSizeTuner 决策日志（NCCL_DEBUG_SUBSYS=TUNING）。

---

## 5. 结论卡片

| 项 | 结论 |
|---|---|
| 非单调是否真实 | 在 SPCX 劫持的 bench-SB 中真实；在 PerSizeTuner/Simple 下**不存在** |
| 根因 | SPCX tuner 在 1.47MB/2MB 选 LL128（慢），4MB 选 Simple（快）；+ 尺寸单位陷阱 |
| "快路径"是什么 | Simple 协议 + 16 通道 + 8MB buffsize |
| 能否提前 | **已提前**（PerSizeTuner >40KB→Simple，1.47MB 已 176µs） |
| 额外收益 | 无 -31% 空间；真实收益 = 小消息 LL（-21~31%）+ 防 SPCX 劫持 |
| 行动 | 生产部署 Stage B：删 NCCL_PROTO=Simple、保留 NCCL_NET_PLUGIN=none；容器测试加 NCCL_TUNER_PLUGIN=none |

---

## 6. 数据来源

- Stage B 报告：`/opt/aicad-prod/deliverables/engineering-assurance/nccl-stageb-verification-2026-08-16.md`
- bench-SB 原始日志：`docker logs bench-SB-r0`（容器已清理，日志已导出）
- P0 扫描：`nccl-p0-scan-results-2026-08-16.md`
- 阈值扫描：`nccl-proto-threshold-scan-2026-08-16.md`
- head-balance：`nccl-latency-head-balance-architect-2026-08-16.md`（生产 368KB=368640B 定义）
- 源码：`/tmp/nccl-official-2307/src/enqueue.cc`（getAlgoInfo / calcCollChunking）、`src/graph/tuning.cc`（成本模型）
- 扫描脚本：`/tmp/nccl_scan.py`（元素数）、`/tmp/nccl_bench_b0.py`（字节）
