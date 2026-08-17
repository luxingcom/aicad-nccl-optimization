# 明文密码排查与整改报告（QA / Tessa）

**审计人**：泰莎（Tessa）· 测试专家 | 工程保障团队
**日期**：2026-08-17
**范围**：/opt/aicad-prod/{scripts,*.py,docs,configs,envs,lib,backup}、/opt/2hop-s1/、/etc/systemd/system/vllm-tp4-head.service、/root、/home/<svc-user>、cron 脚本、/opt/nccl-ringonly、NCCL 源码归档
**注意**：本报告**不含任何完整明文凭据**，密码一律脱敏为 `AS12******`；关键结论已标注文件位置供整改定位。

---

## 0. TL;DR（P0 优先结论）

- ✅ **生产运行链无明文凭据**：systemd 服务（EnvironmentFile=secrets/vllm.env）、生产启动脚本（start_tp4_head.sh 等）、shim-deploy.sh（环境变量/交互输入）、cron 脚本、/root、/home 下运维脚本——**均未发现明文密码**。
- ✅ **密钥存放姿势正确**：/opt/aicad-prod/secrets/vllm.env = **600 root:root**，仅含 VLLM_API_KEY，由 systemd EnvironmentFile 引用。
- ❌ **P0（高暴露）**：`/opt/aicad-prod/scripts/v027-test/preflight_v027.sh`（775 世界可读）明文内嵌 sudo 密码（AS12******），3 处 `echo ... | sudo -S`。
- ⚠️ **P1**：/opt/2hop-s1/ 下 10 个文件（8 脚本 + 1 bak + 2 日志）明文 sudo 密码（755/664 世界可读）；verification-logs 中 manifest_v2.json / precheck_v2.json 记录 **live API key 完整明文**（664 世界可读）。
- ⚠️ **P2**：backup 归档中含同一 preflight 副本；docs/deliverables 已脱敏（核对通过）。
- 🔴 **核心风险**：以上明文密码为**当前有效 sudo 密码**，任意本地用户可读取 → 等于本地提权路径。**建议优先轮换口令 + 收敛脚本**（见 §5）。

---

## 1. 扫描范围与方法

- 关键词：AS12******（已知 sudo 密码前缀）、`password=`、`PASSWORD`、`passwd=`、`api[_-]?key=`、`Bearer <32hex>`、`sudo -S`、`secret=`、`token=`。
- 排除：patch 源码中的 `token`/`perToken`/`barrier_token` 等代码标识符（非凭据）；上游 vLLM 源码 CI/test 样例。
- 逐文件权限核验（ls -la）确认可读性。

---

## 2. 风险分级清单

### 2.1 P0 —— 明文 sudo 密码，位于生产目录树且世界可读

| 文件 | 权限 | 风险 | 说明 |
|---|---|---|---|
| /opt/aicad-prod/scripts/v027-test/preflight_v027.sh | 775 | **高** | 3 处 `echo AS12****** \| sudo -S`；v027 测试脚本但在生产主机生产目录内，任意用户可读 → 本地提权 |
| /opt/aicad-prod/backup/v027-nvfp4-archive-20260815/scripts-v027-test/preflight_v027.sh | （归档） | 中高 | 同上文件归档副本 |

### 2.2 P1 —— 明文 sudo 密码 / live API key，测试/日志文件，世界可读

**2.2a sudo 密码（/opt/2hop-s1/，2-hop 已 D 收尾归档但未清理）**

| 文件 | 权限 | 说明 |
|---|---|---|
| run_2hop_bench.sh | 755 | 多行 `echo AS12****** \| sudo -S` |
| run_2hop_bench.sh.bak-s2pre | 755 | 同上 |
| run_2hop_s2.sh | 755 | 1 处 |
| run_p0.sh | 755 | 2 处 |
| start_2hop.sh | 755 | 1 处（sudorun 函数） |
| s3/run_s3.sh | 755 | 多行 |
| s3/lat_probe.sh | 755 | 多行 |
| s3/s3_isolation.sh | 755 | 1 处 |
| out-s2/bench-rank0-20260816_145405.log | 664 | shell 回显泄漏密码 |
| out-s2/bench-rank0-20260816_150503.log | 664 | 同上 |

**2.2b live API key（VLLM_API_KEY）落盘日志**

| 文件 | 权限 | 说明 |
|---|---|---|
| verification-logs/*/manifest_v2.json、precheck_v2.json（BENCHV2_20260816_130438、BENCHV2_FIX_20260816T165051Z、FINALBASE_20260817_042646 等） | 664 | bench_v2.py 以 `--key <完整key>` 命令行传入 → 进程列表 + 日志均记录完整 key（key 前缀 c3b4de5...，与 secrets/vllm.env 同值） |

> 注：deliverables 报告中出现的 key 已脱敏（`c3b4de5...` 前缀），prod-fix-plan 第 4 项已完成文档脱敏；**verification-logs 属运行时日志，为本次新发现的泄漏点**。

### 2.3 P2 —— 文档/归档中的凭据（评估敏感性）

| 位置 | 说明 | 建议 |
|---|---|---|
| docs/file-registry.md §1.6-30 | 仅写"统一 sudo 密码 <见 secrets 管理指引>（⚠️ P0 待轮换）"，未含明文 | ✅ 已达标；口令轮换后更新指引 |
| deliverables/*.md | API key 已脱敏（c3b4de5...），sudo 密码无明文 | ✅ 已达标 |
| backup/vllm027-src/** | 上游 vLLM 源码 CI/test 中的 `password` 字样 | 上游样例，非我方凭据，忽略 |
| /root/、/home/<svc-user>（排除 cache/local/ssh/config） | 无密码命中 | ✅ |

---

## 3. 已核验的安全项（良好实践，保留）

- `/opt/aicad-prod/secrets/vllm.env` = **600 root:root**，systemd EnvironmentFile 引用，脚本无硬编码 key（`${VLLM_API_KEY:?}`）。
- 生产脚本 `start_tp4_cluster.sh` 用 `sudo -n`（NOPASSWD）读 env，脚本内无密码。
- `shim-deploy.sh` = 750（group 可读写执行），密码走环境变量 `SHIM_SUDO_PW` 或交互输入，无硬编码。
- systemd 服务文件本身无任何凭据。
- deliverables/docs 密码/API key 已脱敏（8/15 已完成）。

---

## 4. 整改建议（出方案，不擅自杀改）

### 4.1 根因
- 团队习惯用 `echo <密码> | sudo -S <cmd>` 在脚本中提权，密码长期未轮换，且脚本/日志未做权限收敛。

### 4.2 方案（按优先级）

**方案 A：sudo 密码轮换（最高优先，阻断提权路径）**
- 轮换 <svc-user> sudo 密码；随后脚本中旧密码失效（即使文件仍存在也无法利用）。
- 所有引用旧密码的脚本需同步更新（v027-test、2hop-s1）或改用方案 B。

**方案 B：sudoers NOPASSWD 白名单（替代脚本内嵌密码）**
- 新增 `/etc/sudoers.d/aicad-ops`（0600 root:root），仅授权运维常用命令：
  ```
  <svc-user> ALL=(root) NOPASSWD: /usr/bin/docker logs, /usr/bin/docker exec, /usr/bin/docker cp, /usr/bin/docker start, /usr/bin/docker stop, /usr/bin/docker rm, /usr/bin/mkdir, /usr/bin/md5sum, /usr/bin/timeout
  ```
- 脚本改为 `sudo -n <cmd>`（shim-deploy.sh 已支持 SUDO_PW 环境变量 → 可扩展为 `sudo -n` 优先）。
- 注意：docker 白名单本身权限较大，需限定参数或接受风险（本环境为受信内网）。

**方案 C：API key 不落命令行**
- bench_v2.py 增加 `--key` 从环境变量读取的 fallback（`os.environ.get("VLLM_API_KEY")`），避免 key 进 `ps` 与日志。
- 或运行后对 manifest/precheck JSON 做 key 脱敏（sed 替换为 `***`）。

**方案 D：权限与清理（立即执行，不重启）**
- `chmod 700` 或 `chmod 600` 以下文件：v027-test/preflight_v027.sh、/opt/2hop-s1/ 全部含密码脚本。
- 删除 2hop out-s2 中含密码回显的日志（或确认已归档后清空）。
- verification-logs 目录权限收敛为 `700`（仅 <svc-user>）或对 JSON 做 key 脱敏。
- 2-hop 已 D 收尾：建议整体移入 backup（chmod 700）或删除。

### 4.3 整改清单（文件 → 当前风险 → 建议动作 → 是否可立即执行）

| 文件 | 当前风险 | 建议动作 | 立即执行 |
|---|---|---|---|
| scripts/v027-test/preflight_v027.sh | P0 | chmod 700 + 改 `sudo -n` + 密码轮换 | ✅ 权限可立即 |
| backup/v027-nvfp4-archive/**/preflight_v027.sh | P0 | 归档内 chmod 700 或重打包 | ✅ |
| /opt/2hop-s1/ 8 脚本 + 1 bak | P1 | chmod 700；2-hop 归档迁移 | ✅ |
| /opt/2hop-s1/out-s2/*.log（2 个） | P1 | 删除或 chmod 600 | ✅ |
| verification-logs/**/manifest_v2.json、precheck_v2.json | P1 | key 脱敏或目录 chmod 700 | ✅ |
| /etc/sudoers.d/aicad-ops（新增） | — | 方案 B 落地 | ⚠️ 需窗口验证 |
| 四机 sudo 密码轮换 | P0 | 方案 A | ⚠️ 需协调四机 |

---

## 5. 结论

1. **生产运行链安全**：vllm-tp4 服务、启动脚本、cron 均无明文凭据，密钥文件权限正确——用户最关心的"运行脚本是否可被利用"结论为**否**。
2. **风险集中在测试/归档脚本**（v027-test preflight + 2hop-s1）与**日志泄漏**（verification-logs 中的 live API key），均为世界可读。
3. 建议按 4.2 方案 A（轮换）+ B（sudoers 白名单）+ D（权限/清理）推进；方案 B/C 涉及脚本改造，建议下窗口与 team-lead 确认后执行。

---

## 6. 整改执行状态（2026-08-17 追加，team-lead 批准分级执行）

| 类别 | 动作 | 状态 |
|---|---|---|
| D-1 | v027-test/preflight_v027.sh + 2hop-s1 全部脚本 chmod 700 | ✅ **已闭环**：Rex 已清理原目录（2hop-s1 → backup/2hop-s1-archive-20260817.tar.gz；v027-test 已移除），原文件不再存在；我创建的 8 个含密码注释备份已删除；归档 preflight 副本已 chmod 700 |
| D-2 | 删除 2hop-s1/out-s2 两个含密码日志 | ✅ **已闭环**：原目录已归档，日志仅存于 tar.gz（无 live 副本）；归档建议保持 600 |
| D-3 | verification-logs 目录 chmod 700 | ✅ **已执行**（drwx------，owner=<svc-user>，不影响 bench_v2.py 同用户读写） |
| C-4 | bench_v2.py 改 VLLM_API_KEY env fallback（--key 兼容优先） | ✅ **已执行**：--key default=VLLM_API_KEY env；parse_args 后空 key 快速失败；py_compile OK；smoke A（env）/B（--key 兼容）/C（缺 key 快速失败）全过；**新 md5=56ad5ef23f56a8d1f9927d255b607093**；备份 bench_v2.py.bak-envkey-20260817 |
| B-5 | sudoers NOPASSWD 白名单方案 | 📋 方案已出：nccl-sudoers-nopasswd-plan-qa-2026-08-17.md（待批，未部署） |
| A-6 | 轮换 sudo 密码（P0 最高优先） | 🔴 呈报用户决策 |

**额外处置（审计中发现的 P2 文档明文密码）**：
- nccl-maxch16-ab-window-sop-2026-08-16.md：4 处 `echo 'AS12******' | sudo -S`（原为完整密码）→ 已 sed 脱敏为 AS12******（0 残留）。
- backups/fix-20260813/file-registry.md.bak：1 处完整密码 → 已脱敏（0 残留）。
- 全 /opt/aicad-prod 复扫：**sudo 密码 0 残留**（live 文件系统，脱敏记 AS12******）。

> 执行环境备注：2026-08-17 执行期间 Bash 输出通道异常（返回空），已通过"PowerShell 重定向 + Read 读取"与"本地脚本 scp + 远端执行"方式完成全部服务器侧落地，无阻塞。

---

*报告落盘：本地 deliverables/engineering-assurance/nccl-secret-audit-qa-2026-08-17.md + 服务器 /opt/aicad-prod/docs/*（本报告不含完整明文密码）
