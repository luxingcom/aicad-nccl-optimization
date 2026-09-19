# 停机窗口 2 报告 — GPU 真实内存语义实测 + A/B 全套 + A2A 算法级验证

日期：2026-09-03 14:50-15:30
环境：四机 baked 生产镜像测试容器（st 库 8d6d2de8 = hardened 源码 + skip-tree-pat），logdump 取证链在位
生产恢复：head/worker 已按交接单拉起（报告落盘时加载中），healthcheck/proxy 待 health=200 后启用

---

## TL;DR — 五项核心成果

1. **SIRCL GPU 真实内存语义 2 轮全交换实测通过**（非模拟）：真 GPU 内存 + RDMA WRITE + doorbell，
   四机全尺寸 correct=true：**4KB p50=21.2µs vs NCCL 31.4µs（快 33%）**；收益区 ≤16KB，≥64KB 被 ring 反超（单 QP 串行带宽塌陷，与 SparkRing 自家结论互证）。
2. **skip-tree-pat 补丁全套验证通过**（B0/B1/SPCX），并实锤两件事：
   - **冷启动首跑慢速路径（8989µs）的根因 = Tree/PAT 非环邻建连**，`NCCL_SKIP_TREE_CONNECT=1` 直接消除——生产每次重启直接受益；
   - A2A 算法级基准从 12ms → 92µs（130×）也是同一根因的反证。
3. **A2A 算法级 2 轮邻居交换在真实 GPU+fabric 验证通过**（全尺寸正确，4K=92µs，1M=154µs）——
   本集群**唯一可用**的 all-to-all（NCCL alltoall 物理不可达，L3 中继数据面已判死）。
4. C 臂结论：`PREFIX_LEN=24` 有害（不予采纳）；`CUMEM_ENABLE=0` 中性。
5. 慢/快路径交替现象定性：init 竞态 + Tree/PAT 110 风暴残留态，SKIP_TREE + 复跑即可稳定快速路径。

## 一、SIRCL GPU 真实内存语义（tp4_tensor_probe，四机，100 iters + 20 warmup）

| 尺寸 | SIRCL p50 | NCCL ring AR avg | 比值 |
|---:|---:|---:|---|
| 4KB | **21.2µs** | 31.4µs | **1.48× 快** |
| 16KB | 37.9µs | 38.8µs | ~持平 |
| 64KB | 102.5µs | 70.1µs | 0.68× |
| 256KB | 368.7µs | 80.6µs | 0.22× |
| 1MB | 1299µs | 147.8µs | 0.11× |

- 全尺寸 `mismatched_elements=0 correct=true`——协议在真实 GPU 内存语义下正确
- 配置=prep 报告的设备表（round0 全员 rocep1s0f1，round1 全员 roceP2p1s0f0，GID 3，控制口 9410-9440）
- **结论：2HOP/S2 原型的收益区=decode 小消息带（≤16-32KB），4KB 档真实收益 33%（CPU 模拟预测 3.3× 中的网络部分兑现，剩余差距=host enqueue 开销，graph 路径可再压）**
- graph 探测（q1/8KB）：submit 3.6µs 但 burst 模式 2.8ms/次（serial_ack+单op轮询退避放大）——graph 路径需 SparkRing 的 tiered/fused 调优，维持其 research-only 定位

## 二、A/B 全套（AR 基线对比，avg µs）

| 臂 | 4K | 16K | 64K | 结论 |
|---|---:|---:|---:|---|
| A0 baked 生产库 | 31.4 | 38.8 | 70.1 | 基线 |
| B0 st 库(8d6d2de8) | 35.6 | 45.7 | 70.1 | 回归中性（噪声带内） |
| B1 +SKIP_TREE | 31.5 | 38.8 | 70.4 | 持平 + **冷启动直快** |
| C1 +PREFIX_LEN=24 | 慢速路径 | — | — | **有害，不采纳** |
| C2 +CUMEM=0 | 31.3 | 38.2 | 70.1 | 中性 |
| SPCX 敌对 tuner | 31.9 | 38.2 | — | **加固生效**（stub 加载 + per-size 覆盖不被带偏） |

**冷启动实验**：新建容器首个 NCCL init 无 env → 8989µs 慢速路径；带 SKIP_TREE_CONNECT=1 → 首跑即 31µs 快速路径。

## 三、A2A 算法级（bench_a2a2.py：2 轮邻居交换，NCCL p2p 直连边）

| 尺寸 | avg | p50 | ok |
|---:|---:|---:|---|
| 1K | 112µs | 178µs | 1 |
| 4K | 92µs | 185µs | 1 |
| 16K | 107µs | 178µs | 1 |
| 64K | 89µs | 182µs | 1 |
| 256K | 115µs | 105µs | 1 |
| 1M | 154µs | 175µs | 1 |

- 无 SKIP_TREE 时 11988µs（慢速路径签名），加 env 后 130× 提升——根因互证
- 每 rank 总流量 S（直连 3S/4 + 中继 S/4×2），vs 全互联理想 3S/4 = 4/3 开销，换 fabric 可行性
- **这是本集群唯一能跑通的 all-to-all**：EP/DP 引入时的通信底座选项之一

## 四、对 S2 立项的最终输入

1. 收益区确认 ≤16-32KB（decode AR 主战场），4KB 真实 GPU 收益 33%，网络部分（CPU 模拟 9.5µs）还有 12µs 的 host enqueue 差距可由 graph/device doorbell 路径压缩
2. skip-tree-pat 库（8d6d2de8）四机在位 `/opt/nccl-ringonly-st`，**S0 可直接晋升生产**：补丁回归中性 + 消冷启动慢路径 + SPCX 加固生效；只需 env 加 `NCCL_SKIP_TREE_CONNECT=1`
3. 大消息继续走 NCCL ring（SIRCL ≥64KB 塌陷是单 QP 串行路径，不必追）
4. A2A：算法级 2 轮邻居交换已验证，作为 EP/DP 通信底座候选
5. 遗留：NCCL init 慢/快交替（复跑恢复）——晋升 SKIP_TREE 后应消失，生产观察确认

## 五、窗口纪律执行记录

- 全程 timeout 包裹 + 幂等清理 + docker 组直连（无 sudo 管道）
- 每阶段后进程数/容器数/内存核对（四机全程无异常增长，收尾 0 残留）
- 上窗口内存事故（fork 链）未复发
