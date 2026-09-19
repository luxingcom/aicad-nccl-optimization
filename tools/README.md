# tools/ — 运维与测试脚本

> 采集自服务器 `/opt/aicad-prod/scripts/`、`/opt/aicad-prod/bench_v2.py` 及本地交付物。
> 脚本头部含 DOCS/CHANGE 纪律注释（改脚本须 `bash -n` + `.bak-<tag>` 留档 + 更新 REFERENCE.md）。

## 文件清单

### 部署工具链（v1.1 新增，2026-09-19，配合 docs/deployment/DEPLOYMENT-GUIDE.md）

| 文件 | 用途 | 对应实录教训 |
|---|---|---|
| `precheck.sh` | **四机一致性 + 系统层预检**（P0 只读 fail-closed）：内核/驱动/MTU/RoCE 口/GRUB 固化/DKMS 残留/锁频单元单行/systemd 权限；`--ips` 走 ssh 巡检 | 坑2/3/5/6/7、错误6 |
| `probe_ring_topology.sh` | **环网拓扑实测**（唯一探针 IP + `ip neigh` 读对端 MAC）：产出 per-rank probe JSON；接线对不对以此为准 | 坑1、错误1/6 |
| `gen_devmap.py` | **拓扑 → 设备映射**：校验（环闭合/口用满 0..3）后生成 `NCCL_RING_DEV_MAP` 串与 `ring-devmap.json`（配合 v5 补丁，换拓扑免重编库） | 坑1、ADR-016 |
| `doctor.sh` | **运行期全量体检**（只读）：容器真实 env（坑9）、NCCL_DEBUG_FILE 落点可写（坑4）、LD_PRELOAD 路径存在性（错误4）、RING-ONLY 日志条数（库生效铁证）、错误签名扫描、API 探测与 API_KEY 四机指纹（坑10）；`--ips` 四机巡检 | 坑4/9/10、错误4 |

### 基准与运维（原有）

| 文件 | 用途 | 来源 |
|---|---|---|
| `bench_v2.py` | **v2 基准测试主脚本**（32 档：DE 12 + PR 20）。QA 整改后 `--key` 默认取 `VLLM_API_KEY` env（显式 --key 优先），避免 key 落命令行/日志。含 **LR-PATCH**（131K 长前缀 prefill 600s 每读超时） | `/opt/aicad-prod/bench_v2.py`（md5 f72e9e84→56ad5ef2） |
| `compare_bench.py` | 对比两次 `summary_v2.json`（当前 vs 基线），输出 DE/PR 逐档 delta% 与判定 | 本地交付物（2026-08-18） |
| `analyze_bench.py` | 将 `summary_v2.json` 归一化为对比表（DE/PR/TTFT/接受率/dspark/k） | 本地交付物（2026-08-18） |
| `gen_report.py` | 生成「当前配置 vs 真B1」全量基准对比报告（支持 131K LR 档位覆盖/补全） | 本地交付物（2026-08-18） |
| `run_benchv2_full.sh` | 全量基准一键运行（32 档循环），API key 已脱敏 | 本地交付物 |
| `healthcheck.sh` | 只读健康探针（P0）：容器运行态 + head 8001 /health；`--role` 可自动探测 | `/opt/aicad-prod/scripts/healthcheck.sh` |
| `healthcheck-rebuild.sh` | 主动重建（P1）：探针失败 → `docker rm -f` 本机容器 → systemd 自愈重建；cooldown 1800s | `/opt/aicad-prod/scripts/healthcheck-rebuild.sh` |
| `clean_tmp_logs.sh` | 临时文件/日志自动维护（每周日 03:30 crontab）：/tmp 清理 + verification-logs + docker dangling 镜像 | `/opt/aicad-prod/scripts/maintenance/clean_tmp_logs.sh` |
| `mirror_to_02.sh` | 01→02 双机镜像备份（rsync 单向，无 --delete 保留 02 回滚锚点） | `/opt/aicad-prod/scripts/mirror_to_02.sh` |
| `run_2hop_bench.sh` | 2-hop 实验基准脚本（**已归档否定**，仅供复现） | `/opt/2hop-s1/`（已归档） |

## 使用注意事项

1. **凭据**：脚本中 `AS12<REDACTED>` 为脱敏占位符；`c3b4<REDACTED>4594` 为 API key 脱敏。真实值请从服务器 `secrets/vllm.env` 或运维凭据库获取。
2. **只读 vs 主动**：`healthcheck.sh` 只读不动作；`healthcheck-rebuild.sh` 会 `docker rm -f` 容器（破坏性，谨慎）。
3. **基准**：跑 `bench_v2.py` 前确保生产空闲（precheck running=0）；完整 32 档约 2 小时。
4. **同步纪律**：服务器脚本为权威版；本地修改需 `bash -n` 校验 + 留档后回同步。

## 关联文档

- 基准协议：`docs/benchmarks/nccl-benchmark-v2-plan-qa-2026-08-16.md`
- 自愈方案：`docs/ops/production-self-healing-plan-architect-2026-08-17.md`、`docs/ops/self-recovery.md`
- 运维手册：`docs/ops/server-maintenance-handbook.md`
