#!/bin/bash
# ============================================================
# 01 -> 02 双机镜像备份脚本
# 部署: SRE Rex, 2026-08-17
#
# 设计决策:
#   - 不使用 --delete: 02 存在节点级回滚文件 (rollback_tp4-rank1.json、
#     rollback_vllm-envE-worker.json、tp2-worker.json 等), 严格镜像会误删.
#     本脚本为单向备份拷贝 (01 关键资料增量同步到 02), 保留 02 本地特有文件.
#   - 使用 --no-o --no-g: 以 <svc-user> 身份传输, 避免 chown root 权限告警.
#   - 排除 v027-test (8.2G 测试残留, 非关键脚本).
#
# 前提: 01 -> 02 ssh 免密 (<svc-user>), 02 侧目标目录 <svc-user> 可写
# 用法: 在 <node1> 上执行: bash /opt/aicad-prod/scripts/mirror_to_02.sh
# ============================================================
# DOCS: file:///opt/aicad-prod/docs/ops/tools-index.md（01->02 双机镜像备份，SRE Rex 2026-08-17）
set -uo pipefail
DATE=$(date +%Y%m%d_%H%M%S)
LOG="/opt/aicad-prod/scripts/maintenance/mirror.log"
mkdir -p "$(dirname "$LOG")"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "=== mirror start $DATE ==="

# 0) 02 侧预创建目标目录
ssh <node2> 'mkdir -p /opt/aicad-prod/backup /opt/aicad-prod/scripts /opt/aicad-prod/docs /opt/aicad-prod/deliverables' 2>>"$LOG" || true

RSYNC="rsync -a --partial --no-o --no-g --timeout=600"

# 1) /opt/aicad-prod/backup (39G+, 含 nccl-official-* / nccl-2hop-proto-archive / 2hop-s1 tar)
log "syncing backup/ ..."
$RSYNC /opt/aicad-prod/backup/ <node2>:/opt/aicad-prod/backup/

# 2) /opt/aicad-prod/scripts (排除 v027-test 测试残留)
log "syncing scripts/ (exclude v027-test) ..."
$RSYNC --exclude 'v027-test' /opt/aicad-prod/scripts/ <node2>:/opt/aicad-prod/scripts/

# 3) /opt/aicad-prod/docs + deliverables
log "syncing docs/ + deliverables/ ..."
$RSYNC /opt/aicad-prod/docs/ <node2>:/opt/aicad-prod/docs/
$RSYNC /opt/aicad-prod/deliverables/ <node2>:/opt/aicad-prod/deliverables/

# 4) /opt/nccl-ringonly: 两机均已有生产库+锚点, 不做覆盖传输, 由外部 md5 校验确认一致
log "nccl-ringonly: present on both nodes, external md5 verify only"

log "=== mirror done $DATE ==="
