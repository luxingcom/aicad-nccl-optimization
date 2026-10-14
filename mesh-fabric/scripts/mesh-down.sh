#!/usr/bin/env bash
# Removes exactly what mesh-up.sh creates.
set -uo pipefail
systemctl stop 'dsv41-mesh-marker@*' 2>/dev/null || true
tc filter del dev enP2p1s0f0np0 ingress pref 49159 protocol 0x88b5 handle 49159 flower 2>/dev/null || true
tc filter del dev enP2p1s0f1np1 ingress pref 49165 protocol 0x88b5 handle 49165 flower 2>/dev/null || true
[ -z "$(tc filter show dev enP2p1s0f0np0 ingress; tc filter show dev enP2p1s0f0np0 egress)" ] && tc qdisc del dev enP2p1s0f0np0 clsact 2>/dev/null || true
[ -z "$(tc filter show dev enP2p1s0f1np1 ingress; tc filter show dev enP2p1s0f1np1 egress)" ] && tc qdisc del dev enP2p1s0f1np1 clsact 2>/dev/null || true
ip route del 10.100.138.3/32 2>/dev/null || true
ip route del 10.20.0.14/32 2>/dev/null || true
echo mesh-down done
