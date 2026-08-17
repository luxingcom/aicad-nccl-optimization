#!/bin/bash
# =============================================================
# SCRIPT: healthcheck-rebuild.sh
# VERSION: v1.0-p1
# ROLE: vLLM TP4 主动重建健康检查 (P1) — 四机
# USAGE: bash healthcheck-rebuild.sh [--role head|worker] [--cooldown SEC]
# 原理: 调用 healthcheck.sh 只读探针; 探针失败 => docker rm -f 本机 vllm 容器
#       触发 monitor docker wait 返回 -> exit 1 -> systemd Restart -> 重建
#       (2026-08-17 fix: 原 systemctl restart 只重启 monitor 不重建容器, 已改)
# 保护: --cooldown 冷却窗口 (默认 1800s), 避免重启风暴; 状态记录于
#       /opt/aicad-prod/state/healthcheck-rebuild.<role>
# 注意: P1 部署留档。是否挂入定时/告警链路由运维决定; 重启演练期间不启用
# EXITCODES: 0=健康或已触发恢复 1=冷却窗口内跳过 2=用法错误
# CHANGE: 改脚本须 bash -n + .bak-<tag> 留档 + 更新 REFERENCE.md
# =============================================================
set -uo pipefail
export HOME=/home/<svc-user>

ROLE=""
COOLDOWN=1800

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --cooldown) COOLDOWN="${2:-1800}"; shift 2 ;;
    -h|--help) grep -E '^# (USAGE|EXITCODES|ROLE)' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ROLE" ]; then
  if [ "$(hostname)" = "<node1>" ]; then ROLE=head; else ROLE=worker; fi
fi

SVC="vllm-tp4-worker.service"
[ "$ROLE" = "head" ] && SVC="vllm-tp4-head.service"

# 1. 先跑只读探针
if bash /opt/aicad-prod/scripts/healthcheck.sh --role "$ROLE"; then
  echo "[healthcheck-rebuild][$ROLE] healthy, 无需干预"
  exit 0
fi

# 2. 冷却窗口判断 (state 文件存最近触发时间戳)
STATE_DIR=/opt/aicad-prod/state
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/healthcheck-rebuild.$ROLE"
NOW=$(date +%s)
LAST=0
[ -f "$STATE" ] && LAST=$(cat "$STATE" 2>/dev/null || echo 0)
if [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
  echo "[healthcheck-rebuild][$ROLE] 冷却窗口内 ($((NOW - LAST))s < ${COOLDOWN}s), 跳过触发" >&2
  exit 1
fi

# 3. 触发主动重建: docker rm -f 本机 vllm 容器
#    (monitor 的 docker wait 返回 -> exit 1 -> systemd Restart -> monitor 重建容器)
echo "$NOW" > "$STATE"
echo "[healthcheck-rebuild][$ROLE] 探针失败, 触发主动重建: docker rm -f 本机 vllm-tp4-rank*"
docker rm -f $(docker ps -aq --filter name=vllm-tp4-rank) 2>/dev/null || true
echo "[healthcheck-rebuild][$ROLE] 已触发容器重建, systemd 自愈接管"
exit 0
