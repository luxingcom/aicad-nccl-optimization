# sudoers NOPASSWD 白名单方案（B 类·待批）

**编制**：泰莎（Tessa）· QA | 工程保障团队
**日期**：2026-08-17
**状态**：⏳ 待 team-lead / 用户批准后执行（不动手）
**目的**：替代脚本内 `echo <sudo密码> | sudo -S <cmd>` 模式，消除明文密码提权路径

---

## 1. 背景与目标

- 现状：v027-test/preflight_v027.sh、/opt/2hop-s1/ 等脚本内嵌明文 sudo 密码（AS12******）通过 `echo ... | sudo -S` 提权（P0/P1）。
- 目标：脚本不再携带密码，改为 `sudo -n`（无密码 NOPASSWD），仅授权运维所需的最小命令集合。
- 约束：不破坏现有运维流程；四机一致；失败可回滚（删除 sudoers 文件即恢复）。

## 2. 方案设计

### 2.1 sudoers 文件（四机一致）

新增 `/etc/sudoers.d/aicad-ops`（**0600 root:root**，语法校验 `visudo -c`）：

```sudoers
# AICAD DGX Spark 运维 NOPASSWD 白名单（QA 整改 2026-08-17）
# 原则：仅授权运维必需命令；禁止 shell/任意命令（防止 sudo 逃逸）
Cmnd_Alias AICAD_DOCKER_READ = /usr/bin/docker logs, /usr/bin/docker exec, /usr/bin/docker cp, /usr/bin/docker inspect, /usr/bin/docker ps
Cmnd_Alias AICAD_DOCKER_MGMT = /usr/bin/docker start, /usr/bin/docker stop, /usr/bin/docker rm, /usr/bin/docker run
Cmnd_Alias AICAD_FS = /usr/bin/mkdir, /usr/bin/md5sum, /usr/bin/timeout, /usr/bin/chmod, /usr/bin/chown
Cmnd_Alias AICAD_SVC = /usr/bin/systemctl status, /usr/bin/systemctl restart vllm-tp4-head.service, /usr/bin/systemctl restart vllm-tp4-worker.service

<svc-user> ALL=(root) NOPASSWD: AICAD_DOCKER_READ, AICAD_DOCKER_MGMT, AICAD_FS, AICAD_SVC
```

> ⚠️ 风险提示：`docker exec/run` 白名单本身可提权（docker exec 进容器 → root）。本环境为受信内网 + 单运维账号，接受该风险；如需更强约束，可把 docker exec/run 从白名单移除（2hop/v027 已归档，实际上仅 monitor/自愈与镜像管理需要）。

### 2.2 脚本改造（与 D 类 chmod 同步）

| 脚本 | 现状 | 改后 |
|---|---|---|
| v027-test/preflight_v027.sh | `echo 密码 \| sudo -S docker logs` | `sudo -n docker logs`（已归档测试用；若保留则改） |
| 2hop-s1/*.sh | `sudorun() { echo 密码 \| sudo -S "$@"; }` | `sudorun() { sudo -n "$@"; }` |
| shim-deploy.sh | `SUDO_PW` 环境变量/交互 → `sudo -S` | 增加 `sudo -n` 优先分支（无密码时直接 sudo -n） |
| start_tp4_cluster.sh | 已用 `sudo -n`（NOPASSWD）读 env | 无需改（现状即目标形态）✅ |

### 2.3 验证与回滚

1. 部署前：`visudo -c`（语法校验，通过才生效）。
2. 部署：四机 scp + `chmod 600` + 语法校验 + 各机抽测 `sudo -n docker ps`（无需密码）。
3. 脚本改造后：`bash -n` 全过 + 抽跑一个只读命令（`sudo -n docker logs ... | tail`）验证。
4. 回滚：删除 `/etc/sudoers.d/aicad-ops` + 恢复脚本 .bak（bash -n 通过）。
5. 若某命令不在白名单 → sudo 会要求密码 → 脚本报错可观测，追加白名单即可（避免静默失败）。

## 3. 影响评估（现状脚本盘点）

| 影响面 | 数量 | 处置 |
|---|---|---|
| 需同步改造的脚本（内嵌 `echo 密码 \| sudo -S`） | v027-test preflight（1）+ 2hop-s1（8 脚本 + 1 bak） | 2hop 已 D 收尾：建议随归档一并改造或直接退役；v027 已归档 |
| 需增加 `sudo -n` 分支 | shim-deploy.sh（1） | 小改 |
| 不受影响（已 NOPASSWD/无 sudo） | 生产启动/自愈脚本（start_tp4_head.sh 等）、systemd、cron | 无需动 |

**关键结论**：当前实际仍在使用 sudo 的**生产脚本**仅 start_tp4_cluster.sh（已 NOPASSWD 形态）与 shim-deploy.sh（部署工具，非运行中）；内嵌密码的脚本均为**已归档测试脚本**。因此 sudoers 白名单切换对生产运行**几乎无影响**，主要收益是根除测试脚本中的明文密码。

## 4. 执行步骤（批准后）

1. 四机部署 sudoers 文件（0600 root:root + visudo -c）。
2. 改造 shim-deploy.sh（加 sudo -n 分支）+ v027 preflight（若保留）+ 2hop 脚本（随归档处置）。
3. 全部改后 bash -n + 只读抽测。
4. 与 A 类（轮换 sudo 密码）联动：轮换后旧密码失效，白名单不依赖密码 → 双保险。

## 5. 备选/增强

- 若不想给 docker 宽泛白名单：可对 2hop/v027 直接退役删除（已在归档），只给生产需要的 `docker logs/exec/inspect/ps` + `systemctl status` 只读项。
- 更严格：sudoers 中 `<svc-user> ALL=(root) NOPASSWD: ALL` 的**否定项**方案不推荐（白名单优于黑名单）。

---

*落盘：本地 deliverables/engineering-assurance/nccl-sudoers-nopasswd-plan-qa-2026-08-17.md（待批，未部署）*
