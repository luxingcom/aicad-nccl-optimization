# NCCL 环网 A/B 实测结果（A0 / T1a / T1b / T1aM4）

**日期**：2026-08-16 00:00 (UTC+8)
**执行**：工程保障团队主理人（四机容器 torch.distributed 4-rank all_reduce bench）
**载体**：sglang 26.07 容器 + ring-only v3 库（LD_LIBRARY_PATH=/opt/nccl-ringonly，torch 2.13 + NCCL 2.30.7）
**脚本**：/tmp/nccl_bench.py（warmup 10 + 采样 50 次取均值，float32，per-size）
**拓扑**：环网 01(0)-02(1)-04(2)-03(3)，PEER_HCA 对口双口，GID=3，MERGE_NICS=0

---

## 1. 数据总表（rank0 视角）

| size (B) | A0 基线 (µs) | T1a (µs) | T1b (µs) | T1aM4 (µs) | T1a vs A0 | T1aM4 vs A0 |
|---|---|---|---|---|---|---|
| 65536 | 237.7 | 309.5 | 431.3 | 279.2 | **-30%** ❌ | -17% ❌ |
| 131072 | 523.6 | 500.9 | 693.5 | 488.8 | +4% | +7% |
| 262144 | 1281.1 | 868.9 | 854.6 | 910.1 | **+32%** | **+29%** |
| **368640（目标）** | **923.4** | **444.5** | 580.3 | **423.7** | **+52%** 🎯 | **+54%** 🎯 |
| 524288 | 1330.8 | 619.7 | 799.2 | 656.8 | **+53%** | +51% |
| 1048576 | 704.0 | 661.4 | 824.8 | 658.4 | +6% | +6% |

### busbw 对比（368640 档）
| 档位 | busbw | vs A0 |
|---|---|---|
| A0（生产基线 env） | 2.40 GB/s | — |
| T1a（Simple+BUFFSIZE 8M+MIN_CH 2） | 4.98 GB/s | **+108%** |
| T1b（+NCHANNELS 8 + QPS 2 + SPLIT） | 3.81 GB/s | +59% |
| T1aM4（T1a+MIN_CHANNELS 4） | 5.22 GB/s | **+118%** |

---

## 2. 结论

1. **T1a 达标**：368KB 延迟 923→444µs（**-52%**），远超验收线（-20%）。主因：`NCCL_PROTO=Simple`（368KB 档 LL128 编码+flag 轮询开销大）+ `NCCL_BUFFSIZE=8M`（管道加深）。
2. **T1aM4 最优**：368KB 423.7µs（-54%），MIN_NCHANNELS 2→4 再贡献 ~5%。**推荐生产配置 = T1aM4**。
3. **T1b 不推荐**：NCHANNELS=8 + QP 分流在环网反而退化（368KB 580µs > T1a 444µs）——通道过多管道变浅，QP 分流在单口受限。
4. **注意小消息退化**：64KB 档 Simple 协议比 LL128 慢 17-30%。decode 步内存在大量小 allreduce（attention/MLP 输出 8KB 级）——**需端到端 bench 验证净收益**（M1 全局 Simple 对小消息的负面影响 vs 368KB 主项收益，用 c1@32K PR/DE 回归判定）。
5. **验证遗留**：本轮为 NCCL 层微基准；端到端回归（Tessa 方案）需生产恢复后执行——M1-M3 的最终保留/回滚由端到端数据裁决。

## 3. 建议生产 env（待端到端验证后定稿）

```bash
# 追加到 start_tp4_head.sh / start_tp4_worker.sh 的 ENV_ARGS
NCCL_PROTO=Simple
NCCL_BUFFSIZE=8388608
NCCL_MIN_NCHANNELS=4
# 不采用：NCCL_NCHANNELS=8 / NCCL_IB_QPS_PER_CONNECTION=2 / NCCL_IB_SPLIT_DATA_ON_QPS=1
```

## 4. 执行记录

- 21:5x-00:0x：A0 → T1a → T1b → T1aM4 四轮实测，每轮四机容器启动+完成约 3.5 分钟
- 障碍与解法：mpirun ORTE 路由失败（03 无 mpirun）→ 改容器 torch.distributed；首次 ibv_modify_qp 110（缺 PEER_HCA）→ 补生产 PEER_HCA 映射后通
- 所有 bench 容器已清理（docker rm -f）；embed（03/04）全程未触碰
- 日志留存：docker logs 已随容器删除；本报告为最终记录
