# 引用与血统 — 参考实现/报告谱系/基准锚点/关联资产

---

## 1. 参考实现借鉴对照（SparkRing）

血统声明：本模块未复制 SparkRing 代码（其克隆在 `~/sparkring-kit/sparkring`，仅作行为参考）；
以下为**范式级借鉴**（思想引用）与**分叉点**：

| 借鉴点 | SparkRing 出处 | ar2 落地 | 分叉说明 |
|---|---|---|---|
| 门铃+旗标握手范式 | spark_transport (producer/门铃/done) | Ar2Ctl 七字 + post_burst | WR 数 6→2；门铃内嵌 magic/flags |
| `__threadfence_system` 发布序 | kernel 发布路径 | dev_pub + st_release/ld_acquire | 同型 |
| device 端 claim 序号 | graph_publish_command | seq 区 word0 atomicAdd_system | 同型（W2 引入修 host 写字竞态） |
| 早到容忍 | eager kernel 容忍 overshoot | wait_two 有界容忍 d≤seq+1 | 贡献：界证明 + 超界仍报错 |
| EndpointInfo 几何校验 | 建连校验 | PeerInfo magic+字段全校验 | 同型 |
| 错误中止 | 各 rank 等满 deadline | 33µs 门铃级联 + kernel abort 感知退出 | 强化（实测对比） |

## 2. 报告谱系（全部原件在 docs/ 或其原位）

| 报告 | 位置 | 内容 |
|---|---|---|
| S2-DESIGN.md | docs/ | 立项设计书（目标/错误模型/enqueue+graph 策略） |
| S2-W1-REPORT-20260903.md | docs/ | W1：M1 四机全绿 + 错误模型实测 + M2 bug 首次记录（坑 1-8） |
| W2-REPORT-20260903.md | docs/ | W2：baked-v6 镜像构建与全生产形态验证（health/md5/env/autotune/PR 首轮） |
| W3-REPORT-20260903.md | docs/ | W3：M2 根治（9 轮调查链）+ 回归矩阵 + v6 二轮整套基准 + 生产恢复 |
| WINDOW2-REPORT-20260903.md | docs/ | 更早窗口：SIRCL GPU 语义实测（4KB +33%）、SKIP_TREE 根因、A2A、C 臂 |
| WINDOW-REPORT-20260903.md | ~/sparkring-kit/window-20260903/ | 首窗口：baked 库 md5 漂移发现等 |
| PREP-REPORT-20260903.md | ~/sparkring-kit/ | 开窗准备：克隆/补丁/SIRCL/设备表与 GID 规则 |
| proto_2round_ar.c v6 | ~/sparkring-kit/proto/ | ar2 的 verbs 骨架直系祖先（fabric 实测验证版） |

## 3. 基准锚点（跨项目可比数字）

- **NCCL ring 生产基线**（LuZ0.4.5 baked 8c7a5df9，W2 窗口 A/B 臂 A0）：AR 1K=28.3 / 4K=31.4 / 16K=38.8 / 64K=70.1µs
- **stageB-glibcfix AB**（20260816）：LL 带 4K=42.7 / 8K=44.4 / 16K=48.7（LL 比 Simple 快 19-27%）
- **SIRCL GPU 语义**（WINDOW2）：4K p50=21.2µs（+33% vs NCCL）——ar2 m1 4K=26.0 的对照
- **裸 RDMA 延迟地板**：round0 1K=2.24µs / 16K=4.43µs；round1 1K=2.65µs
- **ar2 W3 终值**：1K=21.1 / 4K=26.0 / 16K=45.5µs；layer 12KB 34.7-38.7µs/op
- **v6 vLLM E2E**（BENCHV2_20260903T2015/2052Z）：PR 20/20 + DE 12/12 全绿

## 4. 集群与生产资产（关联记忆/位置）

- 集群台账：`dgxspark-vllm-cluster-state`（记忆）——镜像真身/生产形态/凭据
- rank 映射：01=rank0(186) / 02=rank1(187) / 04=rank2(189) / 03=rank3(188)
- 生产链：`~/w6-kit/monitor_tp4_head_v043.sh` + systemd vllm028-tp4-head/worker + concurrency-proxy(8001→8002)
- bench 工具链：`/opt/aicad-prod/bench_v2.py`（PR/DE；--endpoint 8002/v1 --key dummy-bench）
- v6 镜像：registry `...-Ring-baked-v6` digest 62670d69（01）= d5417759（workers，内容一致 md5 裁决）
- 2hop 归档：`/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/`（16 份报告+4 份裁定）
- nvfancontrol/DSV4-Vision 等其他线：见记忆索引 MEMORY.md

## 5. 设备与网络配置（生产几何）

| 项 | 值 |
|---|---|
| round0 NIC | rocep1s0f1（全员，136/138 网） |
| round1 NIC | roceP2p1s0f0（141 网 + 198.51.100.13/14，避开 NFS .9/.10） |
| GID index | 3 |
| QP | RC, MTU≤4096, timeout=14, retry=7, rnr_retry=7, inline 64B |
| 控制口 | 9500（probe），生产 tuner 集成时建议独立端口段 |

## 6. 术语表

| 术语 | 含义 |
|---|---|
| 2HOP / 2 轮全交换 | 两轮邻居交换实现 allreduce（round0 rank^1 / round1 rank^3） |
| 门铃 (doorbell) | 8B inline RDMA WRITE 完成通知字 [magic\|flags\|seq] |
| 槽 (slot) | arena 中 recv/send 区的轮转分片，slot(m)=(m-1)%nslots |
| claim | kernel 执行时对 seq 计数器的原子取号 |
| 有界偏斜 | 对端门铃合法领先本端至多 1 op 的协议状态 |
| M1/M2/M3 | 单 op 串行 / 整层 graph / 回退路径 |
| 指纹校验 | buf 间可区分的精确值设计（base=10+2^i） |
| 金丝雀 | kernel 写入调试区的"我读到了什么"原始记录 |
