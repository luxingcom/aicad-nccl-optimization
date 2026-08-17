#!/bin/bash
cat > /opt/2hop-s1/out-s3/s3-step2b-carry-result-rex-2026-08-17.md <<'EOF'
# A'②b 结果: carry 变体干净测试 (Rex/SRE 2026-08-17)

## lib
- md5 9176e15625c05a331b7abfd655eef6cb (tuner + 常量 + device table 修复 + carry kernel)
- carry kernel 经 Run2HopHelper 偏特化: SIMPLE=carry-fixed pairwise, LL/LL128=runRing fallback
- 双缓冲 carry (C0/C1), send 源与 recv-reduce 目标隔离

## 逐协议结果 (n=1024, 单通道, 期望 6.0)
| proto  | kernel             | 结果 |
|--------|--------------------|------|
| LL     | runRing fallback   | OK [6.0] |
| LL128  | runRing fallback   | OK [6.0] |
| SIMPLE | carry pairwise     | CRASH: CUDA illegal memory access |

## 结论
- carry/temp-buffer 修复在【干净环境】SIMPLE 下仍 illegal memory access 崩溃 —— 与 ②a form C 完全相同的失败模式。
- temp-buffer 假设【证伪】：carry 修复没有改变失败模式。SIMPLE + 双 Primitives pairwise 的失败
  不是 in-place send 源覆写竞态，而是更底层的 SIMPLE 协议 FIFO/代理对齐问题（越界访问）。
- ②a + ②b 合并结论：bilateral kernel ok=True 判据【未达成】→ 结构性确认 → A/D 决策点。
EOF
echo written
