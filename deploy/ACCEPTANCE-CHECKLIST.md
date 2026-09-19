# 部署验收清单（ACCEPTANCE CHECKLIST）v1.1

> 配套 `docs/deployment/DEPLOYMENT-GUIDE.md` §6。
> **纪律：部署完成 = 配置 + 持久化 + 自愈 + 验收数据，缺一不算完成。**
> 每项留 `证据`（命令输出摘录/截图路径），由执行人签字后归档。

## A. 系统层（tools/precheck.sh，四机）

| # | 项 | 期望 | 证据 |
|---|---|---|---|
| A1 | 内核版本 | 四机一致且 = 已验证版本（如 6.17.0-1032-nvidia） | |
| A2 | 驱动版本 | 四机一致 | |
| A3 | GRUB_DEFAULT | 已固化（数字索引形式），grubenv 无 next_entry 残留 | |
| A4 | DKMS | `updates/dkms` 不存在；nvidia.ko signer=Canonical | |
| A5 | RoCE 口 | 全部 state=4:ACTIVE；MTU=9000 四机一致 | |
| A6 | GPU 锁频 | `clocks.sm` 2392-2398 四机一致（单元 ExecStart 单行） | |
| A7 | systemd 权限 | monitor 单元 User= 正确；日志/state 目录属主正确 | |

## B. 物理层（tools/probe_ring_topology.sh + gen_devmap.py）

| # | 项 | 期望 | 证据 |
|---|---|---|---|
| B1 | 环网口连通 | 四机 probe JSON 全部 reachable 且拿到对端 MAC | |
| B2 | 拓扑比对 | 实测「谁连谁、走哪个口」与规划逐边一致 | |
| B3 | devmap | `gen_devmap.py --verify` 通过；与库内默认不同则 env 已四机同值下发 | |

## C. 定制库

| # | 项 | 期望 | 证据 |
|---|---|---|---|
| C1 | 库 md5 | 四机 `/opt/nccl-ringonly/libnccl.so.2` 同 md5（登记：`________`） | |
| C2 | LD_PRELOAD 路径 | 容器内每个路径真实存在（doctor 第4项 ok） | |
| C3 | RING-ONLY 日志 | 容器日志 ≥1 条 `RING-ONLY`（v5 覆盖生效时有 `from NCCL_RING_DEV_MAP*`） | |
| C4 | NCCL banner | `NCCL version 2.30.7` 出现（版本以现场为准） | |

## D. 服务与鉴权

| # | 项 | 期望 | 证据 |
|---|---|---|---|
| D1 | doctor 全项 | `tools/doctor.sh` 退出码 0 | |
| D2 | NCCL_DEBUG_FILE | 落点容器内可写（坑4） | |
| D3 | API_KEY | 四机指纹一致（坑10）；无 key 访问 = 401 | |
| D4 | 容器真实 env | docker inspect 与预期一致（坑9） | |

## E. 功能与性能

| # | 项 | 期望 | 证据 |
|---|---|---|---|
| E1 | 冒烟 | 17×19→323；1234+5678→6912；中文正常 | |
| E2 | needle | 200K 与目标长档检索正确 | |
| E3 | 并发 | C16 全成功，吞吐达预期带 | |
| E4 | 带宽 | 环网单口 ≈108.5 Gb/s（此为 GB10 上限，非降级） | |

## F. 自愈与持久化（必须实测）

| # | 项 | 期望 | 证据 |
|---|---|---|---|
| F1 | 杀 head 容器 | 自动重建，doctor 恢复全绿 | |
| F2 | 四机重启 | 全自动恢复（GRUB/锁频/自启链全持久化） | |
| F3 | 备份留档 | 改动文件均有 `.bak-<date>`；拓扑/env/映射归档 | |
