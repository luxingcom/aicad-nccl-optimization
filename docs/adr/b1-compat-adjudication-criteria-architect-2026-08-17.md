# B1 兼容性判读口径（NCCL_MAX_NCHANNELS 16→4 实测验收判据）

**日期**：2026-08-17
**作者**：Archi（系统架构师）
**对象**：Rex（SRE）——B1 固化后的实测校验
**依据**：ADR-015 S1.14 / `nccl-ab-B-execution-report-2026-08-17.md`
**前置**：B1 已固化生产（MAX_NCHANNELS=4，四机脚本已改，集群 healthy）；库 2be94172 未变

---

## 目的

B1 变更**仅**改 `NCCL_MAX_NCHANNELS` 16→4（env 层），库与其余 env 均未变。本口径用于在 B1 环境下实测 tuner / libncclpin / healthcheck / 368KB 时逐项判读，确认：
1. per-size tuner 路由不受通道数变更影响（≤40KB→LL 仍成立）；
2. 大消息收益兑现（112KB/224KB 快速、368KB 外推接受区间）；
3. 连接层 / shim / 库完整性无回归。

## 判读口径（逐项）

| # | 校验项 | 期望（通过判据） | dev 指示（需排查） |
|---|---|---|---|
| 1 | tuner 路由（nccl-tests 各尺寸） | **≤40KB → LL**（14KB 应 LL，且 ≤40KB 全部 LL）；**>40KB → Simple** | 14KB 走 LL128/Simple 或 40KB 边界路由错乱 → tuner 兼容性问题 |
| 2 | 112KB allreduce | **Simple + 4ch 快速**：预期 ~83µs（±10% 噪声带 ≈ 75-91µs） | >95µs（接近 B0 126µs）→ 4ch 未生效或回落 16ch |
| 3 | 368KB allreduce（外推） | **接受区间 120-130µs**（介于 112/224 之间外推；比 MAX_CH16 基线 173µs 更好） | >150µs 且稳定 → 大消息收益未兑现；<100µs 异常（需复核方法） |
| 4 | 通道数（NCCL_DEBUG 日志） | 每 rank channel 数 = 4（非 16）；RING-ONLY 日志正常 | 显示 16 channel → MAX_NCHANNELS env 未生效 |
| 5 | 连接层 | 无 `ibv_modify_qp 110`；netDev 轮换（devA/devB）正常；与 v3/2be94172 行为一致 | 任何 110 / 连接失败 → 库或 env 冲突 |
| 6 | 库 md5 | 四机 `/opt/nccl-ringonly/libnccl.so.2.30.7` = `2be94172...`（未变）；容器内加载库一致 | md5 漂移 → 库部署异常 |
| 7 | libncclpin shim | NCCL 线程 → 8-9；EngineCore → 15-19；LD_PRELOAD 双库生效 | PSR 漂移 / 单库加载 → shim 兼容性问题 |
| 8 | healthcheck / 收敛 | `/health` 200；四机容器 healthy；启动收敛 ≤6min | 非 200 / 收敛超时 / 容器 unhealthy → 回滚路径 |
| 9 | vLLM 端到端 | c1@131K DE ≥ 基线（~100+）、PR/TTFT 持平 | DE 显著 < 基线 → 需复测 + 判因 |

## 结论判定

- **① 全部通过** → B1 兼容性确认，最终性能基线 v2.0（B1）可定版。
- **② 任一 dev** → 先查 env/脚本（`.bak-ncclB1` diff 核对 MAX_NCHANNELS 是否生效），再查库 md5 / 连接日志。
- **③ 持续 dev** → 回滚 MAX_CH16（还原 `.bak-ncclB1` + `start_tp4_cluster.sh`，~8min）并复盘。

## 参考命令（判读辅助）

```bash
# 通道数（容器内 NCCL_DEBUG 日志）
ssh node1 'grep -c "Channel" ~/vllm-logs/nccl-*.log 2>/dev/null'   # 期望 ≈4×N
# 库 md5
for h in node1 node2 node3 node4; do ssh $h 'md5sum /opt/nccl-ringonly/libnccl.so.2.30.7 | cut -c1-8'; done   # 期望 2be94172 一致
# 脚本 env 核查
ssh node1 'grep -n "NCCL_MAX_NCHANNELS" /opt/aicad-prod/scripts/start_tp4_head.sh'  # 期望 =4
# 健康
curl -s -o /dev/null -w '%{http_code}\n' http://<LAN-IP>:8001/health   # 期望 200
```
