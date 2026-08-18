#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze_bench.py — 将 bench_v2.py 产出的 summary_v2.json 归一化为对比表。

用法:
  python3 analyze_bench.py <summary_v2.json> [label]

输出:
  - 每档 (mode, label, conc) 的主指标 (DE=decode_tps / PR=prefill_tps) + ttft + 接受率 + dspark接受率 + k(=dspark位置数)
  - 顶部打印该次运行的 meta (路径/总档数/总请求/ok率) 与推断的投机深度 k
"""
import json, sys

def main():
    if len(sys.argv) < 2:
        print("usage: analyze_bench.py <summary_v2.json> [label]"); sys.exit(1)
    path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else path
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    summ = data.get("summary", [])
    print(f"=== {label} ===")
    print(f"model={data.get('model')} endpoint={data.get('endpoint')} n_tiers={len(summ)}")
    tot = sum(s.get("requests_total",0) for s in summ)
    ok  = sum(s.get("requests_ok",0) for s in summ)
    print(f"requests total={tot} ok={ok} ok_rate={ok/tot:.4f}" if tot else "no requests")
    # 推断 k: 取第一个有 dspark_per_pos_accept 的 DE 档的位置数
    k_vals = []
    for s in summ:
        dp = (s.get("dspark") or {}).get("dspark_per_pos_accept") or {}
        if s.get("mode")=="de" and dp:
            k_vals.append(len(dp))
    kset = sorted(set(k_vals))
    print(f"inferred speculative k (from DE dspark positions) = {kset}")
    print("-"*100)
    hdr = f"{'mode':<3} {'label':<10} {'c':>2} | {'decode_tps':>10} {'prefill_tps':>11} {'ttft_s':>8} {'total_s':>9} {'accept':>6} {'dspark%':>8} {'k':>2}"
    print(hdr)
    for s in summ:
        mode = s["mode"]
        lbl = s.get("task_type") or f"p{s.get('prefix_len')}"
        c = s["concurrency"]
        dec = s.get("p50_decode_tps")
        pre = s.get("p50_prefill_tps")
        ttft = s.get("p50_ttft_s")
        tot_s = s.get("p50_total_s")
        acc = s.get("acceptance_rate")
        dsp = (s.get("dspark") or {}).get("dspark_accept_rate")
        dp = (s.get("dspark") or {}).get("dspark_per_pos_accept") or {}
        kk = len(dp) if (mode=="de" and dp) else ""
        print(f"{mode:<3} {str(lbl):<10} {c:>2} | {str(dec):>10} {str(pre):>11} {str(ttft):>8} {str(tot_s):>9} {str(acc):>6} {str(dsp):>8} {str(kk):>2}")

if __name__ == "__main__":
    main()
