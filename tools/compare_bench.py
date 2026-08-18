#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
compare_bench.py — 对比两次 bench_v2.py 的 summary_v2.json（当前 vs 基线）。

用法:
  python3 compare_bench.py <current_summary.json> <baseline_summary.json> <baseline_name> [out_json]

输出:
  - 控制台打印 DE/PR 分表（主指标 delta%、TTFT delta%）
  - 写 <out_json>（缺省 <current>_vs_<baseline>.json）含逐档 delta 与判定
主指标: DE=decode_tps, PR=prefill_tps
"""
import json, sys, os

def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)

def keyof(s):
    lbl = s.get("task_type") or f"p{s.get('prefix_len')}"
    return (s["mode"], lbl, s["concurrency"])

def primary(s):
    return s.get("p50_decode_tps") if s["mode"] == "de" else s.get("p50_prefill_tps")

def build(d):
    return {keyof(s): s for s in d.get("summary", [])}

def pct(cur, base):
    if cur is None or base is None or base == 0:
        return None
    return round((cur - base) / base * 100, 2)

def main():
    cur_p, base_p, base_name = sys.argv[1], sys.argv[2], sys.argv[3]
    out_p = sys.argv[4] if len(sys.argv) > 4 else (os.path.splitext(cur_p)[0] + f"_vs_{base_name}.json")
    cur, base = load(cur_p), load(base_p)
    cb, bb = build(cur), build(base)

    out_rows = []
    de_rows, pr_rows = [], []
    for k in bb:
        s = cb.get(k)
        b = bb[k]
        pm_c, pm_b = primary(s) if s else None, primary(b)
        ttft_c = s.get("p50_ttft_s") if s else None
        ttft_b = b.get("p50_ttft_s")
        acc_c = s.get("acceptance_rate") if s else None
        rec = {
            "mode": k[0], "label": k[1], "concurrency": k[2],
            "primary_metric": "decode_tps" if k[0] == "de" else "prefill_tps",
            "current": pm_c, "baseline": pm_b, "delta_pct": pct(pm_c, pm_b),
            "ttft_current": ttft_c, "ttft_baseline": ttft_b, "ttft_delta_pct": pct(ttft_c, ttft_b),
            "acceptance_current": acc_c, "acceptance_baseline": b.get("acceptance_rate"),
            "status": "ok" if s else "MISSING_IN_CURRENT",
        }
        out_rows.append(rec)
        (de_rows if k[0] == "de" else pr_rows).append(rec)

    def fmt_delta(v):
        if v is None:
            return "   n/a"
        return f"{v:+6.2f}%"

    def table(rows, title):
        print(f"\n=== {title} (current vs {base_name}) ===")
        print(f"{'label':<10} {'c':>2} | {'cur':>10} {'base':>10} {'Δ%':>8} | {'ttft_c':>8} {'ttft_b':>8} {'Δ%':>8} | {'acc':>4}")
        for r in rows:
            cur = r["current"]; base = r["baseline"]
            cur_s = f"{cur:.2f}" if cur is not None else "  MISS"
            base_s = f"{base:.2f}" if base is not None else "  n/a"
            ttft_c = f"{r['ttft_current']:.3f}" if r["ttft_current"] is not None else "  n/a"
            ttft_b = f"{r['ttft_baseline']:.3f}" if r["ttft_baseline"] is not None else "  n/a"
            acc = f"{r['acceptance_current']:.2f}" if r["acceptance_current"] is not None else " n/a"
            print(f"{r['label']:<10} {r['concurrency']:>2} | {cur_s:>10} {base_s:>10} {fmt_delta(r['delta_pct']):>8} | {ttft_c:>8} {ttft_b:>8} {fmt_delta(r['ttft_delta_pct']):>8} | {acc:>4}")

    table(de_rows, "DE decode (tok/s, 越高越好)")
    table(pr_rows, "PR prefill (tok/s, 越高越好; TTFT 越低越好 → Δ% 应为负)")
    with open(out_p, "w", encoding="utf-8") as f:
        json.dump({"baseline_name": base_name, "current_model": cur.get("model"),
                   "baseline_model": base.get("model"), "rows": out_rows}, f,
                  ensure_ascii=False, indent=2)
    print(f"\ncomparison written: {out_p}")

if __name__ == "__main__":
    main()
