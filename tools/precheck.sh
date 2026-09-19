#!/bin/bash
# =============================================================
# SCRIPT: precheck.sh
# VERSION: v1.0 (2026-09-19)
# ROLE: 四机一致性 + 单机系统层预检（P0，只读，fail-closed）
#       覆盖实录坑：#1(拓扑前置一致性) #2/#7(内核与GRUB) #3(DKMS+SecureBoot)
#       #5(锁频单元写坏) #6(systemd 权限)；错误 2(vLLM能跑≠ring可用)、错误 6(物理层优先)
# USAGE:
#   bash precheck.sh                       # 本机检查
#   bash precheck.sh --ips ip1,ip2,ip3,ip4 # 四机一致性检查（经 ssh）
#   bash precheck.sh --expect-kernel 6.17.0-1032-nvidia --expect-driver 580.178.04
#   bash precheck.sh --svc-user admin --svc vllm-tp4-head.service
# EXITCODES: 0=全部通过 1=存在失败项（fail-closed：宁报勿漏） 2=用法错误
# NOTE: 本脚本只读不改任何配置。所有 FAIL 项必须人工处置后重跑至 0。
# CHANGE: 改脚本须 bash -n + .bak-<tag> 留档 + 更新 tools/README.md
# =============================================================
set -uo pipefail

EXPECT_KERNEL=""
EXPECT_DRIVER=""
EXPECT_MTU="9000"
SVC_USER=""
SVC_NAME="vllm-tp4-head.service"
IPS=""
SSH_USER=""

usage() { grep -E '^# (USAGE|EXITCODES|NOTE)' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-kernel) EXPECT_KERNEL="${2:-}"; shift 2 ;;
    --expect-driver) EXPECT_DRIVER="${2:-}"; shift 2 ;;
    --expect-mtu)    EXPECT_MTU="${2:-9000}"; shift 2 ;;
    --svc-user)      SVC_USER="${2:-}"; shift 2 ;;
    --svc)           SVC_NAME="${2:-vllm-tp4-head.service}"; shift 2 ;;
    --ips)           IPS="${2:-}"; shift 2 ;;
    --ssh-user)      SSH_USER="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

# ---------- 在单台机器上执行检查（本机或经 ssh） ----------
run_checks() {
  # 通过 $RUN 前缀执行：本机为空串，远端为 "ssh ... bash -c"
  local HOST="$1"; shift
  local FAIL=0
  local RUN_DESC="$1"; shift
  local RUN_CMD="$1"

  r() {  # r "<说明>" <命令...>
    local desc="$1"; shift
    local out
    if out=$("$RUN_CMD" "$@" 2>&1); then
      echo "[precheck][$HOST] ok $desc: $(echo "$out" | head -2 | tr '\n' ' ')"
    else
      echo "[precheck][$HOST] x $desc: $(echo "$out" | head -3 | tr '\n' ' ')"
      FAIL=1
    fi
  }

  warn() { echo "[precheck][$HOST] ! $*"; }

  echo "===== [precheck] 开始检查 $HOST ====="

  # --- 1. 内核 ---
  local KERN
  KERN=$("$RUN_CMD" uname -r 2>&1)
  if [ -n "$EXPECT_KERNEL" ]; then
    if [ "$KERN" = "$EXPECT_KERNEL" ]; then
      echo "[precheck][$HOST] ok 内核 = $KERN（符合期望）"
    else
      echo "[precheck][$HOST] x 内核 = $KERN ≠ 期望 $EXPECT_KERNEL（实录坑2：错误内核致 ibv_reg_mr ENOMEM）"
      FAIL=1
    fi
  else
    echo "[precheck][$HOST] -- 内核 = $KERN（未设期望值，仅记录）"
  fi

  # --- 2. 驱动 ---
  local DRV
  DRV=$("$RUN_CMD" nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 | head -1)
  if [ -n "$EXPECT_DRIVER" ]; then
    if [ "$DRV" = "$EXPECT_DRIVER" ]; then
      echo "[precheck][$HOST] ok 驱动 = $DRV"
    else
      echo "[precheck][$HOST] x 驱动 = $DRV ≠ 期望 $EXPECT_DRIVER"
      FAIL=1
    fi
  else
    echo "[precheck][$HOST] -- 驱动 = $DRV"
  fi

  # --- 3. GRUB_DEFAULT 固化（坑7：grub-reboot 一次性） ---
  local GRUB
  GRUB=$("$RUN_CMD" grep -E '^GRUB_DEFAULT=' /etc/default/grub 2>&1)
  case "$GRUB" in
    *'"'*)  echo "[precheck][$HOST] ok GRUB_DEFAULT 已固化: $GRUB" ;;
    *)      echo "[precheck][$HOST] x GRUB_DEFAULT 未固化/异常: '$GRUB'（实录坑7：grub-reboot 只生效一次，重启即回退；须 GRUD_DEFAULT=\"1>2\" 数字索引）"; FAIL=1 ;;
  esac
  # grubenv 残留 next_entry
  if "$RUN_CMD" sh -c 'grub-editenv /boot/grub/grubenv list 2>/dev/null | grep -q next_entry'; then
    echo "[precheck][$HOST] x grubenv 残留 next_entry（一次性启动覆盖仍生效，须 unset）"
    FAIL=1
  fi

  # --- 4. DKMS 隔离检查（坑3：updates/dkms 自签模块 + Secure Boot = GPU 消失） ---
  if "$RUN_CMD" sh -c 'test -d /lib/modules/$(uname -r)/updates/dkms'; then
    echo "[precheck][$HOST] x 存在 /lib/modules/\$(uname -r)/updates/dkms（优先级高于 kernel/；Secure Boot 下自签模块会致 GPU 消失，实录坑3。须 mv 隔离 + depmod -a + update-initramfs -u）"
    FAIL=1
  else
    echo "[precheck][$HOST] ok 无 updates/dkms 残留"
  fi
  if "$RUN_CMD" sh -c 'dkms status 2>/dev/null | grep -q .'; then
    warn "存在 DKMS 模块：$( "$RUN_CMD" dkms status 2>&1 | head -2 | tr '\n' ' ')（确认是否为历史残留）"
  fi
  # 模块签名者
  local SIGNER
  SIGNER=$("$RUN_CMD" sh -c 'modinfo -k $(uname -r) nvidia 2>/dev/null | grep -i ^signer' 2>&1)
  if echo "$SIGNER" | grep -qi "Canonical"; then
    echo "[precheck][$HOST] ok nvidia.ko 签名: $(echo "$SIGNER" | head -1)"
  else
    echo "[precheck][$HOST] x nvidia.ko 签名异常: $(echo "$SIGNER" | head -1)（须 Canonical Ltd.；自签=DKMS 残留）"
    FAIL=1
  fi

  # --- 5. RoCE 口状态 + MTU（坑1 前置） ---
  local IB_DEV STATE DEV MTU_VAL
  IB_OK=1
  for DEV in $("$RUN_CMD" sh -c 'ls /sys/class/infiniband 2>/dev/null' 2>&1); do
    STATE=$("$RUN_CMD" cat "/sys/class/infiniband/$DEV/ports/1/state" 2>&1)
    if echo "$STATE" | grep -q "4: ACTIVE"; then
      echo "[precheck][$HOST] ok $DEV ACTIVE"
    else
      echo "[precheck][$HOST] x $DEV state: $(echo "$STATE" | head -1)（非 ACTIVE）"
      IB_OK=0
    fi
  done
  [ $IB_OK = 0 ] && FAIL=1
  # MTU（取第一个 RoCE 以太对应口）
  MTU_VAL=$("$RUN_CMD" sh -c 'for d in /sys/class/infiniband/*/device/net/*; do cat $d/mtu; break; done' 2>&1)
  if [ "$MTU_VAL" = "$EXPECT_MTU" ]; then
    echo "[precheck][$HOST] ok RoCE MTU = $MTU_VAL"
  else
    echo "[precheck][$HOST] x RoCE MTU = $MTU_VAL ≠ $EXPECT_MTU（四机必须一致 9000）"
    FAIL=1
  fi

  # --- 6. GPU 锁频单元（坑5：ExecStart 断行 = 只跑 nvidia-smi 无参数） ---
  local EXEC_LINE
  EXEC_LINE=$("$RUN_CMD" sh -c "systemctl cat *.service 2>/dev/null | grep -h 'ExecStart=/usr/bin/nvidia-smi\|ExecStart=/bin/bash -c nvidia-smi' | head -3" 2>&1)
  if echo "$EXEC_LINE" | grep -qE "nvidia-smi -lgc [0-9]+,[0-9]+"; then
    echo "[precheck][$HOST] ok 锁频单元单行带参数: $(echo "$EXEC_LINE" | head -1)"
  elif [ -n "$EXEC_LINE" ]; then
    echo "[precheck][$HOST] x 锁频单元 ExecStart 可疑（可能断行/无参数）: $(echo "$EXEC_LINE" | head -2 | tr '\n' ' ')（实录坑5：断行致锁频从未生效，GPU 跑 208MHz）"
    FAIL=1
  else
    warn "未发现 nvidia-smi 锁频单元（若需 rank 平衡锁频请部署 admin-clock-cap.service）"
  fi
  # 实际时钟
  local CLOCKS
  CLOCKS=$("$RUN_CMD" nvidia-smi --query-gpu=clocks.sm --format=csv,noheader 2>&1 | head -1)
  echo "[precheck][$HOST] -- 当前 SM 时钟: $CLOCKS"

  # --- 7. systemd 单元权限（坑6：root 建的日志文件 User= 写不进） ---
  if [ -n "$SVC_USER" ]; then
    local UNIT_USER
    UNIT_USER=$("$RUN_CMD" sh -c "systemctl show $SVC_NAME -p User 2>/dev/null" 2>&1 | cut -d= -f2)
    if [ "$UNIT_USER" = "$SVC_USER" ]; then
      echo "[precheck][$HOST] ok $SVC_NAME User=$UNIT_USER"
      # 日志目录可写性
      local LOGDIRS
      LOGDIRS=$("$RUN_CMD" sh -c "systemctl cat $SVC_NAME 2>/dev/null | grep -oE 'append:[^ ]+' | sed 's/append://' | head -4" 2>&1)
      for d in $LOGDIRS; do
        local DD=$(dirname "$d")
        if "$RUN_CMD" sh -c "sudo -u $SVC_USER test -w $DD 2>/dev/null || test -w $DD" 2>/dev/null; then
          echo "[precheck][$HOST] ok 日志目标可写: $DD"
        else
          echo "[precheck][$HOST] x 日志目标 User=$SVC_USER 不可写: $DD（实录坑6：root 建文件→自愈静默失灵。修法：PermissionsStartOnly=yes + ExecStartPre chown）"
          FAIL=1
        fi
      done
    else
      echo "[precheck][$HOST] x $SVC_NAME User=$UNIT_USER ≠ $SVC_USER"
      FAIL=1
    fi
  fi

  echo "===== [precheck] $HOST 完成（$([ $FAIL = 0 ] && echo PASS || echo FAIL)） ====="
  return $FAIL
}

# ---------- 执行入口 ----------
FAILED=0
if [ -n "$IPS" ]; then
  IFS=',' read -ra HOSTS <<< "$IPS"
  for h in "${HOSTS[@]}"; do
    if ! run_checks "$h" "ssh" ssh ${SSH_USER:+$SSH_USER@}$h bash; then
      FAILED=1
    fi
  done
else
  if ! run_checks "$(hostname)" local bash; then
    FAILED=1
  fi
fi

if [ $FAILED = 0 ]; then
  echo "[precheck] ✅ 全部通过"
else
  echo "[precheck] ❌ 存在失败项 —— 对照 docs/ops/troubleshooting-playbook.md 对应条目处置后重跑"
fi
exit $FAILED
