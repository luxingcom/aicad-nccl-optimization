#!/bin/bash
# =============================================================
# SCRIPT: doctor.sh
# VERSION: v1.0 (2026-09-19)
# ROLE: 运行期全量体检（P0，容器 + 网络配置 + 鉴权 + 错误签名扫描）
#       覆盖实录坑：#4(NCCL_DEBUG_FILE 落到未挂载路径=日志静默丢失)
#       #9(.env 键名不透传,须看容器真实 env) #10(API_KEY 四机同值)
#       错误 4(LD_PRELOAD 路径不存在=静默跳过,须显式验证库真被加载)
#       错误 5(带宽 108.5 是 GB10 单口上限非降级)
# USAGE:
#   bash doctor.sh                              # 本机容器检查
#   bash doctor.sh --container vllm-tp4-rank0   # 指定容器
#   bash doctor.sh --api-endpoint http://127.0.0.1:8899 --api-key-file ~/state-tp4/api-key
#   bash doctor.sh --ips ip1,ip2,ip3,ip4        # 四机巡检（经 ssh）
# EXITCODES: 0=全部通过 1=存在失败项 2=用法错误
# NOTE: 只读（不重启容器、不改配置）；唯一外呼是 --api-endpoint 的 GET /v1/models。
# CHANGE: 改脚本须 bash -n + .bak-<tag> 留档 + 更新 tools/README.md
# =============================================================
set -uo pipefail

CONTAINER=""
IPS=""
SSH_USER=""
API_ENDPOINT=""
API_KEY_FILE=""
API_KEY_ENV=""

usage() { grep -E '^# (USAGE|EXITCODES|NOTE)' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --container)    CONTAINER="${2:-}"; shift 2 ;;
    --ips)          IPS="${2:-}"; shift 2 ;;
    --ssh-user)     SSH_USER="${2:-}"; shift 2 ;;
    --api-endpoint) API_ENDPOINT="${2:-}"; shift 2 ;;
    --api-key-file) API_KEY_FILE="${2:-}"; shift 2 ;;
    --api-key-env)  API_KEY_ENV="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

FAIL=0
ok()   { echo "[doctor] ok $*"; }
bad()  { echo "[doctor] x $*"; FAIL=1; }
info() { echo "[doctor] -- $*"; }

# ---------- 远程模式：逐机跑本脚本 ----------
if [ -n "$IPS" ]; then
  HERE=$(cd "$(dirname "$0")" && pwd)
  IFS=',' read -ra HOSTS <<< "$IPS"
  for h in "${HOSTS[@]}"; do
    echo "===== [doctor] 远程检查 $h ====="
    scp -q "$HERE/doctor.sh" ${SSH_USER:+$SSH_USER@}$h:/tmp/aicad-doctor.sh \
      && ssh ${SSH_USER:+$SSH_USER@}$h "bash /tmp/aicad-doctor.sh --container ${CONTAINER:-auto}; rc=\$?; rm -f /tmp/aicad-doctor.sh; exit \$rc" \
      || FAIL=1
  done
  [ $FAIL = 0 ] && echo "[doctor] ✅ 四机巡检通过" || echo "[doctor] ❌ 存在失败项"
  exit $FAIL
fi

# ---------- 自动探测容器 ----------
if [ -z "$CONTAINER" ] || [ "$CONTAINER" = "auto" ]; then
  CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'vllm|sglang|rank' | head -1)
  [ -z "$CONTAINER" ] && { echo "[doctor] x 未发现运行中的推理容器（vllm/sglang/rank*）" >&2; exit 1; }
  info "自动选定容器: $CONTAINER"
fi

echo "===== [doctor] 容器 $CONTAINER ====="

# 1. 容器运行态
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  ok "容器运行中: $(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}')"
else
  bad "容器不在运行"
fi

# 2. 容器真实 env（坑9：.env 键名≠容器 env，以 docker inspect 为准）
NCCL_DEBUG_FILE_VAL=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^NCCL_DEBUG_FILE=' | cut -d= -f2-)
LD_PRELOAD_VAL=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^LD_PRELOAD=' | cut -d= -f2-)
API_KEY_SET=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -cE '^API_KEY=')
info "容器真实 env 摘要: NCCL_DEBUG_FILE=${NCCL_DEBUG_FILE_VAL:-<未设>} | LD_PRELOAD=${LD_PRELOAD_VAL:-<未设>} | API_KEY=$([ "$API_KEY_SET" -ge 1 ] && echo 已注入 || echo 未注入)"

# 3. NCCL_DEBUG_FILE 落点必须已挂载（坑4：落到未挂载路径=调试输出静默全丢）
if [ -n "$NCCL_DEBUG_FILE_VAL" ]; then
  DIR_IN_CONT=$(dirname "$NCCL_DEBUG_FILE_VAL")
  if docker exec "$CONTAINER" sh -c "test -d $DIR_IN_CONT && test -w $DIR_IN_CONT" 2>/dev/null; then
    ok "NCCL_DEBUG_FILE 落点容器内可写: $DIR_IN_CONT"
  else
    bad "NCCL_DEBUG_FILE 落点 $DIR_IN_CONT 在容器内不存在/不可写 —— 调试输出会静默全丢（实录坑4）。改到已挂载路径（如 /state）"
  fi
else
  info "NCCL_DEBUG_FILE 未设置（排障时务必临时设置到已挂载路径）"
fi

# 4. LD_PRELOAD 每个路径都必须真实存在且可加载（错误4：路径不存在 glibc 静默跳过不报错）
if [ -n "$LD_PRELOAD_VAL" ]; then
  IFS=' ' read -ra PRELOADS <<< "$LD_PRELOAD_VAL"
  for p in "${PRELOADS[@]}"; do
    if docker exec "$CONTAINER" sh -c "test -f $p" 2>/dev/null; then
      ok "LD_PRELOAD 路径存在: $p"
      # 若是 nccl 库，校验 md5 与挂载
      if echo "$p" | grep -q nccl; then
        MD5=$(docker exec "$CONTAINER" md5sum "$p" 2>/dev/null | awk '{print $1}')
        info "  md5($p) = ${MD5:-<取不到>}"
      fi
    else
      bad "LD_PRELOAD 路径不存在: $p —— glibc 会静默跳过，库从未被加载（错误4）。vLLM 跑通≠ring-only 可用"
    fi
  done
else
  info "LD_PRELOAD 未设置"
fi

# 5. NCCL 版本 banner（LD_PRELOAD 是否真生效的旁证）
BANNER=$(docker logs "$CONTAINER" 2>&1 | grep -m1 -E 'NCCL version' || true)
if [ -n "$BANNER" ]; then
  info "NCCL banner: $(echo "$BANNER" | head -1)"
else
  bad "容器日志无 NCCL version banner —— 库可能未被加载或日志被轮转"
fi

# 6. RING-ONLY 日志模式（v4/v5 库生效的铁证）
RING_LOGS=$(docker logs "$CONTAINER" 2>&1 | grep -c 'RING-ONLY' || true)
if [ "${RING_LOGS:-0}" -ge 1 ]; then
  ok "RING-ONLY 日志 $RING_LOGS 条（定制库在生效）"
  docker logs "$CONTAINER" 2>&1 | grep -m3 'RING-ONLY' | sed 's/^/[doctor]     /'
else
  bad "0 条 RING-ONLY 日志 —— 定制库未生效（对照错误4：LD_PRELOAD 静默跳过 / 或用的根本不是定制库）"
fi

# 7. 错误签名扫描（坑1/2/坑110 等典型签名）
LOG=$(docker logs "$CONTAINER" 2>&1 | tail -2000)
echo "$LOG" | grep -q 'ibv_modify_qp failed with 110' && bad "命中: ibv_modify_qp 110 —— 环网接线与库内映射不符（坑1，先跑 probe_ring_topology.sh 实测拓扑）"
echo "$LOG" | grep -q 'wrap_ibv_reg_mr_iova2.*Cannot allocate memory\|reg_mr.*ENOMEM' && bad "命中: ibv_reg_mr ENOMEM —— 内核版本问题（坑2，回退已验证内核）"
echo "$LOG" | grep -qi 'NCCL WARN' || info "无 NCCL WARN（注意：若 NCCL_DEBUG_FILE 落点坏，WARN 会静默丢失，看第 3 项）"
echo "$LOG" | grep -qi 'unhandled system error' && bad "命中: NCCL unhandled system error —— 对照 troubleshooting-playbook.md #1"

# 8. API 探测
KEY=""
if [ -n "$API_KEY_FILE" ] && [ -f "$API_KEY_FILE" ]; then KEY=$(tr -d '\r\n' < "$API_KEY_FILE"); fi
if [ -n "$API_KEY_ENV" ] && [ -n "${!API_KEY_ENV:-}" ]; then KEY="${!API_KEY_ENV}"; fi
if [ -n "$API_ENDPOINT" ]; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$API_ENDPOINT/v1/models" ${KEY:+-H "Authorization: Bearer $KEY"} 2>/dev/null || echo 000)
  if [ "$CODE" = "200" ]; then
    ok "API /v1/models = 200"
  elif [ "$CODE" = "401" ]; then
    bad "API = 401 —— 鉴权失败：API_KEY 未带/不一致（坑10：四机必须同值）"
  else
    bad "API = $CODE（000=连不上）"
  fi
  # 无 key 应 401（鉴权层在线）
  CODE_NOKEY=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$API_ENDPOINT/v1/models" 2>/dev/null || echo 000)
  if [ "$CODE_NOKEY" = "401" ]; then ok "无 key 访问 = 401（鉴权层正常）"; else info "无 key 访问 = $CODE_NOKEY（若服务要求鉴权则此项应为 401）"; fi
fi

# 9. API_KEY 四机同值只能由 head 与各 worker 容器 env 哈希比对——此处输出本机值指纹供人工比对
if [ "$API_KEY_SET" -ge 1 ]; then
  KEYFP=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^API_KEY=' | md5sum | awk '{print substr($1,1,8)}')
  info "本机 API_KEY 指纹: $KEYFP（四机跑本脚本，指纹必须一致；不一致=坑10）"
fi

[ $FAIL = 0 ] && echo "[doctor] ✅ 通过" || echo "[doctor] ❌ 存在失败项 —— 对照 docs/ops/troubleshooting-playbook.md"
exit $FAIL
