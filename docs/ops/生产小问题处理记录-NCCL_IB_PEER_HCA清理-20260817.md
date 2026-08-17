# 生产小问题处理记录：NCCL_IB_PEER_HCA 清理 + systemd 自恢复核验

- 日期: 2026-08-17
- 作者: SRE 工程师 Rex
- 状态: 脚本清理已留档, 未重启生产 (下次部署窗口生效)

## 1. NCCL_IB_PEER_HCA 脚本清理

背景: 该 env 已被 NCCL 库忽略 (ADR 记录弃用), 从生产启动脚本中移除, 纯清理, 无功能影响。

### 执行动作 (四机)
| 节点 | 文件 | 行号(原) | 动作 | .bak 留档 | bash -n |
|------|------|---------|------|----------|---------|
| <node1> | /opt/aicad-prod/scripts/start_tp4_head.sh | L122 | 删除 `NCCL_IB_PEER_HCA=...` env 行 | start_tp4_head.sh.bak-sre-peerhca-clean-20260817 | 通过 |
| <node2> | /opt/aicad-prod/scripts/start_tp4_worker.sh | L127 | 删除 `-e "NCCL_IB_PEER_HCA=${PEER_HCA}"` 行 | start_tp4_worker.sh.bak-sre-peerhca-clean-20260817 | 通过 |
| <node3> | /opt/aicad-prod/scripts/start_tp4_worker.sh | L127 | 同上 | 同上 | 通过 |
| <node4> | /opt/aicad-prod/scripts/start_tp4_worker.sh | L127 | 同上 | 同上 | 通过 |

验证: 新文件 grep -c NCCL_IB_PEER_HCA = 0; 原 .bak = 1; 行数 192→191 恰好删 1 行。

### 说明
- worker 脚本中 PEER_HCA 变量 case 块 (L78-82) 现为死代码, 保留留档 (不删, 防误恢复; 后续可再清)。
- **未重启生产容器** — 改动在下次部署窗口 (容器重建/重启) 时随新脚本生效。
- 其他变体脚本 (start_tp4_head_b12x/combo/cutlass/deepgemm/marlin/nvfp4weight, start_sglang_*) 非当前生产路径, 未动, 记录在案。

## 2. systemd 自恢复核验 (持久化自恢复基础)
| 节点 | 服务 | ExecStart | Restart | RestartSec | 状态 |
|------|------|-----------|---------|------------|------|
| <node1> | vllm-tp4-head.service | /opt/aicad-prod/scripts/monitor_tp4_head.sh | always | 15 | active (running), enabled |
| <node2> | vllm-tp4-worker.service | /opt/aicad-prod/scripts/monitor_tp4_worker.sh | always | 15 | active (running), enabled |
| <node3> | vllm-tp4-worker.service | /opt/aicad-prod/scripts/monitor_tp4_worker.sh | always | 15 | active (running), enabled |
| <node4> | vllm-tp4-worker.service | /opt/aicad-prod/scripts/monitor_tp4_worker.sh | always | 15 | active (running), enabled |

结论: Restart=always + RestartSec=15 + 服务 enabled, 进程异常退出由 systemd 自动拉起, 自恢复机制完整。
