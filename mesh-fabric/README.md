# mesh 硬件转发层（switchless RoCE ring fabric）—— 四机 DGX Spark 全套基础设施

> 本目录收录 **CX-7 无交换机 RoCE 环网的硬件转发层全套**：拓扑生成器、硬件 tc hairpin
> 规则、驱动层 hairpin 队列与 PFC/trust 预置、RDMA-TX 源标记探针、systemd 引导单元、
> netplan 正典、守卫/自愈套件与三份定谳文档。与仓内 NCCL ring-only 优化件
> （patches/deploy/results）配合构成完整通信栈——本层解决「包怎么在四机环上走」，
> NCCL 层解决「包怎么被高效消费」。

## 一、架构一览

```
        [01 head] ──f0──→ [02]        环上每节点：对角节点流量经邻居硬件转发
           ↑  ↺            ↑ f1       （tc flower skip_sw + mirred redirect，
        f1 │    f0         │            in_hw 硬件落地，CPU 零拷贝）
           [04] ←──f0── [03]
```

- **物理层**：4×ConnectX-7（每机双口 f0/f1），DAC 直连成物理环，每条 DAC 独立 /24 子网。
- **硬件转发**：对角（opposite-node）流量由邻居网卡 tc flower 规则 **in_hw 硬件重定向**
  （改 EtherType 0x88b5→0x0800 + 改 dst MAC + mirred egress redirect），交换机无、
  CPU 不经——对照外部交换机同内核 **1.548×** 劣势定谳（见 docs/RING-FACE-3REF）。
- **源标记**：RDMA-TX 源端口 65535→EtherType 0x88b5 改写探针
  （`bin/mlx5-rdma-tx-rewrite-probe`，构建自 FujitsuPolycom/sparkring
  `spark_transport/fabric/cx7_hairpin_diagonal/native/mlx5_rdma_tx_rewrite_probe.c`，
  f16b5f4 实测基线）——让纯 RDMA 流量可被 tc flower 分类。
- **驱动预置**：`hairpin.sh`（mlx5 `hairpin_queue_size` 1024→8192，driverinit，
  reinit 断链警告：**引擎在跑禁改值**）；`qos.sh`（trust dscp→**pcp**——6.17-nvidia
  mlx5 仅 PCP trust 支持 hairpin offload；PFC 3/5 保配置但转空闲）。
- **引导序**：`dsv41-mesh.service`（oneshot，RemainAfterExit）= 等四口 up →
  hairpin.sh 8192 → qos.sh（**必须后于 hairpin**：reinit 会把 trust 打回 dscp）→
  mesh-up.sh（clsact + 硬件规则 + /32 对角路由 + 重启双口 marker）。

## 二、文件清单

| 件 | 说明 |
|---|---|
| `plan.py` / `inventory.sh` / `fabricctl` | **拓扑生成器**（switchless ring 规划全套）：SSH 盘点四机 → 读 DAC 子网布线 → 按 sparkring 规划器（cx7_hairpin_diagonal/fabric.py）生成 per-rank 两条 /32 对角路由+两条硬件 tc 规则+双源标记 → 产出 `mesh-up-<host>.sh`/`mesh-down-<host>.sh`/`fabric.json`/`env.txt`。用法：`python3 plan.py --sparkring ~/sparkring --out ring-mesh HEAD W1 W2 W3`（TP rank 序 SSH 名） |
| `systemd/dsv41-mesh.service` | 引导单元（产线在役形；enabled，WantedBy=multi-user.target） |
| `systemd/dsv41-mesh-marker@.service` | RDMA-TX 源标记模板单元（%i=RoCE 口名，双口各一实例） |
| `scripts/mesh-up.sh` / `mesh-down.sh` | **01 head 生成形示例**（含本机 MAC/pref；他机以 plan.py 重生成，MAC/子网/前缀不同） |
| `scripts/hairpin.sh` / `qos.sh` | 驱动预置（幂等；顺序律见上） |
| `netplan/97-roce-mtu.yaml` | MTU 9000 + DAC /24 编址 + 邻居路由（正典形） |
| `netplan/99-nvidia-sync-cluster.yaml` | NVIDIA sync 生成形参考件（f1 口地址/MTU/路由正典化收编位） |
| `topology.json` | **Q3bA 正典拓扑**（10-14 收编形；`topology.json.bak-pre-q3ba` 前形留档于产线 /opt 位） |
| `bin/mlx5-rdma-tx-rewrite-probe` | 源标记探针二进制（md5 见下；学习交流用途，上游源码为准） |
| `guards/` + `diag/` + `lutune.sh` | 守卫/自愈套件：`fabric-guard`（drift 巡检）+`fabric-gid-heal`（**断电 GID 表出洞修复**，唯一 auto_ok 守卫）+`fabric-restore-gate`+`fabric-sentinel`+`fabric-doctor`+`s4_bench`+`lutune`（RX 4096 调优） |
| `docs/RING-NETWORK-RESEARCH-REPORT-20261002.md` | 九章总卷研究报告（四层架构/E1 −13.2%/fin2 桶分解/八类失败机理/I14 D1-D5） |
| `docs/RING-FACE-3REF-COMPARISON-20261002.md` | 三参考对照定谳（sparkring hairpin 对角/mesh hairpin 队列/NCCL ring-only 等价实现逐件判读） |
| `docs/RING-FACE-LANDING-VERIFICATION-20261002.md` | 落地验证档（外部交换机 1.548× 对照等） |

**探针二进制 md5**：`mlx5-rdma-tx-rewrite-probe` = `5262d17d…`（01 机 /opt/dsv41-mesh/bin
在役件逐字节拷贝；重编译以上游 sparkring 源为准）。

## 三、部署序（新机从零）

1. netplan 正典落位（97+99）→ `netplan apply`；四口 up、MTU 9000、IB port state ACTIVE。
2. `hairpin.sh 8192`（**引擎必须停机**——reinit 断 RDMA 链接；boot 期执行无此忧）。
3. `qos.sh`（trust=pcp；**必须后于 hairpin**，reinit 回置 dscp）。
4. `systemctl enable --now dsv41-mesh.service`（内部依序调 2→3→mesh-up，幂等可重跑）。
5. 验证：`tc -s filter show dev <口> ingress` 各规则须见 **in_hw**（软件落地=exit 3
   fail-closed）；`systemctl is-active dsv41-mesh-marker@rocep1s0f0 …` 双实例 active；
   `ip route show exact <对角/32>` 双路由在位。
6. NCCL 侧：接仓内 ring-only 栈（`DSV41_ROCE_RING` 单键+GID idx3 纪律，见 README §部署）。
7. 守卫常驻：fabric-guard.timer + fabric-sentinel（drift 巡检/熔断人工复位）；
   断电后 GID 出洞 → `fabric-gid-heal.sh`（洞口 IP 环回重建；兜底=四机整体切 GID=2 勿单机改）。

## 四、纪律与出处

- **GID idx3**：判读线零改（`fabric-gid-heal` 之外禁改 GID 选择）；DEVLIST 白名单硬界。
- **熔断人工复位**：fabric-guard 熔断态不自动复位（防振荡）。
- **宿主守护件不入容器镜像**（「载荷不是运行时守卫」律——/proc/sys/cgroup 判据全来自宿主接口）。
- **出处**：生成器与规划语义参考 FujitsuPolycom/sparkring
  `spark_transport/fabric/cx7_hairpin_diagonal`（f16b5f4 实测基线）；本目录脚本为
  四机产线在役形的并档快照（2026-10-14，LuZ-0.3.1 交付战役收录）。Apache-2.0，
  学习研究交流用途，同仓根免责声明。
