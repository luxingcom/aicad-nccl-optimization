#!/usr/bin/env bash
# Hairpin pre-condition on this fleet's 6.17-nvidia kernel: mlx5 refuses tc hairpin rules
# unless the port's priority trust state is PCP ("only PCP trust state supported for hairpin").
# The fleet was hardened to trust=dscp (NCCL_IB_TOS=46 -> prio5 lossless); flipping to pcp maps
# untagged traffic to prio 0 instead (PFC 3/5 stay configured but idle). Idempotent; the engine
# must be down only for the hairpin re-init, not for this call.
set -euo pipefail
for n in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
  cur=$(mlnx_qos -i "$n" 2>/dev/null | sed -n 's/^Priority trust state: //p')
  [[ "$cur" == "pcp" ]] && { echo "  $(hostname) $n: already pcp"; continue; }
  mlnx_qos -i "$n" --trust=pcp >/dev/null
  echo "  $(hostname) $n: trust $cur -> pcp"
done
