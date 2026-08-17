# 环网集群延迟优化措施清单（交付执行专家）

**日期**：2026-08-15（v2：按 Cody/Rex 双成员审查修订）
**工作流**：NCCL 环网补丁优化（延迟优先）
**编制**：工程保障团队主理人（基于 Archi 方案 + Rex 判读标准 + Cody/Rex 审查修订 + 主理人实测证据）
**执行环境**：<node1>~04（生产 TP4 已停机，GPU 空闲，03/04 仅 embed 5.7GB）

---

## 📌 TL;DR

- **路径 A 已定案**：二进制符号 `RING-ONLY v3: peer %d chan %d -> net dev %d` + 生产日志统计（peer1: dev1×32+dev3×32；peer3: dev0×32+dev2×32，64 通道完美均分双口）实证 **v3 补丁已是 channel 级双口轮换，Archi 的"钉死单口"假设被推翻，无需 v4 改码**。
- **延迟主攻点**：每 token 368KB allreduce（MLA 激活）+ 131K 长上下文 TTFT 63s。
- **验收判据（v2 修正，Cody High 项）**：禁用过时基线 TPOT 431ms（8/12 fix72 问题窗口数据）；以 **nccl-tests 368KB 延迟实测前后对比为主判据**，端到端以 **8/15 快检同源数据**（PR 2110 / DE 96 / TTFT 13.6s）为回归基线。
- 全部措施按"预期收益 × 风险 × 前置条件"排序，P0 零风险可立即执行；**执行前必须先补齐恢复 SOP 与四节点 env diff 核对（Rex 硬约束）**。
- mpirun 多机实测存在 ORTE 路由问题未打通（多网卡环境 orted 回连失败），备选路径为容器内 torch.distributed 4-rank bench（脚本见附录 A，已备好）。

---

## 已实证的基线数据（勿重复采集）

| 项 | 值 | 来源 |
|---|---|---|
| 单口带宽（TCP/RoCE 双口径） | 107-110 Gbps（200G 口的 55%） | 主理人 iperf3/ib_write_bw 实测 |
| 双 dev 轮换 busbw | 23.86 GB/s（历史，口径见 §A0 判据） | P2 v3 补丁记录 |
| v3 通道分布 | 每 peer 双口各 32 通道，完美均衡 | nccl-<node1>.log 统计 |
| 368KB allreduce 延迟 | **待实测**（Archi 估 ~110µs 不作验收线依据，v2 修正） | 先补实测基线 |
| c1@131K | TTFT 63s / decode 102 tok/s | 8/15 生产快检 |
| c1@32K（回归基线） | PR 2110.14 / DE 96.45 / TTFT 13.60s | 8/15 快检（同源） |
| 当前稳态 TPOT 折算 | DE 96-102 tok/s → **TPOT ≈10.4ms**（v2 修正：431ms 为 8/12 问题窗口数据，作废） | 8/15 快检换算 |
| MTU | OS 9000 / RDMA active 4096（非瓶颈，勿动） | Archi 实证 |
| nccl-tests | /opt/nccl-tests/all_reduce_perf_ringonly（需 LD_LIBRARY_PATH=/opt/nccl-ringonly:/usr/local/cuda/lib64） | 主理人核实 |

---

## ⚠️ 执行前置（v2 新增，Rex 硬约束，先做这 3 步再动 env）

### P0a. 恢复/停机 SOP（生产恢复纪律）
- **停机顺序**：worker 先停（03→04→02）→ head 后停（01）；`systemctl stop vllm-tp4-{head,worker}.service` → 确认 monitor 退出（0 进程）→ `docker rm -f` 容器
- **启动顺序**：head-first（01 先起 → 02/04/03，TCPStore :25999 门禁 120s）
- **litellm 网关**：恢复前确认 litellm-proxy（02:4000）路由指向 8001；实验期间若直接改 8001 参数，litellm 无需动（它只代理到 8001）；恢复后 curl /health=200 + 真实推理 smoke test
- **恢复后观察窗**：30 分钟健康观察（TTFT/PR/DE 采样 + 日志扫 NCCL error / CUDA OOM / "No available memory"）

### P0b. 四节点 env diff 核对
ENV_ARGS 是 per-node 读取，head/worker 脚本分属 4 台机。**改动前/后都必须执行**：
```bash
for h in <node1> <node2> <node3> <node4>; do
  echo "== $h =="; ssh $h "grep -E 'NCCL_PROTO|NCCL_BUFFSIZE|NCCL_MIN_NCHANNELS|NCCL_NCHANNELS' /opt/aicad-prod/scripts/start_tp4_{head,worker}.sh 2>/dev/null | sort -u"
done
# 四机输出必须完全一致（协议不匹配 LL128 vs Simple 会导致起不来或静默降级）
```

### P0c. 回滚路径（git 化，降级为"切回旧 tag"）
- env 改动先 `cd /opt/aicad-prod/scripts && git diff > ~/nccl-env-v2.patch.bak` 留档
- 容器镜像保留旧 tag（0.2.1-v026.0 勿删）；若重建后异常，回滚 = 删除 env 行 + 重建容器（.bak 留档）

## 延迟优化措施（按优先级）

### P0｜零风险 env 调优（立即可做，只改启动脚本 env）

**M1. 368KB 档协议切换 LL128→Simple**
```bash
NCCL_PROTO=Simple   # 368KB 处带宽-延迟分界，LL128 的 120/128 编码 + flag 轮询开销 ~6-8%
```
预期：每 token allreduce 延迟 -10~15%，decode 直接受益（每步 2 次 allreduce × 43 层）。

**M2. BUFFSIZE 4M→8M 加深管道**
```bash
NCCL_BUFFSIZE=8388608   # 368KB in-flight 批次 5→10，摊薄同步点
```
注意：8ch×16M 会占显存，16M 档位需评估；8M 起步安全。

**M3. 通道数提升（v2 修正：先确认当前 channel 数再定档）**
```bash
# 执行前先确认当前每 peer 通道数（日志已证 v3 为 64 通道/peer 口径，勿盲目设定）
grep -h "RING-ONLY v3: peer" /home/<svc-user>/vllm-logs/nccl-<node1>.log | wc -l   # 通道计数
grep -h "Channel 00/" /home/<svc-user>/vllm-logs/nccl-<node1>.log | head -1      # 总通道判定
# 档1：NCCL_MIN_NCHANNELS=4（若当前低于 4 才有效）
# 档2（档1 验证后）：NCCL_NCHANNELS=8（仅当当前 <8 时提升；若已 ≥8 则跳过本项，重点转 M1/M2）
```
> **Cody Med 项提醒**：若当前通道数已 ≥8，NCCL_NCHANNELS=8 反而是降通道。M3 以"确认现状→再决定"为准。

**执行方式**：在 start_tp4_head.sh / start_tp4_worker.sh 的 ENV_ARGS 中追加（当前 ALGO=RING / NET=IB / GID=3 / MERGE_NICS=0 / TOS=46 / CROSS_NIC=1 全部保持不动）。**逐项验证**：每加一项跑 c1@32K bench（PR/DE/TTFT），对比 8/15 基线（PR 2110 / DE 96 / TTFT 13.6s），无回归再加下一项。
**回滚**：删除 env 行重建容器即可，.bak-script 留档。

### P1｜低风险参数调优（需短窗口验证）

**M4. 激进档 QP 分流**（P0 验证后）
```bash
NCCL_IB_QPS_PER_CONNECTION=2
NCCL_IB_SPLIT_DATA_ON_QPS=1
```
前置：`grep -rn "QPS_PER_CONNECTION\|SPLIT_DATA_ON_QPS" /opt/nccl-ringonly/../nccl-src 2>/dev/null` 确认 2.30.7 支持（源码不在 /opt/nccl-ringonly，用 `strings /opt/nccl-ringonly/libnccl.so.2.30.7 | grep QPS` 验证）。

**M5. TTFT 长上下文优化：chunked prefill 加深**
```
--max-num-batched-tokens 4096 → 8192（或 16384）
```
131K TTFT 63s 中 prefill 串行 32 chunk 是主因。风险：显存峰值上升（激活 ~1.8GiB 会增），util 0.65 下有 ~79GiB/121.6GiB 余量，8192 应安全；16384 需盯 `No available memory for cache blocks`。
验证：c1@131K TTFT 63s → 目标 <45s。

**M6. 投机解码 per-batch 表微调**
当前 `[[1,1,5],[2,4,4],[5,6,3]]`（batch 大时降到 3 token 是 TPOT 变差因素之一）。若业务实际并发多为 c1-c2，可试 `[[1,1,5],[2,4,4],[5,6,4]]`，接受率 0.75-0.92 下 4-draft 或更优。**用 bench A/B 决定，不拍脑袋。**

### P2｜结构性方案（大收益，需专门窗口决策）

**M7. TP2×2 双实例 / TP1×4 四实例**（延迟终极解）
- 权重 40.5GiB < 单机 121.6GiB，单机完全放得下
- TP4 的每 token 跨机 allreduce（368KB×43 层×2 次）**整条消除**（TP1）或减半（TP2）
- c1 decode 有望从 ~100 提升至单机理论 150-250 tok/s 区间；TTFT 消除跨机同步
- 代价：400K 长上下文 KV cache 单机 ~34-36GiB 需重核算；litellm 网关改为多实例路由；运维复杂度上升
- **建议**：起 TP1 单机实例（01 机本地权重，--tensor-parallel-size 1 --nnodes 1，端口 8002）跑 c1@32K/131K bench 对照，用数据决策。启动脚本可从 archive_scripts/start_head_v026.sh 改（去掉 nnodes/node-rank/master-addr）。

**M8. flashinfer 0.6.15 升级**（0.27 前置）
- 生产镜像已用 python 0.6.15 + jit-cache 0.6.15+cu130（SM120 decode 修复版），**无需动**
- 0.27 升级仍阻塞于 flashinfer-cubin 0.6.14 SM120 decode dispatch（镜像级），flashinfer.ai 源 + GitHub release 有 0.6.15.post1 cu130 aarch64（1.8GB jit-cache）可取，属独立升级窗口事项

### 验证判据（v2 修正：Cody High 项--禁用过时基线，统一同源）

1. **先补实测基线（第一步，不跳过）**：用 nccl-tests 实测当前 368KB 单次 allreduce 延迟（A0 env），记录为真实基线 B0。**Archi 估的 110µs 不作为验收线依据**（v2 修正）。
2. **主判据（NCCL 层）**：368KB 单次 allreduce 延迟相比 B0 ≥20% 下降（如 B0=110µs → ≤88µs；以实测 B0 为分母）。
3. **次判据（端到端回归）**：c1@32K PR/DE/TTFT 相对 **8/15 快检同源基线**（PR 2110.14 / DE 96.45 / TTFT 13.60s）**无回归（±10% 内）**；当前稳态 TPOT ≈10.4ms（DE 96-102 折算），**禁用 8/12 fix72 的 431ms**（问题窗口数据，作废）。
4. **收口判定**：A0 复测 busbw 与历史 23.86GB/s（**同消息尺寸/rank/iterations 口径**）量级一致，且 env 调优提升 <5% → 网络侧已到顶，重心转 M5/M7。
5. **采样方法（v2 新增）**：每档 bench 跑 rounds≥3 取 p50；TTFT/TPOT 波动容忍 ±15%；A/B 数据落盘 `deliverables/engineering-assurance/verification-logs/`（固定路径，附命令与 env 快照）。

### 附录 A：备选 bench（ORTE 失败时的 torch.distributed 4-rank 退路，已备好）

```bash
# 01 机执行（容器内，需四机同镜像+免密）
cat > /tmp/nccl_bench.py <<'EOF'
import os, time, torch, torch.distributed as dist
dist.init_process_group("nccl")
rank = dist.get_rank()
sizes = [65536, 131072, 262144, 368640, 524288, 1048576]
for n in sizes:
    t = torch.ones(n, dtype=torch.float32, device="cuda")
    for _ in range(10): dist.all_reduce(t)          # warmup
    torch.cuda.synchronize()
    ts = []
    for _ in range(50):
        torch.cuda.synchronize(); s = time.perf_counter()
        dist.all_reduce(t)
        torch.cuda.synchronize(); ts.append(time.perf_counter() - s)
    if rank == 0: print(f"size={n} avg={sum(ts)/len(ts)*1e6:.1f}us")
EOF
mpirun -np 4 -H <node1>:1,<node2>:1,<node4>:1,<node3>:1 \
  --allow-run-as-root --mca routed direct --mca btl tcp,self --mca btl_tcp_if_include enP7s7 \
  -x LD_LIBRARY_PATH=/opt/nccl-ringonly:/usr/local/cuda/lib64 \
  -x NCCL_ALGO=Ring -x NCCL_NET=IB -x NCCL_IB_GID_INDEX=3 -x NCCL_IB_MERGE_NICS=0 \
  python /tmp/nccl_bench.py
```

---

## ✅ 行动清单（v2 修订）

| # | 行动 | 紧急度 | 预期收益 | 风险 |
|---|------|--------|---------|------|
| 0 | **前置三步**：P0a 恢复 SOP 交底 / P0b 四节点 env diff / P0c 回滚 git 化 | P0 | 消除操作风险 | 零 |
| 0.5 | **补实测基线 B0**：nccl-tests 368KB 当前延迟（A0 env），锁定主判据分母 | P0 | 验收线同源 | 零 |
| 1 | M1+M2+M3 三项 env 上 staging 验证（逐项 bench，rounds≥3 取 p50） | P0 | 368KB 延迟 -10~25% | 零（删 env 即回滚） |
| 2 | M5 max-num-batched-tokens 8192 + c1@131K TTFT 复测 | P1 | TTFT 63s→<45s | 低（显存盯防） |
| 3 | M7 TP1 单机对照实例（8002 直连测，不经 litellm，结论口径注明） | P1 | 决策依据：跨机开销量化 | 低（独立端口） |
| 4 | M4 QP 分流（strings 确认支持后） | P2 | 叠加 5-10% | 低 |
| 5 | M6 投机 per-batch A/B | P2 | TPOT -5~10% | 低 |

## ⚠️ 已知局限（v2 补充）

- mpirun 多机实测未打通（ORTE 路由），368KB 延迟改善幅度需执行专家实测确认（退路脚本已备，附录 A）
- NCCL 源码不在服务器（仅二进制+strings 验证），v3 行为以日志+符号双证据定案
- M7 收益预估基于内存带宽推算（LPDDR5X 273GB/s vs 网络 26.9GB/s），非实测；"150-250 tok/s"为**乐观假设**（数据包口径 100-270 受实现影响），须 TP1 实测裁决
- **显存账（Cody Med 项）**：M5 的 79GiB 是 util 0.65 的**显存预算上限**（121.6×0.65），非权重外余量；131K 下 KV cache 更大，16384 档须重算（权重 40.5 + KV + 激活 ≤ 79GiB）
- **embed 共存**：03/04 有 embed 5.7GB；NCHANNELS/BUFFSIZE 调大会增加 NCCL 显存分配，需确认不挤占（验证窗口可避让）
- **日志证据**：v3 定案依赖 nccl-<node1>.log，确认持久化挂载 + 轮转不删，防容器重建丢证据
- M2 "in-flight 批次翻倍"为定性描述（4MB/368KB≈11 批，8M 后≈22），方向正确、数值随实现浮动

## 📚 数据来源

- 主理人实测：网络带宽（iperf3/ib_write_bw）、NCCL 日志统计、二进制符号
- Archi 报告：/opt/aicad-prod/deliverables/engineering-assurance/nccl-ringonly-optimization-2026-08-15.md
- **Cody（code-reviewer）审查意见**：v2 修订（验收判据 High 项、M3 口径、显存算式、乐观假设措辞）
- **Rex（sre-engineer）审查意见**：v2 修订（恢复 SOP、四机 env diff、git 化回滚、观察窗、采样方法）
- 生产基线：prod-perf-quickcheck-2026-08-15.md、TP4FINAL（8/12）
- 本地数据包：research/findings-raw-2026-08-15.md

> 本报告由工程保障团队协作生成（v2 经双成员审查修订），关键决策请由人类工程负责人复核。
