#!/bin/bash
# 生产环境临时文件与日志自动维护 (每周日 03:30, root crontab)
# 部署: SRE Rex, 2026-08-17
# 内容: /tmp 清理 + verification-logs 清理 + docker dangling 镜像清理
LOG="/var/log/vllm/maintenance.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "=== maintenance start ==="

# 1) /tmp 普通文件 >30 天清理 (排除系统私有目录由 find maxdepth 1 天然规避)
find /tmp -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null || true

# 2) /tmp 已知测试残留目录 >30 天清理 (绝不删 systemd-private/snap-private/nvidia)
find /tmp -maxdepth 1 -type d -mtime +30 \
  \( -name 'v027*' -o -name 'v026*' -o -name 'nccl-*' -o -name 'fi015*' -o -name 'fi016*' \) \
  -exec rm -rf {} + 2>/dev/null || true

# 3) verification-logs 产物 >30 天清理
find /opt/aicad-prod/verification-logs -type f -mtime +30 -delete 2>/dev/null || true
find /opt/aicad-prod/verification-logs -type d -mtime +30 -empty -delete 2>/dev/null || true

# 4) docker dangling (untagged) 镜像清理
docker image prune -f >/dev/null 2>&1 || true

log "=== maintenance done ==="
