#!/bin/bash
# record_2a.sh — write ②a result file
cat > /opt/2hop-s1/out-s3/s3-step2a-formc-result-rex-2026-08-17.md <<'EOF'
# A'②a 结果: 原始 form C run2Hop 干净测试 (Rex/SRE 2026-08-17)

## lib
- md5 cfa8c14cbd21de1e7a1fcd26ae667aff (tuner + 常量 + device table 修复 + form C kernel)
- form C 通过 Run2HopHelper 偏特化: SIMPLE=form C pairwise, LL/LL128=runRing fallback
- 2HOP 仅实例化 Sum f32 (form C directRecvReduceCopy 仅 SIMPLE 支持; LL/LL128 编译期缺失)

## 逐协议结果 (n=1024, 单通道, 期望 6.0)
| proto  | kernel          | 结果 |
|--------|-----------------|------|
| LL     | runRing fallback | OK [6.0] ok=True |
| LL128  | runRing fallback | OK [6.0] |
| SIMPLE | form C pairwise  | CRASH: CUDA illegal memory access |

## 结论
- ① 根因确认后的干净环境下, LL/LL128 经 2HOP 正确 (ring fallback 已可用)。
- 原始 form C pairwise kernel 在 SIMPLE 下【illegal memory access】崩溃 —— 不是死锁、不是错值,
  而是真实 kernel 缺陷 (越界访问)。该 kernel 历史上从未真正运行过 (设备表未注册 → 一直 launch 到错误 kernel)。
- ②a 判据 (bilateral kernel ok=True) 未达成 → 按 Archi 顺序进入 ②b (carry 变体)。
EOF
echo written
