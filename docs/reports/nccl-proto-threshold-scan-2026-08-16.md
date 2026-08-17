# NCCL 协议 per-size 阈值扫描（LL vs Simple，容器实测）

**日期**：2026-08-16 02:00 (UTC+8)
**执行**：主理人（四机 sglang 容器 + ring-only 库，免停机）
**脚本**：nccl_scan.py（10 尺寸全扫）+ nccl_32k.py（24-57KB 阈值细扫）
**基线 env**：T1aM4（Simple + MIN_CH 4 + BUFFSIZE 8M + PEER_HCA + GID=3），仅切换 NCCL_PROTO

---

## 1. 全尺寸对比（p50 µs）

| size | Simple | LL | 判定 |
|---|---|---|---|
| 1KB | 54.5 | (首轮未采集) | — |
| 4KB | 62.7 | 44.6 | **LL -29%** ✅ |
| 8KB | 67.3 | 48.6 | **LL -28%** ✅ |
| 16KB | 82.1 | 54.3 | **LL -34%** ✅ |
| 24KB | 104.2 | 89.8 | **LL -14%** ✅ |
| 32KB | 123.4 | 112.4 | **LL -9%** ✅ |
| 40KB | 145.5 | 139.3 | 持平 |
| 48KB | 172.8 | 174.0 | 持平 |
| 56KB | 196.3 | 228.8 | **Simple 优** ❌ |
| 64KB | 241 | 321 | Simple 优 ❌ |
| 131KB | 240 | 1315 | Simple 优（LL 爆）❌ |
| 368KB | 173 | 3414 | Simple 必须（LL 爆）❌ |
| 512KB | 198 | 4585 | Simple 必须 ❌ |
| 1MB | 315 | 6919 | Simple 必须 ❌ |

## 2. 结论

1. **per-size 协议 tuner 实证成立**：小消息（≤32KB）LL 快 9-34%，大消息（≥48KB）Simple 快，翻转点在 **~40KB**
2. **87 次/step 小消息主战场（1-16KB）LL 快 28-34%** → 每 step 通信理论可再降 ~30%
3. LL 在大消息（≥64KB）爆炸（131KB +448%、368KB 20×）——**绝不能全局切 LL**，必须 per-size 选择
4. 阈值建议：**≤32KB 走 LL，≥48KB 走 Simple**（40KB 为过渡区，可任选侧）

## 3. 实施路径（待 Archi 细化确认）

- **NCCL tuner 插件**（NCCL_TUNER_PLUGIN，2.30.7 支持情况待确认）或
- **vLLM 层 custom allreduce 扩展**（communication_op.py 预留位）：<32KB 走 LL、≥48KB 走 NCCL Simple
- 风险：LL 禁 GPUDirect RDMA（走 host），GB10 UMA 理论上抵消（Archi 判断），需实测 + CUDA graph 兼容性

## 4. 环境

- 测试容器已全部清理；生产四机 vllm-tp4 全程 healthy（T1aM4 配置运行中）
- 本轮为纯容器 NCCL 层测试，未碰生产
