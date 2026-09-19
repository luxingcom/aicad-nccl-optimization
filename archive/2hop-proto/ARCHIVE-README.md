# NCCL 2-hop 项目归档 (D 收尾) — 2026-08-17

## 1. 结论 (一句话)
2-hop bilateral 在当前 NCCL ring 原语框架内被【干净否定】(SIMPLE 双 Primitives 在 form C 与 carry
两套独立设计下以完全相同方式 illegal memory access 崩溃); LL/LL128 价值区不可触及 (2-hop kernel 未实例化,
生产 tuner 将 <=32KB 路由 LL)。项目归档, 预算转投 P2 交换机 / 0.27 升级。终审: 
nccl-2hop-s3-final-adjudication-architect-2026-08-17.md

## 2. 根因链 (ADR 记录, 见 adjudication/nccl-tuner-netdev-hardcode-adr-architect-2026-08-16.md S1.13)
- 主根因: 2HOP 算法未注册进 device kernel table
  (generate.py algos_of_coll 缺 "2HOP" + ncclDevFuncId nAlgos=6 直接 +algo 溢出
   -> 一直 launch 到 Reduce kernel -> 垃圾值 [783.875])
- 根因闭环证据: lib d3fc78a4 (2HOP+runRing -> ok=True 6.0/6.0/6.0) [二进制未留存, md5 见 MD5-RECORD.txt]
- 机制级否定: ②a form C (cfa8c14c) / ②b carry (9176e156) 在干净 SIMPLE 下同样 illegal memory access 崩溃

## 3. 目录结构
- source/          完整源码树 (git clone, 原始 SHA, 含未提交 device table 修复)
- git-bundle/      自包含 git bundle + SHA 映射表 (见下)
- patches/         2hop-proto-host-plumbing.patch + 2hop-proto-kernel.patch + apply 脚本 + record 脚本
- libs/            proto 库关键变体 (before-tuner/step1-tuner/step2-carry/carry-final)
- MD5-RECORD.txt   lib md5 总表 (proto + 生产 + 修复锚点)
- failures/        失败复现日志 (2hop-failures + /tmp mini + fd_* 对照)
- data/            S3 门数据 (G1 ring / G3 ring-baseline / 2hop r1r2 / isolation pre-post)
- reports/         全部 2-hop 报告 (S1-S3 + step1/2/2a/2b + 设计 + P0)
- adjudication/    终审裁定 + step12 框架 + ADR

## 4. git bundle 说明 (重要)
- 原始 worktree 的 v2.30.7-1 merge (73cf112) 上游父提交已被裁剪 (1933fdd/3ec3073f 缺失),
  直接 bundle 无法 clone。
- 因此用 git fast-export/import (honor graft root) 生成【自包含 bundle】: nccl-2hop-proto-20260817.bundle
- bundle 中 SHA 与原始不同 (树内容与提交信息一致), 映射见 git-bundle/SHA-MAPPING.txt
- source/ 保留原始 SHA + grafts 文件 (git log 2hop-proto 可读)

## 5. 复现指引
- 从 bundle 重建: git clone nccl-2hop-proto-20260817.bundle 2hop-proto
- 重建 lib (d3fc78a4/cfa8c14c/9176e156):
  make src.build NVCC_GENCODE="-gencode=arch=compute_120,code=sm_120"  (anemll 0.2.1 容器)

## 6. 生产终态
- 生产库 /opt/nccl-ringonly/libnccl.so.2.30.7 md5 2be94172 (未变, 只读)
- bench_v2.py 修复版 f72e9e84 在位, 备份 6ed8ce93 在 /opt/aicad-prod/backup/

## 7. 测试残留清理记录 (2026-08-17)
- 2hop-s1-rank0 (测试容器): 已 rm -f
- nccl-2hop-build (构建容器): 已 rm -f
- 生产 vllm-tp4-rank0: 未触碰 (healthy, Up 12h+)
- /opt/2hop-s1 目录: 保留 (含 src/proto-lib/prod-lib/out-s3 等, 归档已完成, 供后续核对)
