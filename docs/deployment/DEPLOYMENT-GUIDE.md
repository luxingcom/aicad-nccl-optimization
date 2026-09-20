# DGX Spark GB10 四机环网 TP4 部署指南（deploy-kit v1.1）

> **适用**：4× DGX Spark GB10（SM121）· 无交换机 RoCE 环网 · TP4 推理栈（vLLM/SGLang 均适用）
> **版本**：v1.1（2026-09-19）｜ **配套补丁**：`patches/v5-netdev-configurable.patch`（ADR-016）
> **依据**：生产实录《LuZ-0.1.7 DSV41 TP4 四机环网部署实录》（2026-09）+ 8/17 生产基线包
> **铁律**：物理层优先 → 配置次之 → 应用最后。每一节的【验证】不过，禁止进入下一节。

---

## §0 部署总览与工具链

```
  ┌─────────────────────────────────────────────────────────────┐
  │ Phase 1 系统层    precheck.sh     内核/驱动/GRUB/DKMS/锁频   │
  │ Phase 2 物理层    netplan模板 + probe_ring_topology.sh 实测  │
  │ Phase 3 定制库    patches v1+v5+stageB 重建 ring-only 库     │
  │ Phase 4 组件部署  netplan/env/systemd 模板 + gen_devmap.py   │
  │ Phase 5 起栈      start-tp4.sh serve（或现场等价编排）        │
  │ Phase 6 验收      doctor.sh + needle/并发/自愈 实测           │
  └─────────────────────────────────────────────────────────────┘
```

| 工具 | 用途 | 对应实录教训 |
|---|---|---|
| `tools/precheck.sh` | 四机一致性 + 系统层预检（fail-closed） | 坑2/3/5/7、错误6 |
| `tools/probe_ring_topology.sh` | 实测环网拓扑（唯一探针 IP + MAC） | 坑1、错误1/6 |
| `tools/gen_devmap.py` | 拓扑 → `NCCL_RING_DEV_MAP`（免重编库） | 坑1、ADR-016 |
| `tools/doctor.sh` | 运行期体检（env/LD_PRELOAD/鉴权/错误签名） | 坑4/9/10、错误4 |
| `deploy/*` | netplan / systemd / env 修正版模板 | 坑5/6、错误7 |

---

## §1 Phase 1：四机系统层预检（最容易漏，也最容易出事）

### 1.1 逐项四机比对

```bash
# 一键预检（fail-closed：任何 FAIL 都必须处置后重跑）
bash tools/precheck.sh --ips <ip1>,<ip2>,<ip3>,<ip4> \
     --expect-kernel 6.17.0-1032-nvidia --expect-driver 580.178.04 --svc-user admin
```

必须四机一致的项：**内核 / 驱动 / 环网口 MTU=9000 / 全部 RoCE 口 state=4:ACTIVE / GRUB 固化 / 无 DKMS 残留**。

### 1.2 内核（实录坑2/坑7）

实录教训：错误内核 `7.0.0-1019` 导致 `ibv_reg_mr_iova2` ENOMEM（1400 字节握手缓冲都注册不了，不是真缺内存）；回退 `6.17.0-1032` 后错误消失。

```bash
apt-get install -y linux-image-6.17.0-1032-nvidia linux-modules-6.17.0-1032-nvidia \
                   linux-modules-nvidia-580-open-6.17.0-1032-nvidia linux-headers-6.17.0-1032-nvidia
# 永久设为默认：数字索引（menuentry_id 字符串实测无效）
sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="1>2"|' /etc/default/grub && update-grub
grub-editenv /boot/grub/grubenv unset next_entry   # 清掉 grub-reboot 一次性残留
reboot
```

⚠️ **不要动驱动**——模块包里的 `nvidia.ko` 版本即用户态驱动版本。
⚠️ `grub-reboot` 只对下一次启动有效；上线必须固化成 `GRUB_DEFAULT`（坑7）。

**装新内核前必查（坑3，事故级）**：

```bash
dkms status                                   # 有 DKMS 残留 → 高危
ls /lib/modules/6.17.0-1032-nvidia/updates/dkms 2>/dev/null   # 存在 → 必须隔离
# 隔离（不删包、不动驱动）：
mv /lib/modules/6.17.0-1032-nvidia/updates/dkms /root/dkms-6.17-quarantine-$(date +%Y%m%d)
depmod -a 6.17.0-1032-nvidia
modinfo -k 6.17.0-1032-nvidia nvidia | grep signer   # 必须是 Canonical Ltd.
update-initramfs -u -k 6.17.0-1032-nvidia            # initramfs 也要重建！
```

> 坑3 机理：`updates/dkms/` 优先级高于 `kernel/`，DKMS 自签模块（Secure Boot 不认）会压过 Canonical 官方模块 ⇒ 一重启 GPU 直接消失。
> ⚠️ `dkms framework.conf autoinstall="no"` 无效——hook 走 `dkms_autoinstaller`，必须物理隔离目录。

**验证**：`bash tools/precheck.sh`（本机模式）全绿。

### 1.3 GPU 锁频（实录坑5）

⚠️ 实录坑5：单元 `ExecStart` 断行 ⇒ 只执行了无参数 `nvidia-smi` ⇒ 锁频从未生效（GPU 跑 208 MHz）。**部署统一使用本仓库修正版**：

```bash
# 用 deploy/admin-clock-cap.service（ExecStart 单行、参数完整），装到四机：
install -m 644 deploy/admin-clock-cap.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now admin-clock-cap
```

GB10 陷阱：`-lgc 0,2400` 是软上限只跑 2242；必须写 `2400,2400`。

**验证**：`nvidia-smi --query-gpu=clocks.sm --format=csv,noheader` → 期望 **2392-2398**（四机一致）。

---

## §2 Phase 2：环网接线与 IP（本方案最脆的一环）

### 2.1 物理拓扑（必须与库内映射一致）

每台机两张 ConnectX-7 双口卡共 4 个 RoCE 口：**F0**（靠近 RJ45）/ **F1**（远离 RJ45）。
**每条环边 = 2 根线**（相邻两机各出一根，同一个 F 号）。

```
环序示例（实录拓扑）：  .130(r0) —f1— .17(r1) —f0— .18(r2) —f1— .129(r3) —f0— .130
```

### 2.2 IP 布局

用 `deploy/netplan-99-qsfp.yaml.example` 填实地址；**同一 /29 段的两台 = 物理直连对**。
权限 `root:root 600`，四机全部写完再逐台 `netplan apply`。
控制面（10G/WiFi）混用没问题，四机互 ping 通即可。注意部分机器重启后控制口可能丢 IP：`nmcli dev connect <iface>`。

### 2.3 实测拓扑（唯一可信来源，实录坑1/错误1）

实录坑1：接线 F0/F1 整体装反 ⇒ 四机同时 `NCCL unhandled system error`；错误1：试图靠改 `NCCL_IB_HCA` 顺序「软修」⇒ **库按物理设备名选 dev，配对完全不变**，白费两轮。**唯一修法是动物理线；唯一验证是实测拓扑**：

```bash
# 每台机对本机全部环网 IP 探一轮（探针期别在多台机同时跑，避免 neigh 表互相污染）
bash tools/probe_ring_topology.sh --ping 198.51.100.1,198.51.100.2,198.51.100.1,198.51.100.1 \
     --label rank0-probe --out probe-rank0.json
# 四机各出一份 JSON；逐条核对「谁连谁、走哪个口」与规划一致。
# 任何一条边对不上 ⇒ 动线，不是动配置。
```

### 2.4 拓扑 → 设备映射（ADR-016，免重编库）

```bash
# 1. 按实测结果写 topology.json（格式见 gen_devmap.py 头注释）
# 2. 校验 + 生成
python3 tools/gen_devmap.py --topology topology.json --verify
python3 tools/gen_devmap.py --topology topology.json      # 打印 NCCL_RING_DEV_MAP + json
# 3. 与库内默认一致时可不设 env；不一致时把生成串写入 nccl-ring.env（见 deploy/nccl-ring.env.example）
```

---

## §3 Phase 3：ring-only 定制库

### 3.1 补丁栈（v5 起取代 v4）

```bash
git clone https://github.com/NVIDIA/nccl -b v2.30.7-1 nccl-2307 && cd nccl-2307
git apply patches/v1-ring-only.patch            # 环邻过滤
git apply patches/v5-netdev-configurable.patch  # 可配置 per-peer 映射（内建=v4 生产默认表）
git apply patches/stageB-tuner-two-band.patch   # per-size tuner
git apply patches/stageB-hardened-two-branch.patch  # 双分支加固
make -j src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE=-gencode=arch=compute_121,code=sm_121
# 产物 build/lib/libnccl.so.2.30.7 → 四机同 md5 安装；md5 记入验收单
```

构建容器 glibc 必须 ≤2.35（与生产镜像匹配，GLIBC 版本阻断史见 `patches/README.md` §5）。
**Windows 下载本仓库后**：确认补丁为 LF 行尾（`.gitattributes` 已强制）；若经其他渠道传输，用 `dos2unix patches/*.patch` 兜底。

### 3.2 v5 的三种运行形态

| 配置 | 行为 |
|---|---|
| 不设任何新 env | 内建 v4 默认表（与 ADR-015 生产库逐位一致） |
| `NCCL_RING_DEV_MAP=r0:...` | 运行期覆盖（优先） |
| `NCCL_RING_DEV_MAP_FILE=...` | 文件覆盖（容器内须可读） |

配置非法时**不崩**：WARN + 回退内建默认表；日志出现 `RING-ONLY v5: per-peer dev map from ...` 即覆盖生效。

---

## §4 Phase 4：组件部署

- env：`deploy/nccl-ring.env.example`（坑9/10、错误4 已内建为注释级检查项）。
- systemd：`deploy/head-monitor.service.example`（坑6 修正：`PermissionsStartOnly=yes` + `ExecStartPre` chown，根治 root 建文件导致自愈静默失灵）。
- 改任何配置前先备份：`cp <file> <file>.bak-$(date +%Y%m%d)`（错误7）。

---

## §5 Phase 5：起栈

```bash
./start-tp4.sh doctor      # 干跑（或现场等价编排的预检模式）
./start-tp4.sh serve       # worker-first 3→2→1→0，冷启约 12 分钟
./start-tp4.sh status
```

---

## §6 Phase 6：验收（配置 + 持久化 + 自愈 + 数据，缺一不算完成）

```bash
# 1. 体检（env 真实性 / LD_PRELOAD / RING-ONLY 日志 / 鉴权 / 错误签名）
bash tools/doctor.sh --container <head容器> \
     --api-endpoint http://127.0.0.1:8899 --api-key-file ~/state-tp4/api-key

# 2. 冒烟
curl -s http://127.0.0.1:8899/v1/chat/completions -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"17*19=?"}],"max_tokens":32}'
# 期望 "323"；再加 1234+5678→6912 与中文解释

# 3. 长上下文 needle + 并发吞吐（实录验收口径：200K/470K needle，C1→C16 吞吐阶梯）

# 4. 自愈实测（纪律11：杀容器看它能不能回来）
docker kill <head容器> && sleep 180 && bash tools/doctor.sh
# 5. 整机重启验证：四机 reboot → 全自动恢复（含 GRUB 固化、锁频、自启链）
```

验收数据留档（对照 `deploy/ACCEPTANCE-CHECKLIST.md`）。

---

## 附：实录验收参考值（4×GB10，SGLang TP4/EP2，600K ctx / 9.6M KV / 16 并发）

| 项 | 参考值 |
|---|---|
| 冒烟 | 17×19→323、1234+5678→6912、中文 ✓ |
| needle | 200K(177,809 tok) ✓ 92.0s；470K(417,809 tok) ✓ 216.6s |
| 并发吞吐 | C1 72.6 → C4 165.3 → C8 241.6 → **C16 392.8** tok/s（16/16 成功） |
| DSpark | spec_accept_length 2.47–2.49 |
| 环网单口带宽 | **108.4–108.6 Gb/s 即为 GB10 上限，不是降级**（错误5：4MB 313µs≈13.4GB/s 单口=55% 线速） |
| 冷启 | ≈12 分钟（权重加载 5-8 分钟属正常） |
