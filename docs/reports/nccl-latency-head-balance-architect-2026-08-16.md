# TP4 环网通讯延迟优化 + head 负载均衡 —— 架构师方案清单（v1）

**日期**：2026-08-16
**作者**：Archi（系统架构师）
**范围**：只读分析（不动服务器）
**输入**：nccl-ab-results-2026-08-16 / nccl-t1am4-e2e-verification-2026-08-16 / findings-raw-2026-08-15 / nccl-latency-optimization-actions-2026-08-15 + WebSearch 社区调研
**约束**：TP4 框架固定（TP1 已确认不可行）；ring-only 补丁在编；T1aM4 已上线

---

## 0. 必须先讲清楚的结构性认知（决定一切优先级）

### 0.1 "368KB allreduce" 不是单次调用，而是每 token 聚合流量

用 TP 通信量模型核算（参考 arXiv 2507.14392 《Characterizing Communication Patterns in Distributed LLM Inference》 的公式）：

```
V_tp(单token decode) ≈ (2L+1) × h × b × 2((t-1)/t) + logits_gather
```

对 DSV4-Flash（L=43, h=4096, MLA o_lora_rank=1024, fp8 激活 b=1, t=4）：

| 组成 | 每层 allreduce 尺寸 | 次数 |
|---|---|---|
| 注意力输出（MLA latent 1024） | ~1-4 KB | 43 |
| MLP down（hidden 4096） | ~4 KB | 43 |
| 首层 embedding allreduce | ~4 KB | 1 |
| 末层 logits allgather | 非 allreduce | 1 |

- **每 decode step ≈ 86~87 次独立小 allreduce**，单次仅 1~4KB（batch=1 时），合计 ≈ **368KB/step**（与实测 368640B 吻合）。
- 投机解码 dspark（5 draft）使 decode batch 升到 6 → 每次 allreduce 放大到 ~6×（~24KB），这是当前**唯一已在生效的"放大单次通信、摊薄每步延迟"机制**。

### 0.2 推论（决定方案取舍）

1. **decode 的瓶颈是"每 call 固定延迟 × 87 次"，不是带宽**。4 节点 RING allreduce = 2(n-1)=**6 步**；每步延迟 ≈ 内核启动 + RDMA 往返 + 协议开销。T1aM4 的 424µs（368KB 单次）≈ 6 步 × ~60-70µs/步 + 传输，**步数/每步延迟主导**。
2. **prefill 的瓶颈是带宽/大消息协议**：4096-token chunk → 每层 allreduce 达 ~16-32MB 级，Simple 协议大幅胜出（T1aM4 已吃下这波：PR +7.7~11.3%）。
3. **64 通道是协议误判的根因**：368KB/64ch = 每通道每步仅 5.75KB → NCCL 自动 tuner 按"每通道小消息"选 LL128（A0 923µs 就是这么来的）。强制 Simple 绕开了每通道 flag 轮询（T1aM4 424µs）。
4. **decode 小消息 Simple 反而不利**（A/B：64KB 档 Simple -17~30%），但 E2E 只 -2.7%~-9.8% → 说明 **GB10 decode 是内存带宽受限/计算受限，通信基本被隐藏**，协议对 decode 的净影响小。这解释了为何全局 Simple 净收益仍成立。
5. 因此**下一波收益的最大杠杆 = 减少"步数 × 次数"**，而非继续压单次参数。

---

## 1. NCCL 参数剩余空间扫描（含已试/未试/建议）

| 参数 | 状态 | 理论 | 建议 |
|---|---|---|---|
| NCCL_PROTO=Simple | 已上线 T1aM4 | 368KB 档赢；<64KB 档输 | 保留；补充 per-size 混合路径（见 P2-5） |
| NCCL_BUFFSIZE=8M | 已上线 | 64ch×8M×2 ≈ 1GB/rank，16M 再翻倍 | **不建议 16M**（显存 + 收益趋零：8M/64=128KB 每通道缓冲已 >> 5.75KB 每步块） |
| NCCL_MIN_NCHANNELS=4 | 已上线 | 小消息活跃通道下限 | 保留；**MAX 侧未试**（见 P1-2） |
| NCCL_NCHANNELS=8 | 已证伪（T1b） | 通道过多管道变浅 | 不再试 |
| NCCL_IB_QPS_PER_CONNECTION=2 | 已证伪（仅作为 T1b 组合） | **SPLIT=1 是延迟杀手**（NCCL 官方："visible latency degradation if we use many QPs"） | **单独 QPS=2 + SPLIT=0 未试**（见 P1-3） |
| NCCL_IB_SPLIT_DATA_ON_QPS=1 | 已证伪（T1b） | 每条消息跨 QP 拆分，延迟劣化 | 保持默认/显式 0 |
| NCCL_IB_TIMEOUT / RETRY_CNT | 未动 | **只影响错误重传，不影响稳态延迟**（default 20/7） | **不调**（调大只延长故障占坑时间，无性能收益） |
| NCCL_IB_GID_INDEX=3 | 已固定 | GID[3]=RoCEv2-IPv4；**社区证实 580.159 驱动改 GID 表导致回退 TCP**，本环境已钉死 | **保持不变**（这是回退防线，非性能项） |
| NCCL_SOCKET_IFNAME | 未动 | 只影响 socket/bootstrap 控制面，不影响 IB 数据面 | 可选加固（避免 bootstrap 误走 RoCE/管理网），非性能项 |
| NCCL_CHECKS_DISABLE=1 | **未试（P0）** | 取消每 call 参数检查；87 次/step × 每 call 省 1-2µs | **最便宜的一张牌**（见 P0-1） |
| NCCL_MAX_NCHANNELS=16/32 | **未试（P1）** | 强制小消息少通道 → 每通道块变大 → 减少通道级开销 | 见 P1-2 |
| NCCL_NTHREADS=256 | **未试（P1）** | 少线程 → 少 launch 开销；可能损大消息带宽 | 见 P1-4 |
| NCCL_ALGO=Tree / ^Ring | **未试（P1/P2）** | 4 节点 Tree = 4 步 vs Ring 6 步，小消息 -33% | 见 P1-1（需先确认 ring-only 补丁是否支持） |

> 结论：**参数层剩下的肥肉集中在"步数"（Tree/拓扑）和"每 call 开销"（checks/nthreads/通道数）**，而非继续加 BUFFSIZE。

---

## 2. 方案清单（按优先级）

### P0｜零风险立试（只改 bench/启动 env，删行即回滚）

**P0-1. NCCL_CHECKS_DISABLE=1**
- 【优化项】`NCCL_CHECKS_DISABLE=1`（+ 确认 `NCCL_CHECK_POINTERS=0`，默认即 0）
- 【理论依据】NCCL 在每 call 做参数/指针检查（debug 开启时）；87 次/step × 每 call 省 1-2µs = 每 step 省 87-174µs。官方文档明确"checks can increase latency，可关闭以提升性能"。
- 【预期收益】decode/小消息路径 -1~3%（e2e），几乎免费
- 【风险】极低；仅失去开发期校验
- 【验证方法】先 `grep NCCL_DEBUG` 确认当前 debug 级别（若 INFO 则 checks 开、收益更大）；四机 env diff；c1@32K rounds≥3
- 【来源】NCCL 官方 env docs

**P0-2. 实测确认"87 次小 allreduce"假设（数据先行）**
- 【优化项】在测试容器用 `NCCL_DEBUG=TRACE`（或 torch profiler / nsys）跑一次真实 vLLM TP4 推理，采集**实际每 call 的 allreduce 尺寸分布与次数**
- 【理论依据】0.1 的推算基于公式，须用实测闭合：若实际 per-call 是 1-4KB×87，则"每步延迟优化"优先级最高；若 vLLM 实际有融合（更大单次），则结论不同
- 【预期收益】把后续所有方案的优先级从"推测"升级为"实证"
- 【风险】TRACE 日志量大，仅测试容器跑
- 【验证方法】`NCCL_DEBUG=TRACE NCCL_DEBUG_FILE=/tmp/nccl-trace.log` + 一个短请求，`grep "ncclAllReduce"` 统计 size 直方图

**P0-3. 快速 bench 扫描（同窗跑完，一次性）**
- 【优化项】在 bench 容器（非生产）扫一组新组合：`MAX_NCHANNELS=16` / `NTHREADS=256` / `QPS=2+SPLIT=0`，分别测 368KB + 64KB + 1MB 三档
- 【理论依据】见 P1-2/3/4 各条；先用 bench 低成本筛掉无效项，再决定是否上生产窗口
- 【预期收益】筛选出 1-2 个真正有效项
- 【风险】零（bench 容器，四机 torch.distributed 已验证可跑）
- 【验证方法】nccl_bench.py（已有脚本）+ 判据：368KB 相对 423.7µs 不劣化、64KB 相对 Simple 基线改善

### P1｜需停机窗口验证（可操作、风险可控）

**P1-1. 验证 NCCL_ALGO=Tree（或 ^Ring）在环网 4 节点的可行性**
- 【优化项】`NCCL_ALGO=Tree` 或 `NCCL_ALGO=^Ring`（先 bench，后生产）
- 【理论依据】4 节点 Ring allreduce = 2(n-1)=6 步；Tree（double binary tree，Sanders 2009）= 2×log2(4)=**4 步**。对 <64-256KB 小/中消息（decode 全部 + 368KB 档），步数 -33% 直接折到延迟 -25~33%。社区与官方均确认"小消息 Tree 胜、大消息 Ring 胜"。
- 【预期收益】decode 每 call 延迟 -25~33%；368KB 档可能 -20~30%
- 【风险】**关键不确定项**：本环境 stock NCCL 纯环 4 rank 曾 110 崩溃（P1 补丁的由来）。若 ring-only 补丁硬编码 RING 或拓扑检测仍崩溃，则 Tree 不可用 → 降级为 P2（需给补丁加 Tree 使能）。另：Tree 在"路径型生成树"上大消息带宽受限（1-2 链路成为瓶颈），**大 prefill 不能走 Tree**——若补丁 tuner 支持按 size 自动切（Ring for large / Tree for small）则最优；否则仅小消息专用实例考虑。
- 【验证方法】bench 容器直接 `NCCL_ALGO=Tree` 跑 4-rank all_reduce，看是否 110 崩溃；不崩则测 368KB/64KB/1MB/16MB 四档；观察 `NCCL_DEBUG=INFO` 的 Tree 构建日志
- 【来源】NCCL 官方算法文档；ai-infrastructure.net / jvoltci 的 Ring/Tree 步数推导；NVIDIA forums 4-node 实测

**P1-2. NCCL_MAX_NCHANNELS=16（保持 Simple/8M/4min）**
- 【优化项】`NCCL_MAX_NCHANNELS=16`（上限而非下限；活跃通道受消息大小约束）
- 【理论依据】当前 64 通道把 368KB 切成 5.75KB/通道 → 每通道开销放大。限制到 16 → 368KB/16=23KB/通道；64KB → 4KB/通道，通道级同步点减少。**同时避免自动 tuner 因"每通道小块"误选 LL128。**
- 【预期收益】小/中消息延迟 -5~15%
- 【风险】大 prefill（16-32MB）需要多通道并行；16 通道可能压带宽 → **必须同时看 1MB+ 档不劣化**
- 【验证方法】bench 扫 MAX_NCHANNELS=16/32，368KB + 1MB + 16MB 三档；生产侧只放行"368KB 和 1MB 都改善、16MB 不劣化"的档
- 【来源】NCCL 官方 env docs（MAX 与 MIN 语义）

**P1-3. NCCL_IB_QPS_PER_CONNECTION=2 + NCCL_IB_SPLIT_DATA_ON_QPS=0（round-robin 非 split）**
- 【优化项】`NCCL_IB_QPS_PER_CONNECTION=2` + 显式 `NCCL_IB_SPLIT_DATA_ON_QPS=0`
- 【理论依据】T1b 证伪的是 **8ch + QPS2 + SPLIT=1** 组合；NCCL 官方明确 SPLIT=1（split 模式）"对多 QP 有可见延迟劣化"。SPLIT=0（round-robin）每个 QP 整条消息轮转，不引入拆分裂缝，环网上每 peer 连接 2 QP 可能降低单 QP 队列深度与 DSCP46 竞争。
- 【预期收益】不确定（-5~10% 尝试值）；直连环网无交换机路由熵，理论增益有限
- 【风险】低；显存 +（2 QP/连接）
- 【验证方法】bench 单独跑 `QPS=2 SPLIT=0`（不叠加 8ch），368KB/64KB 对比 T1aM4
- 【来源】NCCL 官方 env docs（2.10/2.18）；kubernetes.recipes QPS 指南

**P1-4. NCCL_NTHREADS=256（可与 P1-2 同窗扫）**
- 【优化项】`NCCL_NTHREADS=256`
- 【理论依据】小消息延迟受 kernel launch 影响；降线程数减少每 call 启动开销（GB10 20 核、已绑 8-9，CUDA block 更小）。代价是大消息吞吐（默认 512 为带宽优化）。
- 【预期收益】小消息 -5~10%；大消息可能 -3~5%
- 【风险】低；需与大消息档对照
- 【验证方法】bench 扫描；生产只放行双档都合格的组合
- 【来源】NCCL 官方 env docs

**P1-5. 131K 低峰复测 + 观察 decode 侧残余（配合 Tessa）**
- 【优化项】确认 131K 纯净波（rounds=3，带并发监控）——已列 Tessa 待办
- 【理论依据】T1aM4 131K 仅"边缘未破线"；DE -9.8% 若成立，说明小消息 Simple 退化在长档放大，需裁决是否上 per-size 混合
- 【预期收益】决策依据；若 DE 持续接近 -10% → 升级 P2-5（per-size 协议）优先级
- 【风险】无（测试）
- 【验证方法】Tessa 方案固化 SOP（带 num_requests_running 分层判读）

### P2｜需开发或上游（结构性）

**P2-1. TP2×2 双实例（替代已不可行的 TP1×4）**
- 【优化项】两套 TP2 实例：01-02 一对 + 03-04 一对；litellm 路由分流
- 【理论依据】**RING 步数 6→2**（2 节点 ring = 2 步），每 call allreduce 延迟理论上 -50~70%；权重 40.5GiB/2 = 20.25GiB/节点 + KV/2 ≈ 18GiB，单节点仍 < 79GiB 预算，**可行**。这是不换硬件前提下对 decode 延迟的最大单点收益。
- 【预期收益】decode 每 call 延迟 -50~70%；c1 单请求吞吐与 TP4 相当（2 rank 算力），c2 并发由双实例并行承接
- 【风险】运维复杂度翻倍（两套 systemd/监控/回滚）；KV 容量按实例减半（400K 上下文预算重算）；litellm 需按实例路由；flashinfer/dspark 需在 TP2 口径复验
- 【验证方法】测试实例（8002 等独立端口）跑 c1@32K/131K 对照；只读分析阶段不执行
- 【来源】NCCL ring 步数理论（2(n-1)）；vLLM TP 通信量模型

**P2-2. per-size 协议混合（tuner 插件 / 补丁层）**
- 【优化项】为 ring-only 库实现/接入 tuner：`<64KB → LL128，≥64KB → Simple`（阈值可配）
- 【理论依据】协议应"逐 call 尺寸"选择，而非全局强制（当前全局 Simple 牺牲 decode 小消息）。社区已有 `voipmonitor/nccl-tuner-amd` 插件范式（LD_PRELOAD + NCCL_TUNER_PLUGIN，8×RTX6000 实测 LL128 区 512K-2M 提升 10-50%）。
- 【预期收益】decode 小消息回归消除（-2.7%~-9.8% → ~0），prefill 保持 Simple 收益
- 【风险】中等：需要与 ring-only 补丁兼容编译；LL128 编码 + flag 轮询在 Blackwell 的行为需验证
- 【验证方法】staging 容器 LD_PRELOAD 插件跑 64KB/368KB/1MB 三档 + c1@131K 复测
- 【来源】NCCL tuner plugin 接口；voipmonitor/nccl-tuner-amd（GitHub）；alphaxiv 2507.04786（协议 vs 消息尺寸曲线）

**P2-3. ring-only 补丁升级：使能 Tree + 拓扑感知 tuner**
- 【优化项】给 ring-only 库增加 Tree 算法路径与按 size 的 algo 选择（Ring for large / Tree for small）
- 【理论依据】见 P1-1；若 P1-1 显示当前补丁不支持 Tree，则需在源码层补（`make src.build CUDA_HOME=... NVCC_GENCODE sm_121` 已有 build 路径）
- 【预期收益】P1-1 收益 × 自动切算法
- 【风险】高（改库需四机部署 + 回滚锚点）；属开发事项
- 【验证方法】同 P1-1 + 回滚锚点流程

**P2-4. 4 节点接入 200GbE 交换机（硬件拓扑升级，官方推荐路径）**
- 【优化项】购置/接入 200GbE RoCE 交换机，改"直连环网"为"星型/全互联"
- 【理论依据】**NVIDIA GTC 2026 官方对 DGX Spark 4 节点 LLM 推理的推荐拓扑就是 200GbE 交换机**（4-node via switch = 700B 参数/通信密集推理；3-node ring = 微调/训练；2-node direct = 一般推理）。交换机拓扑下对角不再 2 跳、NCCL 可用 Tree/CollNet、消除环网步数上限。
- 【预期收益】结构性消除当前拓扑天花板；368KB/64KB 延迟进一步 -20~40%（可量化但需实测）
- 【风险】高：硬件采购/布线/换网段/iptables 白名单/重做 PEER_HCA；生产迁移窗口
- 【验证方法】先在测试网段用 2 台交换机旁路验证，再切生产
- 【来源】NVIDIA Developer Blog《Scaling Autonomous AI Agents with DGX Spark》（GTC 2026）；dgx-spark-playbooks（nvidia/connect-three-sparks, nvidia/multi-sparks-through-switch）；NVIDIA forums 4-node 实测

**P2-5. vLLM 0.27 通信/序列并行改进（上游，受 flashinfer 阻塞）**
- 【优化项】0.27 的 DSV4 序列并行 + "跳过多余 kernel"（官方称 TTFT -3.4%/-3.9%）已证实为社区核验项；本环境 0.27 升级仍被 flashinfer-cubin 0.6.14 SM120 decode dispatch 缺陷阻塞
- 【理论依据】0.27 release notes：序列并行、skip 空 c128、FlashMLA workspace 等；对 TP4 通信频率有结构性影响
- 【预期收益】TTFT -3~4%（官方数字）+ 通信调用数下降
- 【风险】升级阻塞未解；镜像级
- 【验证方法】flashinfer 0.6.15.post1 cu130 aarch64 就绪后按 v027 A/B 方案执行
- 【来源】vLLM 0.27.0 release notes（freedom.tech / change8.dev）；Tessa v027 A/B 方案

**P2-6. 驱动版本回归核查（580.142 vs 580.159/580.173）**
- 【优化项】评估 580.173.02 是否存在社区报告的 GB10 decode 吞吐回归（580.142→580.159.03 曾致 TP2 decode -3.5×）
- 【理论依据】r0b0tlab 实测：580.159.03 对 GB10(SM121) 有 ~3.5× decode 回归（kernel launch/CUDA graph 捕获效率），回滚 580.142 恢复；本环境 580.173.02 更新于两者，需排除同类问题
- 【预期收益】若存在回归，修复后 decode 可能 +数倍（大口径）
- 【风险】驱动回滚涉及四机重装 + 兼容性复验，高风险高收益；**先只做证据采集（无需动驱动）**
- 【验证方法】在测试容器用固定 kernel 微基准对比；与社区 580.142 数字横向核对；不轻率动生产驱动
- 【来源】r0b0tlab/deepseek-v4-flash-nvfp4-gb10-benchmark（GitHub）

---

## 3. 重点问题直接回答

### a) 除 T1aM4 外最值得试的 3 个参数组合

按"收益 × 可操作性"排序：

1. **NCCL_ALGO=Tree / ^Ring（P1-1）** —— 唯一能把**步数 6→4**（-33%）的参数级手段，直接打 decode 每 call 延迟。前提是 ring-only 补丁不崩（若不支持则转 P2-3 开发）。**最大预期收益**。
2. **NCCL_MAX_NCHANNELS=16（P1-2）** —— 修正 64 通道导致的"每通道小块 + 协议误判"，对小/中消息 -5~15%，同时可能让自动 tuner 对大档行为更健康。**最均衡**。
3. **NCCL_IB_QPS_PER_CONNECTION=2 + SPLIT_DATA_ON_QPS=0（P1-3）** —— 修正 T1b 的"用错拆分模式"问题（SPLIT=1 才是延迟杀手），round-robin 双 QP 在环网可能小幅降每连接队列压力。**低风险补刀**。

另加一个零成本必做：**NCCL_CHECKS_DISABLE=1（P0-1）**，87 次/step 的每 call 检查省下就是净赚。

### b) head 负载均衡是否有可操作优化？

**结论：NCCL 数据面上 head 负载在理论上是均衡的，当前无可操作的 NCCL 侧优化；真正的 head 负担在 CPU 控制面，已被 shim v8 处理。**

论据链：
1. **RING allreduce 对称性**：每 rank 收发总量 = 2(n-1)/n × M = 1.5M，与 rank 位置无关；rank0 只是"向 rank1 发 + 从 rank3 收"各 0.75M，四个 RoCE 口（peer1 dev1/dev3 + peer3 dev0/dev2）全被使用，日志已证 64 通道 = 32/32 每口，**已完美均衡**。
2. **vLLM TP4 allreduce 无 rank0 偏置**：87 次 allreduce 全部 rank 同构执行（MP executor 下 rank0 是 driver 但 NCCL call 由各 rank 各自发起）；logits 为 allgather 也对称。MLA o_proj/q_proj 的 TP 切分不引入 rank0 额外流量。
3. **head 的额外负担在 CPU 面**：TCPStore（仅启动期）、EngineCore 调度、API serving——都在 **15-19 核**（shim v8），与 NCCL 的 8-9 核隔离，不争 NCCL 数据面。
4. **观测到的 GPU util 差（01/02=17.6/17.1% vs 03/04=9.9%）** 更可能来自 embed 共存与业务流量，而非 NCCL 偏置。

**可操作的观测（不停生产）**：
- `nvidia-smi dmon -s pucvmet -d 1` 四机同步采样，对比 per-rank SM% 峰值/均值（bench 时打点）
- `/sys/class/infiniband/*/ports/1/counters/port_xmit_data` + `port_rcv_data` bench 前后差值 → 直接量化每口数据面字节对称性
- `NCCL_DEBUG=TRACE`（测试容器）按 rank 统计每 call send/recv 尺寸 → 确认 rank0 总字节 = 其他 rank
- `ib_read_lat`/`ib_write_bw` 环上四条边对称测试 → 排除链路本身不均衡
- `ps -eLo tid,psr,comm | grep -E "NCCL|EngineC"` 四机核对 shim pin 在 head 上也生效

**若观测发现 head 偏高，最可能来源与对策**：head EngineCore + API 进程在 15-19 核上的 CPU 调度抖动（非网络）→ 保持 shim v8、必要时把 API/tokenizer 线程外置（已是 mp 后端）；**不建议动 PEER_HCA 映射**（已均衡，改映射是负优化）。

### c) 社区有无环网 TP4 的更好做法？

有，但结论分三层：

1. **官方（NVIDIA）对 4 节点 LLM 推理的推荐拓扑不是直连环，而是 200GbE 交换机**（GTC 2026，DGX Spark 4-node via switch 面向 700B/通信密集推理；3-node ring 面向微调/训练；2-node direct 面向一般推理）。→ 长期结构性路径 = **P2-4**。社区实测佐证：4 节点经 2 台交换机 busbw 15.58 GB/s vs 2 节点同交换机 23.9 GB/s（NVIDIA forums）——交换机拓扑本身也有跨交换损耗，但换取了对角直达 + Tree/CollNet。
2. **同是直连/环网的社区做法与我们的差距主要在"已修项"**：r0b0tlab 双 GB10 TP2 报告 NCCL GID 表因驱动 580.159 变化导致 TCP 回退（424µs→修复 22µs）——**我们已钉死 GID=3 规避**；其 MoE padding 修复（compute_aligned_M 过分配 21×→1×）是模型层收益，**建议核对 0.26 anemll 镜像是否已含**（P1 追加项）。
3. **"社区有没有更好"的务实答案**：在不动硬件的前提下，社区没有比"TP4 环网 + Simple/大缓冲 + 尽量放大单次通信（投机解码 batch）"更好的现成方案；可借鉴的**新东西**只有：per-size tuner 插件（P2-2）、驱动回归核查（P2-6）、以及 NVIDIA playbooks 强调的"小消息永远跑不满 200G，必须靠缓冲/批量放大单次通信"这一原则（我们已在用）。

---

## 4. 落地顺序建议（对 team-lead / Rex / Tessa）

```
第 1 步（P0，无需停机）：P0-2 实测 per-call 尺寸 + P0-1 CHECKS_DISABLE + P0-3 bench 扫描
第 2 步（P1，一个停机窗口）：P1-1 Tree 可行性 → P1-2 MAX_CH=16 → P1-3 QPS2/SPLIT0 → P1-4 NTHREADS
   （按"每项单独 bench + 合格才上生产"纪律，任一 110 崩溃/回归即跳过）
第 3 步（P1，同窗或下窗）：131K 纯净复测（Tessa）+ 驱动/MoE-padding 证据采集
第 4 步（P2，立项决策）：TP2×2（P2-1）与交换机拓扑（P2-4）二选一作为下一阶段结构路径
```

**验收线维持 v2 口径**：368KB 延迟相对 T1aM4(423.7µs) 再有 -15% 以上才值得叠加；端到端以 c1@32K（PR 2272/DE 93.84/TTFT 12.56s）为同源基线，±10% 内无回归；131K 纯净波为视窗判据。

---

## 5. 风险与纪律

- **Tree 风险**：ring-only 补丁可能不支持 → 110 崩溃 = 直接跳过，不强行；若支持但大消息带宽劣化，仅允许小消息档使用（需 tuner 支持按 size 切）。
- **MAX_NCHANNELS 风险**：大 prefill 带宽依赖多通道 → 16MB 档必须不劣化才放行。
- **CHECKS_DISABLE 风险**：生产若遇误用指针，缺校验更难定位 → 仅在新版本验证窗口内合入，回滚路径保留。
- **P2-6 驱动项风险**：只做证据采集，不轻率动生产驱动；社区回归结论基于 TP2 特定 fork，需本方复验。
- **head 均衡结论的适用边界**：基于"ring 对称 + 日志 32/32"的推理；若 P0-2 观测发现实测字节不均（如某口 PFC/丢包），再回头评估（优先级立即上调）。

---

## 6. 数据来源

- 本地实测：nccl-ab-results-2026-08-16.md / nccl-t1am4-e2e-verification-2026-08-16.md / findings-raw-2026-08-15.md / nccl-latency-optimization-actions-2026-08-15.md / tp4-service-deployment-guide-2026-08-13.md
- 社区：NVIDIA Developer Blog（DGX Spark scaling, GTC 2026）；NVIDIA forums（4-node vs 2-node NCCL）；r0b0tlab/deepseek-v4-flash-nvfp4-gb10-benchmark；dgx-spark-playbooks（github.com/NVIDIA）；kubernetes.recipes NCCL QPS/RoCE；voipmonitor/nccl-tuner-amd；arXiv 2507.14392（TP 通信量模型）、2507.04786（NCCL 协议曲线）；NCCL 官方 env docs
