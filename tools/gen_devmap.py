#!/usr/bin/env python3
# =============================================================
# SCRIPT: gen_devmap.py
# VERSION: v1.1 (2026-09-19)
# ROLE: 从实测物理环网拓扑生成 NCCL_RING_DEV_MAP / ring-devmap.json（配合 v5 补丁，ADR-016）
# USAGE:
#   python3 gen_devmap.py --topology topology.json              # 打印 NCCL_RING_DEV_MAP + ring-devmap.json
#   python3 gen_devmap.py --topology topology.json --json-only  # 只写 ring-devmap.json（当前目录）
#   python3 gen_devmap.py --topology topology.json --verify     # 只校验拓扑合法性
#   python3 gen_devmap.py --default                             # 打印库内建 v4 默认表（自检）
# EXITCODES: 0=成功 1=拓扑非法 2=用法错误
# -------------------------------------------------------------
# topology.json 格式（由 probe_ring_topology.sh 实测产出，或按接线手写）：
# {
#   "ring_order": [0, 1, 2, 3],          # 环序（rank 顺序，最后一个连回第一个）
#   "edges": [                            # 每条物理边 = 2 根线（每机两台 ConnectX-7 各出一根）
#     {"a": 0, "b": 1,
#      "ports_on_a": [1, 3],             # a 机在该边上出的两根线所占的 dev 口
#      "ports_on_b": [1, 3]},            # b 机同边两根线的口；线对线: a口1<->b口1, a口3<->b口3
#     ...
#   ]
# }
# 语义（与 v4/v5 库内一致，ADR-015/016）：
#   - 对每个环邻 peer，本机以两个口按 channel 奇偶轮换：even chan -> ports[0]，odd chan -> ports[1]。
#   - dev 口索引 = NCCL_IB_HCA 顺序 0..3（如 rocep1s0f0=0, rocep1s0f1=1, roceP2p1s0f0=2, roceP2p1s0f1=3）。
#   - 实录教训（坑1）：接线 f0/f1 整体装反 ⇒ 这里 ports 填的口与物理不符 ⇒ ibv_modify_qp 110。
#     先用 probe_ring_topology.sh 实测，再填本文件。
# CHANGE: 改脚本须 .bak-<tag> 留档 + 更新 tools/README.md
# =============================================================
import argparse
import json
import sys

def fail(msg):
    print("[gen_devmap] x %s" % msg, file=sys.stderr)
    sys.exit(1)

def validate(t):
    if not isinstance(t, dict):
        fail("拓扑必须是 JSON 对象")
    ring = t.get("ring_order")
    edges = t.get("edges")
    if not isinstance(ring, list) or sorted(ring) != [0, 1, 2, 3]:
        fail("ring_order 必须是 [0,1,2,3] 的某个排列，实测: %r" % (ring,))
    if not isinstance(edges, list) or len(edges) != 4:
        fail("edges 必须是 4 条边，实测 %d 条" % len(edges) if isinstance(edges, list) else "edges 缺失")
    for e in edges:
        for k in ("a", "b", "ports_on_a", "ports_on_b"):
            if k not in e:
                fail("边缺少字段 %s: %r" % (k, e))
        if not (0 <= e["a"] <= 3 and 0 <= e["b"] <= 3):
            fail("边 rank 越界: %r" % (e,))
        if e["a"] == e["b"]:
            fail("边两端相同 rank: %r" % (e,))
        for ports in (e["ports_on_a"], e["ports_on_b"]):
            if (not isinstance(ports, list) or len(ports) != 2
                    or not all(isinstance(d, int) and 0 <= d <= 3 for d in ports)
                    or ports[0] == ports[1]):
                fail("ports 必须是 2 个不同的 0..3 索引: %r" % (ports,))
    # 环闭合性：按 ring_order 检查每对相邻 rank（含首尾）恰有一条边
    want_pairs = set()
    for i in range(4):
        a, b = ring[i], ring[(i + 1) % 4]
        want_pairs.add(frozenset((a, b)))
    got_pairs = [frozenset((e["a"], e["b"])) for e in edges]
    if len(set(got_pairs)) != 4:
        fail("存在重复边（同一对 rank 多条边）: %r" % (got_pairs,))
    if set(got_pairs) != want_pairs:
        fail("edges 与 ring_order 不闭合：边集 %r != 环邻对 %r"
             % (sorted(map(sorted, set(got_pairs))), sorted(map(sorted, want_pairs))))
    # 每台机器恰好用满 4 个口（2 边 × 2 线；这是 GB10 双卡双口 4 dev 的物理约束）
    for r in range(4):
        used = []
        for e in edges:
            if e["a"] == r: used.extend(e["ports_on_a"])
            if e["b"] == r: used.extend(e["ports_on_b"])
        if sorted(used) != [0, 1, 2, 3]:
            fail("rank%d 的口使用为 %r，必须恰好用满 0..3 各一次" % (r, sorted(used)))

def build(t):
    """edges -> map[myRank][peerRank] = (devA, devB)；even chan -> devA, odd chan -> devB。"""
    m = [[None] * 4 for _ in range(4)]
    for e in t["edges"]:
        a, b = e["a"], e["b"]
        pa, pb = e["ports_on_a"], e["ports_on_b"]
        m[a][b] = (pa[0], pa[1])
        m[b][a] = (pb[0], pb[1])
    return m

def builtin_default():
    """v4 内建默认表（ADR-015）——ring 0-1-2-3-0"""
    return [
        [None, (1, 3), None, (0, 2)],
        [(1, 3), None, (0, 2), None],
        [None, (0, 2), None, (1, 3)],
        [(0, 2), None, (1, 3), None],
    ]

def map_to_devmap_string(m):
    parts = []
    for r in range(4):
        pairs = ["%d=%d,%d" % (p, m[r][p][0], m[r][p][1])
                 for p in range(4) if r != p and m[r][p] is not None]
        parts.append("r%d:%s" % (r, ";".join(pairs)))
    return ";".join(parts)

def map_to_json(m):
    return {str(r): {str(p): list(m[r][p]) for p in range(4) if r != p and m[r][p] is not None}
            for r in range(4)}

def emit(m):
    print("/* 每台机器对每个环邻 peer 以两口按 channel 奇偶轮换（NCCL_IB_HCA 顺序 0..3）*/")
    for r in range(4):
        cells = []
        for p in range(4):
            cells.append("  --  " if r == p else ("%s" % (m[r][p],)))
        print("  rank%d: %s" % (r, "  ".join(cells)))
    print()
    print("NCCL_RING_DEV_MAP=%s" % map_to_devmap_string(m))
    print()
    print("# ring-devmap.json 内容：")
    print(json.dumps(map_to_json(m), indent=2, ensure_ascii=True))

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--topology")
    ap.add_argument("--json-only", action="store_true")
    ap.add_argument("--default", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()
    if args.help or (not args.topology and not args.default):
        print(__doc__ or "")
        print("USAGE 见文件头注释：--topology <file> [--json-only|--verify] 或 --default")
        sys.exit(0 if args.help else 2)
    if args.default:
        print("内建 v4 默认表（未设 NCCL_RING_DEV_MAP* 时库内行为）：")
        emit(builtin_default())
        sys.exit(0)
    try:
        t = json.load(open(args.topology, encoding="utf-8"))
    except Exception as ex:
        fail("读取拓扑失败: %s" % ex)
    validate(t)
    if args.verify:
        print("[gen_devmap] ok 拓扑合法：环闭合、4 边、每机口恰好用满 0..3")
        sys.exit(0)
    m = build(t)
    if args.json_only:
        with open("ring-devmap.json", "w", encoding="utf-8") as f:
            json.dump(map_to_json(m), f, indent=2)
            f.write("\n")
        print("[gen_devmap] ok 已写 ring-devmap.json")
        sys.exit(0)
    emit(m)

if __name__ == "__main__":
    main()
