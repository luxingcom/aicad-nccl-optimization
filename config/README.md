# config/ — 环境参数基线（生产快照）

> 采集：2026-08-17 现场 `docker inspect vllm-tp4-rank0` + `/opt/aicad-prod/scripts/start_tp4_head.sh` + `systemctl cat` + `/etc/docker/daemon.json`。
> 权威来源：服务器 `/opt/aicad-prod/`（本目录为可复现快照；**不含 secrets/vllm.env**，API key 由 systemd EnvironmentFile 引用）。

## 文件清单

| 文件 | 内容 |
|---|---|
| `production-nccl-env.md` | **NCCL 环境参数基线**：全部 NCCL_* 环境变量、含义、历史对照、生产库 md5（建议先读） |
| `daemon.json` | Docker 守护进程配置（四机统一：json-file / max-size=100m / max-file=5，P1 治理） |
| `vllm-tp4-head.service` | systemd 单元（head/rank0，<node1>），含 P1 Wants=docker.service |
| `vllm-tp4-worker.service` | systemd 单元（worker/rank1-3，<node2>/03/04）参考模板 |
| `vllm-healthcheck.service-timer.md` | 自恢复健康探针 systemd oneshot + timer（60s 周期，cooldown 1800s） |

## 关键参数速览

| 参数 | 值 | 说明 |
|---|---|---|
| 算法 | `NCCL_ALGO=RING` | ring-only 定制库（库内硬编码） |
| 通道 | MIN_CH4 / MAX_CH4（B1：16→4）/ BUFFSIZE 8M | T1aM4 + B1 组合（2026-08-17 B1 固化，取代 MAX_CH16） |
| tuner | `NCCL_TUNER_THRESHOLD=40960` + `NCCL_NET_PLUGIN=none` | per-size：≤40KB→LL / >40KB→Simple；禁用外部 tuner 防劫持 |
| IB | HCA 4 口 / GID=3 / MERGE_NICS=0 / TOS=46 | 双口 ×2，P2 硬编码映射（ADR-015） |
| 自愈 | systemd Restart=always + healthcheck timer 60s | StartLimit 1800s/20，cooldown 1800s |

> ⚠️ 脱敏说明：本目录不包含任何明文密码/API key；`secrets/vllm.env` 为服务器 600 root:root 私有文件，不在资料包内。
