# 生产自恢复与持久化完善方案（Architect 设计稿）

**状态:** Proposed（待 team-lead 批准实施分级）
**日期:** 2026-08-17
**作者:** 阿奇（系统架构师）| 工程保障团队
**范围:** DGX Spark 四机环网 TP4 vLLM（deepseek-v4-flash-0731，NCCL 2.30.7 ring-only 2be94172）
**对应需求:** ① 生产环境持久化修复和自恢复功能完善 ② 测试过程带来的修改/小问题完善 ③ 不停机运行日志/临时文件/缓存自动维护防膨胀

---

## 0. 摘要（TL;DR）

| 维度 | 结论 |
|------|------|
| 自恢复体系 | **基本完备**：systemd Restart=always + monitor 恒非零退出 + head-first 全链重建 + 互杀守卫 + D1 模型门禁；五类故障场景 4 类已覆盖 |
| 主要缺口 | ① 进程级故障（容器在但 vLLM API 挂/死锁）无外部探针（self-recovery.md §6 已记录，P2→本方案提升为 P0/P1）② docker 依赖未声明（当前仅 `After=`，无 `Wants/Requires`）③ `RequiresMountsFor` 三机不一致且 03/04 指向遗留路径 |
| 持久化 | 模型/脚本/文档/备份均在**根分区**（非独立数据盘）；模型本地 4 份冗余（156G×4）；双机镜像（Rex）兜底 |
| 防膨胀短板 | ① journald 无限额（当前 0.6~1.1G/机，默认上限高）② docker 测试镜像约 **686G**（<node1>）③ 03/04 模型 `.local-backup` 冗余约 162G×2 ④ vllm logrotate 已部署但路径待补正（见 3.4） |
| 实施分级 | **P0 五项**（不重启生产，可立即）/**P1 三项**（需重启窗口，报批）/**P2 四项**（观察/后续） |

---

## 1. 背景与目标

- 生产：DGX Spark 四机环网 TP4 vLLM（deepseek-v4-flash-0731），NCCL 2.30.7 ring-only（2be94172 hardened），systemd 托管（vllm-tp4-head.service / vllm-tp4-worker.service），四机 healthy。
- 拓扑：01=head(rank0,<LAN-IP>) 02=rank1(<LAN-IP>) 04=rank2(<LAN-IP>) 03=rank3(<LAN-IP>)；控制面 MASTER_ADDR=<LAN-IP>:25999，API :8001。
- 目标：核验并完善自恢复/持久化，覆盖测试遗留小问题，建立日志/临时文件/缓存自动维护防膨胀机制；产出可执行的分级实施清单。

---

## 2. 现状核验结论（2026-08-17 实测）

### 2.1 systemd 服务配置（四机）

| 项 | head(01) | worker(02/03/04) | 评估 |
|---|---|---|---|
| Description | TP4 vLLM head (rank0) with self-heal | rank1/2/3 with self-heal | ✓ |
| Restart | `always` | `always` | ✓ 覆盖崩溃/主动退出（monitor 恒非零依赖此） |
| RestartSec | 15 | 15 | ✓ 有节流（优于最小建议 5s，适配权重加载场景） |
| StartLimitIntervalSec | 1800 | 1800 | ✓ 窗口合理 |
| StartLimitBurst | 20 | 20 | ✓ 防崩溃循环空转（R11 已放大） |
| TimeoutStartSec | 1500 | 1500 | ✓ 覆盖 156G 权重冷加载（25min） |
| User / Group | <svc-user> | <svc-user> | ✓ 非 root |
| EnvironmentFile | `/opt/aicad-prod/secrets/vllm.env` | 同 | ✓ 600 root:root（权限安全，Tessa 审计项已达标） |
| After= | remote-fs, network-online, docker | 同 | ⚠ 仅 After，无 Wants/Requires（见 2.2） |
| RequiresMountsFor | **缺** | 02缺 / 03/04 有（指向 `/data/models/...`） | ⚠ 不一致 + 03/04 指向遗留路径（实际模型在 `/opt/aicad-prod/models` 本地目录） |
| is-enabled | enabled | enabled | ✓ 开机自启已配 |

- 服务活性（实测）：01 head=active / worker=inactive（正确）；02/03/04 worker=active / head=inactive（正确）；docker 四机 active。
- 稳定性：head NRestarts=0（08-16 16:01 起）、worker02 NRestarts=1；容器四机 Up 15h+ healthy。
- 环境文件权限：`/opt/aicad-prod/secrets/vllm.env` = `-rw------- root root`（600）→ systemd 以 root 读取后降权运行，安全达标。

### 2.2 自愈机制架构（monitor 脚本 + systemd）

```
systemd(vllm-tp4-head.service) ── ExecStart ── monitor_tp4_head.sh (01)
systemd(vllm-tp4-worker.service)── ExecStart ── monitor_tp4_worker.sh (02/03/04)
   ├─ 容器在(docker ps 命中) → docker wait（跟随退出）→ 退出非零 → systemd Restart
   ├─ 容器不在(head) → ssh 清 worker(02/04/03) → start_tp4_head.sh → TCPStore 就绪门禁(≤60s) → 等 3 worker 接入(60s 无进展 fail)
   └─ 容器不在(worker) → head API=200 且集群成形? → rm rank0 触发全链重建; 否则等 TCPStore:25999(≤120s)
        └─ 模型未就绪(exit 2) → 60s×n 指数退避(最多 10 次)
```

- 容器 `--restart no`（**有意设计**）：防 docker daemon 重启风暴，生命周期完全由 systemd 掌控。用户要求的"docker restart=unless-stopped 容器级兜底"**不建议采纳**——TP4 分布式集群单容器自行拉起会造成 split-brain/rank 不一致，协调式重建（head-first）更正确。
- monitor 恒 exit 非零 → systemd Restart=always 接管，RestartSec=15 节流。
- head 重建前置清理 worker → 保证所有 rank 重新注册 TCPStore。
- 互杀守卫（R11）：worker 仅在 head API 健康且集群已成形（rank 全连 TCPStore）时才允许动 head；冷启动阶段不动 head，防冷启动互杀。
- 前置依赖（docker）：当前 unit 仅 `After=docker.service`，**无 `Wants=/Requires=`**。后果：docker daemon 故障时 unit 仍会启动 → monitor `docker run` 失败 → 退避重试 → 可能烧 StartLimitBurst。但 docker 故障属维护事件，影响有限，见 3.1 权衡。

### 2.3 五种故障场景恢复评估

| # | 场景 | 恢复行为（现状） | 评估 |
|---|---|---|---|
| 1 | 进程崩溃（容器退出） | monitor `docker wait` 感知 → exit 1 → systemd Restart=15s → 重建该 rank | ✓ 已覆盖（worker 场景会评估是否全链重建） |
| 2 | 容器退出 | 同上；head 退出会触发 worker 依次自愈重注册 | ✓ 已覆盖 |
| 3 | 节点重启 | multi-user.target 拉起 + unit 已 enable；开机顺序 01→02→03→04 依赖人工/运维编排 | ✓ 基本覆盖；顺序依赖人工（P2 增强） |
| 4 | 网络抖动 | 容器级：NCCL `--distributed-timeout-seconds 300` 兜底；脚本级：monitor 内 ssh/curl 失败均 `|| true` 容忍 + 退避 | ✓ 已覆盖 |
| 5 | 模型加载失败 | worker：D1 门禁 → exit 2 → 指数退避 10 次；head：preflight 自检 + TimeoutStartSec=1500，失败 → exit 1 → Restart 循环 → 1800s/20 次超限转 failed 人工介入 | ✓ 已覆盖（head 侧无 D1 型显式门禁，靠启动失败传播，可接受） |
| 6 | **进程级：容器在但 vLLM API 挂/死锁** | **不被感知**——docker wait 只跟容器退出；docker `--health-cmd` 仅查 `pgrep VLLM::EngineCore`（进程存在即 healthy，不探 API） | ⚠ **缺口**（self-recovery.md §6 已记录 P2）→ 本方案提升：P0 只读探针 + P1 主动重建 |

### 2.4 持久化与防膨胀现状

**日志**
| 项 | 现状 | 评估 |
|---|---|---|
| vLLM 容器日志 | docker json-file + `--log-opt max-size=100m --log-opt max-file=3`（每容器 ≤300MB） | ✓ 已有上限 |
| 容器内 /var/log/vllm | bind `~/vllm-logs`（当前仅 nccl 日志 ~14KB） | ✓ 量小 |
| monitor/start 脚本日志 | journald（`-u vllm-tp4-head/worker`） | ⚠ **journald SystemMaxUse/RuntimeMaxUse 未设**（默认上限高）；实测 head 1.1G / 02 684M / 03 659M / 04 592M |
| journald 持久化 | `/var/log/journal` 存在（四机）→ 崩溃现场保留 ✓ | ✓ 已持久化 |
| logrotate | `/etc/logrotate.d/aicad` 仅覆盖 `/opt/aicad/logs/*`（旧 aicad 栈）；**无 vllm 专属轮转**（Rex 部署中） | ⚠ 待部署 |
| 验证日志 | `/opt/aicad-prod/verification-logs` 仅 1.3M | ✓ 量小 |

**数据/配置持久化**
- 模型：`/opt/aicad-prod/models/deepseek-v4-flash-0731` → 各机软链（01/02 → `/home/<svc-user>/models/...`；03/04 → `/data/models/...`），均**本地盘**，约 156G/机 ×4 冗余。
- `/data/models` 为遗留路径：01/02 无 deepseek 子目录，03/04 有模型 + `.local-backup`（约 162G/机，冗余副本）。
- 脚本/文档/备份/环境：均在 `/opt/aicad-prod/`，与系统**同一根分区**（01/02: 3.6T，03/04: 916G）——**无独立数据盘**，系统盘故障则全丢，双机镜像（Rex）为唯一兜底。
- rollback 锚点：`/opt/aicad-prod/backup/` 在位（nccl 多版本、脚本 bak）。

**临时文件/缓存/镜像**
| 项 | 现状 | 评估 |
|---|---|---|
| docker 测试镜像 | <node1>：v027 + sglang 等 test-* 镜像合计 **约 686G**（47.3G×7 + 53.3G + 45.1G + sglang 30.8G×2 等） | ⚠ **最大膨胀源** |
| 模型 .local-backup | 03/04：`/data/models/deepseek-v4-flash-0731.local-backup` ≈ 162G/机 | ⚠ 冗余副本，需确认保留策略 |
| 编译缓存 | vllm-envc-cache 52M + vllm-cache 36M + tilelang 25M + b12x 1.1M | ✓ 量小 |
| 脚本 bak 积累 | `/opt/aicad-prod/scripts/*.bak-*` 数十个（每次修改留档） | ⚠ 属治理资产，建议归档后清理（P2） |
| nccl-ab-B | `/opt/aicad-prod/scripts/nccl-ab-B/`（今日 06:20 测试残留 hosts.txt/run_lat.sh） | ⚠ 测试残留，待清理 |

### 2.5 小问题残留清单（对应测试过程带来的修改）

| # | 问题 | 实测 | 处置建议 | 分级 |
|---|---|---|---|---|
| 1 | NCCL_IB_PEER_HCA 残留 | head `start_tp4_head.sh` **L122 仍残留** 1 处（worker 已移除 fix-20260813）；非生产脚本 b12x/sglang/v027-test 多处 | head 脚本移除（ADR-015 已记录弃用；库 v4 忽略该 env）；非生产脚本归档标注 | **P1**（改脚本不影响运行容器，但为四机一致归入部署窗口） |
| 2 | 测试容器残留 | nccltune 25 个已清理（Rex）；v027 测试容器未见 | 继续核对 `docker ps -a` | Rex 处理中 |
| 3 | 明文密码风险 | `vllm.env` 已 600 root:root（systemd 读取） | Tessa 审计中；确认无其他明文落盘 | Tessa 处理中 |
| 4 | 日志无轮转 | vllm 专属 logrotate 未部署 | Rex 部署中 | Rex 处理中 |
| 5 | 测试镜像 686G | <node1> 大量 v027/sglang test-* 镜像 | 清理（见 3.6） | **P0** |

---

## 3. 方案设计

### 3.1 systemd 加固（P1，需重启窗口）

**目标**：补 docker 依赖声明、统一 RequiresMountsFor、保持现有已完备参数。

**改动点（建议 diff 见附录 A，留档待批）**：
1. **docker 依赖**：在 `[Unit]` 增加 `Wants=docker.service`（软依赖）并保留 `After=docker.service`。
   - 权衡：`Requires=` 严格但 docker.service 无自动重启，docker 短暂故障会让 vllm 进入 failed 卡死，需要人工 `start`；`Wants=` 软依赖 → docker 未起时尝试拉起，拉起失败由 monitor 退避兜底，**风险更低**。默认推荐 `Wants`；如团队偏好严格，可改用 `Requires`（附录 A 给出两种，二选一）。
2. **RequiresMountsFor 统一**：03/04 现有条目指向 `/data/models/deepseek-v4-flash-0731`（遗留路径且非挂载点）；实际模型为本地目录，该门禁**无实际保护作用**，且 head/02 无此条目造成不一致。建议**统一移除**（模型就绪由 start 脚本 D1 门禁保证），或统一改为实际路径（本地目录下同样无意义）。→ 归 P2 随 3.1 一并处理（不单独触发重启）。
3. **保持项（不修改）**：Restart=always / RestartSec=15 / StartLimitIntervalSec=1800 / StartLimitBurst=20 / TimeoutStartSec=1500 / User=<svc-user> / EnvironmentFile —— 现状已满足并超过最小加固建议。

**生效方式**：改 unit → `systemctl daemon-reload` → 需 `systemctl restart vllm-tp4-*` 生效（= 重启生产，报 team-lead 批准，纳入下次窗口）。

### 3.2 健康检查自动恢复（P0 只读探针 + P1 主动重建）

**背景**：当前自愈不感知"容器在但 API 挂"。docker `--health-cmd` 只查 EngineCore 进程存在。

**P0 — 只读探针（不触生产，可立即部署）**：
- 新增 `/opt/aicad-prod/scripts/healthcheck.sh`（建议脚本全文见附录 B，待 Rex 部署）：`curl :8001/health` + `curl :8001/v1/models`，超时 5s。
  - 通过：写 `/tmp/vllm-healthcheck.ok`（时间戳）。
  - 失败：追加 `/tmp/vllm-healthcheck.fail`（时间戳+连续计数）。
- 调度：systemd timer（`vllm-healthcheck.timer`，OnUnitActiveSec=60s，AccuracySec=5s，Persistent=true）或 cron `* * * * *`。仅 head(01) 探测即可（API 单点）。
- 行为：P0 阶段**只记录 + 写 critical 标记**，不做自动恢复；供 SRE 观测与后续 P1 启用。
- 影响：新增文件/unit，不修改现有服务，**无需重启生产**。

**P1 — 主动重建（需窗口，报批后启用）**：
- 探针连续失败 ≥3 次（约 3 分钟）→ 写 `/tmp/vllm-healthcheck.critical` → 触发 head monitor 全链重建（`docker rm -f vllm-tp4-rank0`，worker 侧 monitor 感知后协调重注册）。
- 需在窗口执行自愈演练验证（沿用 self-recovery.md §4 演练 B 方法 + API 级注入：`kill` vLLM 主进程而非容器，验证探针捕获并触发重建）。

### 3.3 节点重启自动拉起（现状确认 + 增强）

- **现状**：四机 unit 均已 `systemctl enable`（is-enabled=enabled）；节点重启后由 multi-user.target 拉起 monitor → 重建容器。✓
- **容器级兜底**：明确**不采用** docker `restart=unless-stopped`（理由见 2.2），维持 `--restart no` + systemd 协调式重建。
- **增强（P2）**：开机顺序 01→02→03→04 目前依赖运维人工/脚本；建议后续用 systemd 依赖链或运维编排固化（四机 head 先起、worker 后起的顺序），避免多机同时重启时 rank 注册竞态。
- **验证**：下次窗口执行一次"单机重启自愈演练"（reboot 01，观察四机恢复与 API 可用，参考 self-recovery.md §4）。

### 3.4 日志持久化与轮转（P0）

1. **journald 限额（P0，热生效）**：四机 `/etc/systemd/journald.conf` 设置 `SystemMaxUse=2G`、`SystemKeepFree=8G`（当前 0.6~1.1G/机；2G 上限充足且防无限增长）→ `systemctl restart systemd-journald` 热生效，**不影响 vLLM**。
2. **vllm 专属 logrotate（P0，与 Rex 协同——已于 2026-08-17 部署）**：Rex 已部署 `/etc/logrotate.d/vllm-tp4`（四机），覆盖 docker 容器 json 日志（daily/size 100M/rotate 5/copytruncate）与 `/var/log/vllm/*.log`（daily/rotate 14/copytruncate）。
   - **补正点（P2）**：logrotate 覆盖 `/var/log/vllm/*.log`，但实际 vLLM 文件日志绑定在 `~/vllm-logs`（即 `/home/<svc-user>/vllm-logs`）——建议补规则或 `ln -s /home/<svc-user>/vllm-logs /var/log/vllm` 对齐；当前 nccl 日志仅 ~14KB，影响低。
   - 容器内日志已由 docker `--log-opt` 兜底（≤300MB/容器），无需额外处理。
3. **崩溃现场保留**：journald 已持久化（/var/log/journal 存在）✓；确认 P1 主动重建前保留最近 3 次崩溃的 journal 段（`journalctl -u vllm-tp4-head -b` 历史 boot 均在）。

### 3.5 数据/配置持久化（P1/P2）

- **落盘确认**：关键资产均在 `/opt/aicad-prod/`（模型/脚本/文档/备份/环境），但**与系统同根分区**。建议双机镜像（Rex task 3）覆盖目录：`/opt/aicad-prod/`（排除模型大目录可另策略）、`/etc/systemd/system/vllm-tp4-*.service`、`/etc/logrotate.d/`、`/etc/systemd/journald.conf`。
- **模型冗余评估（P2）**：156G×4 本地重复；后续可评估 NFS/共享存储去重或 01 单份 + 各机按需拉取。当前**不动**（避免引入新风险）。
- **.local-backup 处置（P2）**：03/04 `/data/models/deepseek-v4-flash-0731.local-backup`（约 162G×2）待确认保留策略——若双机镜像已生效可删除；确认前保留。

### 3.6 防膨胀治理（P0/P1）

| 项 | 处置 | 分级 | 预计释放 |
|---|---|---|---|
| docker 测试镜像（v027/sglang test-*） | `docker rmi` 清理 <node1> 上非生产 tag；**保留**生产 `0.2.1-v026.0` 及正在运行容器镜像；03/04 同样清理 | **P0**（不动生产容器） | 01 约 600G+ |
| journald 限额 | 见 3.4 | P0 | 上限锁定 2G/机 |
| vllm logrotate | 已部署（Rex，四机）；路径补正见 3.4 | P2 | 日志滚动清理 |
| 维护 cron（/tmp/verification-logs/dangling） | 已注册（Rex，head 周日 03:30） | — | 自动维护生效 |
| .local-backup | 确认保留策略后清理 | P2 | ~324G |
| 脚本 bak 归档 | 归档至 `/opt/aicad-prod/backup/retired-scripts/` 后清源目录 | P2 | 少量 |
| nccl-ab-B 等测试残留 | 清理或归档 | P0 | 少量 |

---

## 4. 实施分级清单

### P0 — 立即实施（不重启生产，不触运行容器）
| # | 项 | 执行人 | 说明 |
|---|---|---|---|
| P0-1 | journald SystemMaxUse=2G + SystemKeepFree=8G（四机） | SRE | 热生效，`systemctl restart systemd-journald` |
| P0-2 | docker 测试镜像清理（v027/sglang test-*） | SRE | 保留生产 v026.0；`docker rmi` 前 `docker ps -a` 核对无引用 |
| P0-3 | healthcheck.sh 只读探针 + timer（P0 模式，只记录） | SRE | 新增文件/unit，不修改现有服务 |
| P0-4 | vllm logrotate 路径补正（~/vllm-logs 规则或软链） | SRE/Rex | logrotate 已部署四机；补路径对齐（P2 亦可） |
| P0-5 | nccl-ab-B 等脚本区测试残留清理 | SRE/Rex | 清理/归档 |

### P1 — 下次窗口（需重启 vLLM 生产 → 报 team-lead 批准）
| # | 项 | 执行人 | 说明 |
|---|---|---|---|
| P1-1 | systemd unit 增加 docker 依赖（Wants/Requires 二选一） | SRE | 四机 daemon-reload + 服务重启 |
| P1-2 | head 脚本 L122 移除 NCCL_IB_PEER_HCA（四机一致） | SRE | 改脚本 + bash -n + .bak 留档；下次容器重建生效 |
| P1-3 | healthcheck 主动重建模式（连续失败→触发全链重建）+ 演练验证 | SRE/QA | 需窗口演练（API 级 kill 注入） |

### P2 — 观察/后续
| # | 项 | 说明 |
|---|---|---|
| P2-1 | RequiresMountsFor 统一移除/修正 | 纯一致性，随 P1-1 一并处理（本地目录门禁无实际作用） |
| P2-2 | 开机顺序自动化（01→02→03→04） | 编排/依赖链固化 |
| P2-3 | 模型 4 份冗余去重评估 | NFS/共享存储，需专项 |
| P2-4 | .local-backup（~324G）清理 / 脚本 bak 归档 | 确认镜像兜底后执行 |

> **需重启生产项**：仅 P1 全部（P1-1 必须重启、P1-2 下次容器重建即生效、P1-3 需窗口演练）。P0 全部无需重启。

---

## 5. 风险与回滚

| 风险 | 缓解 |
|---|---|
| journald 限额误伤崩溃现场 | 2G 上限仍保留最近多日日志；关键崩溃段在 P1 重建前手动 `journalctl --vacuum` 前导出 |
| 测试镜像清理误删生产 | 仅清理 test-*/v027/sglang tag；生产 `0.2.1-v026.0` 白名单保留；清理前 `docker ps -a` 全量核对 |
| healthcheck 误报触发重建 | P0 只记录不动作；P1 连续失败≥3 才触发，且需窗口演练 |
| systemd 依赖改动引发启动顺序问题 | 默认用 Wants 软依赖；改动前保留原 unit 备份（`.bak-arch-20260817`），可秒级回滚 `cp` 恢复 + daemon-reload |
| 容器 `--restart no` 维持不动的解释 | TP4 协调式重建优于单容器自行拉起，避免 split-brain（写入本方案留档） |

---

## 6. 附录 A：systemd 建议修改 diff（留档待批，不实际修改）

```
--- /etc/systemd/system/vllm-tp4-head.service (现状)
+++ (建议)
 [Unit]
 Description=TP4 vLLM head (rank0) with self-heal
 Documentation=file:///opt/aicad-prod/scripts/start_tp4_head.sh
 After=remote-fs.target network-online.target docker.service
+Wants=network-online.target remote-fs.target docker.service   # 新增 docker 软依赖（或改用 Requires=docker.service，二选一）
-Wants=network-online.target remote-fs.target
 StartLimitIntervalSec=1800
 StartLimitBurst=20
 ...（其余不变）

--- /etc/systemd/system/vllm-tp4-worker.service (02/03/04, 现状)
+++ (建议)
 [Unit]
 Description=TP4 vLLM worker (rank N) with self-heal
 Documentation=file:///opt/aicad-prod/scripts/start_tp4_worker.sh
 After=remote-fs.target network-online.target docker.service
+Wants=network-online.target remote-fs.target docker.service
-Wants=network-online.target remote-fs.target
-RequiresMountsFor=/data/models/deepseek-v4-flash-0731   # 03/04：移除（遗留路径+非挂载点，无实际作用；02 本就无）
 StartLimitIntervalSec=1800
 StartLimitBurst=20
 ...（其余不变）
```

> 决策提示：`Wants`（推荐）＝软依赖，docker 不可用由 monitor 退避兜底；`Requires`＝严格依赖，docker 未起则 unit 不启动。因 docker.service 无自动重启，选 `Requires` 时 docker 故障后需人工 `systemctl start`。
>
> **验证记录（2026-08-17 只读核验）**：`docker.service` 为合法单元（/usr/lib/systemd/system/docker.service，自带 StartLimitBurst=3——docker 连续 3 次启动失败会进入 failed 且不自愈）。该特性进一步支持推荐 `Wants`：若用 `Requires`，docker.service 自身 failed 会把 vllm 拖入不可用且需人工介入；用 `Wants` 则 monitor 退避兜底更稳健。`systemd-analyze verify` 对当前单元与 `Wants=... docker.service` 建议 diff 均通过（无语法/依赖错误）。

## 7. 附录 B：healthcheck.sh 建议脚本（留档待部署，P0 只读版）

```bash
#!/bin/bash
# /opt/aicad-prod/scripts/healthcheck.sh — TP4 vLLM API 健康探针（只读，P0）
# 由 systemd timer 或 cron 每 60s 调用；连续失败 ≥3 次写 critical 标记（P1 由该标记触发重建）
# 部署：chmod +x；归属 <svc-user>；仅需在 <node1> 运行
set -uo pipefail
HEALTH_URL="http://<LAN-IP>:8001/health"
MODELS_URL="http://<LAN-IP>:8001/v1/models"
STATE_DIR="/tmp"
OK_FILE="$STATE_DIR/vllm-healthcheck.ok"
FAIL_FILE="$STATE_DIR/vllm-healthcheck.fail"
CRIT_FILE="$STATE_DIR/vllm-healthcheck.critical"

h=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || true)
m=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$MODELS_URL" 2>/dev/null || true)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$h" = "200" ] && [ "$m" = "200" ]; then
  echo "$ts OK health=$h models=$m" >> "$OK_FILE"
  rm -f "$FAIL_FILE" "$CRIT_FILE" 2>/dev/null
  exit 0
fi
echo "$ts FAIL health=$h models=$m" >> "$FAIL_FILE"
n=$(wc -l < "$FAIL_FILE" 2>/dev/null || echo 0)
# 只保留最近 10 次失败记录用于计数
tail -n 10 "$FAIL_FILE" > "$FAIL_FILE.tmp" && mv "$FAIL_FILE.tmp" "$FAIL_FILE"
if [ "$n" -ge 3 ]; then
  echo "$ts CRITICAL consecutive_failures=$n (P1: 触发 head 全链重建)" >> "$CRIT_FILE"
fi
exit 1
```

> P1 增强：`CRIT_FILE` 出现且 SRE 启用的 watchdog 检测到后执行 `ssh <node1> "docker rm -f vllm-tp4-rank0"` 触发协调式全链重建；重建完成后清 CRIT_FILE。

## 8. 参考文档

- `/opt/aicad-prod/docs/ops/self-recovery.md`（v1.5-R11 自恢复方案）
- `/opt/aicad-prod/docs/ops/fault-tolerance.md`、`server-maintenance-handbook.md`
- `/opt/aicad-prod/docs/tp4-service-deployment-guide-2026-08-13.md`
- `/opt/aicad-prod/docs/production-issues-fix-confirmation-2026-08-17.md`（Rex）
- ADR-015（nccl-tuner-netdev-hardcode，NCCL_IB_PEER_HCA 弃用记录）
- 四机实测：systemd unit / monitor 脚本 / journald / docker / 磁盘 / 模型软链（2026-08-17）
