# 排障手册（Troubleshooting Playbook）v1.1

> **依据**：客户部署实录（2026-09《LuZ-0.1.7 DSV41 TP4 四机环网部署实录》）全部 10 个坑 + 7 个思路错误 + 原 ops §4 错误码表。
> **用法**：按「症状」找行 → 按「根因」确认 → 按「修复」处置 → 按「验证」闭环。
> **总纪律**：物理层优先 → 配置次之 → 应用最后；**「不重现」≠「错」，修复后必须复现原故障再做闭环验证**。

---

## 第一类：NCCL/环网连接故障

### T1. `NCCL error: unhandled system error`，四机同时报，WARN 极少
| | |
|---|---|
| **根因** | 环网接线与库内 per-peer 映射不符（实录坑1：F0/F1 整体装反）。**这是排障第一嫌疑。** |
| **确认** | worker 日志：`rank1 peer0 走 dev rocep1s0f1 → local 10.100.1.3 ↔ remote 10.100.24.1`（不同段 = 物理不直连）；`ibv_modify_qp failed with 110 Connection timed out` |
| **修复** | **四根边 F0/F1 整体对调**（谁连谁不变，八根线全换口）。禁止靠改 `NCCL_IB_HCA` 顺序「软修」——库按物理设备名选 dev，实测配对不变（错误1）。 |
| **验证** | `tools/probe_ring_topology.sh` 实测拓扑逐边比对；若与库默认表不一致，用 `tools/gen_devmap.py` 生成 `NCCL_RING_DEV_MAP` 下发（v5 免重编库）。 |

### T2. `wrap_ibv_reg_mr_iova2 ... Cannot allocate memory`（1400B 都失败）
| | |
|---|---|
| **根因** | 内核版本问题（实录坑2：7.0.0-1019 触发；对 1400 字节握手缓冲注册 MR 失败不是真缺内存） |
| **修复** | 回退已验证内核（如 `6.17.0-1032`），按指南 §1.2 固化 GRUB |
| **验证** | 换内核后该错消失；若随后出现 T1，属正常——前置障碍清掉才暴露下一层问题 |

### T3. NCCL 报错但 `grep 'NCCL WARN'` 返回 0 条（「没有任何警告」）
| | |
|---|---|
| **根因** | `NCCL_DEBUG_FILE` 落到**未挂载进容器**的路径（实录坑4：`/cache`），调试输出静默全丢 |
| **修复** | 改到已挂载路径（如 `/state`）+ `NCCL_DEBUG_SUBSYS=INIT,ENV,NET,GRAPH,TUNING,P2P,PROXY,ALLOC,BOOTSTRAP` |
| **验证** | `tools/doctor.sh` 第 3 项 ok；改完立刻能拿到真因与完整调用栈 |

### T4. 贪多求快：`ibv_modify_qp 110` 只在个别 rank 出现/间歇出现
| | |
|---|---|
| **可能根因** | 部分线/口接触不良；或 topo 与映射部分一致部分不一致（比全反更难查） |
| **修复** | 逐边 probe；检查线缆/笼口；对照 `gen_devmap.py --default` 输出逐格核对 |

---

## 第二类：GPU/系统层故障

### T5. GPU 频率只有 200 MHz 档（应 2392+）
| | |
|---|---|
| **根因** | 锁频单元 `ExecStart` 断行（实录坑5）：systemd 报 `Missing '=', ignoring line`，实际只跑了无参数 `nvidia-smi` |
| **修复** | 换用 `deploy/admin-clock-cap.service`（单行 ExecStart `-lgc 2400,2400`） |
| **验证** | `nvidia-smi --query-gpu=clocks.sm` = 2392-2398；负载时贴住上限（`-lgc` 是工作点不是封顶） |

### T6. 重启后 GPU 消失 / nvidia-smi 报错
| | |
|---|---|
| **根因** | `updates/dkms/` 里的 DKMS 自签模块压过官方模块，Secure Boot 拒签（实录坑3，事故级） |
| **修复** | `mv /lib/modules/<kern>/updates/dkms /root/dkms-quarantine-<date>` + `depmod -a` + `update-initramfs -u -k <kern>`；⚠️ `dkms framework.conf autoinstall=no` 无效 |
| **验证** | `modinfo -k <kern> nvidia | grep signer` = Canonical Ltd.；`tools/precheck.sh` A4 项 ok |

### T7. 重启后掉回旧内核
| | |
|---|---|
| **根因** | `grub-reboot` 只生效一次（坑7）；且 menuentry_id 字符串形式实测无效 |
| **修复** | `GRUB_DEFAULT="1>2"` 数字索引固化 + `grub-editenv ... unset next_entry` |
| **验证** | 重启两次，`uname -r` 稳定 |

### T8. systemd 单元 active 但故障时不重建（自愈静默失灵）
| | |
|---|---|
| **根因** | root 先创建了 `StandardOutput=append:` 日志文件（或 launch.json），`User=admin` 进程写不进（实录坑6） |
| **修复** | `PermissionsStartOnly=yes` + `ExecStartPre=/bin/sh -c 'chown -R ...'`（模板 `deploy/head-monitor.service.example`） |
| **验证** | **杀容器实测自愈**（纪律11）——active 不等于能自愈 |

### T9. `mv` 目录「成功」但什么都没搬
| | |
|---|---|
| **根因** | 目标同名目录已存在 ⇒ `mv /src/engram /dst/` 变成 `mv /src/engram /dst/engram`（坑8） |
| **修复** | 用 `mv /src/engram/*.bin /dst/` 或先 `rsync`；脚本里 mv 后校验目标内容 |

---

## 第三类：配置不生效（静默失败专类）

> 本类共性：**改了 =/= 生效**。全部以「运行时真实状态」为唯一判据。

### T10. 改了 `.env` 里的键但容器里没生效
| | |
|---|---|
| **根因** | 键名不透传（坑9）：`NCCL_IB_HCA` 实际生效键可能是 `IB_HCA`（脚本转发）；`NCCL_DEBUG_FILE` 等须走 `EXTRA_DOCKER_ENV` |
| **验证/修复** | `docker inspect <c> --format '{{range .Config.Env}}{{println .}}{{end}}'` 看**容器真实 env**（doctor 第2项）；改用正确键名 |

### T11. `LD_PRELOAD` 指向的库根本没加载
| | |
|---|---|
| **根因** | **路径不存在 glibc 静默跳过，不报错**（错误4）；`strings libnccl.so | grep XX` 为空也不代表功能缺失——可能被硬编码替代（错误3） |
| **验证** | doctor 第 4 项（路径存在）+ 第 6 项（`RING-ONLY` 日志 ≥1 条，库生效铁证）；权威锚点=生产库 md5 快照 |
| **连带教训** | 「vLLM 能跑通」≠ ring-only 可用——vLLM 镜像可能压根没有那条路径，跑的是普通 NCCL（错误4） |

### T12. 四机鉴权行为分裂（有的 401 有的 200）
| | |
|---|---|
| **根因** | `API_KEY` 四机不同值（坑10）——脚本仅在其非空时注入 |
| **验证/修复** | doctor 第 9 项四机指纹比对；统一后重启全链 |

### T13. 带宽 108.5 Gb/s，怀疑「性能降级」
| | |
|---|---|
| **结论** | **不是降级**。108.4–108.6 就是 GB10 上 200G 单口的实际上限（55% 线速，官方 2hop 报告 §实测）；真正降级是掉到 12.5 Gbps 那种差一个量级的（错误5） |
| **判断法** | 带宽「低」先查上限基线，再判故障 |

---

## 第四类：原生产运维错误码表（ops §4 沿用）

| 现象/错误码 | 判定 | 响应动作 |
|---|---|---|
| head API 不通 / curl 000 | head 未就绪或崩溃 | 查 TCPStore 端口监听；head-first 重来；权重加载 5-8 分钟属正常 |
| 容器 Up(restarting) 循环 | 自愈反复失败 | `journalctl -u <svc> -n 100`；NCCL 日志（先确认 T3 已修）；banner 验库已加载 |
| KV 不足 / OOM | util/seqs 过高 | 清 buff/cache；降 max-num-seqs 或 util；勿动 max-model-len |
| prefix 命中 0 | 缓存未生效 | 确认参数在 rank0；请求需含相同前缀 |
| 单 rank 掉线但 head API 200 | worker 故障 | 互杀守卫自动处置，人工勿插手，观察 5 分钟 |
| healthy 但推理超时 | 队列积压 | 等待；`/v1/models` 确认模型名；网关并发满则排队 |

---

## 附：思路错误自查表（改配置前对照，实录 7 错误浓缩）

1. **只信实测不信推断**——HCA 顺序、env 名、文档描述都可能是错的；`tools/probe_ring_topology.sh` + `doctor.sh` 的实测输出优先。
2. **有引用链就顺链走**——主仓库找不到的东西先查兄弟仓库（`dgxspark-tp4-deploy-kit` 等），别在原地打转。
3. **strings 为空 ≠ 功能缺失**——用 md5 权威锚点判定库身份。
4. **能跑通 ≠ 用了它**——LD_PRELOAD 路径不存在不报错。
5. **「低」先查上限**——108.5 Gb/s 是上限不是故障。
6. **物理层优先**——线插对没、口对应没，先实测再动配置（连续两轮在应用层打转的教训）。
7. **改前必备份**——`cp <file> <file>.bak-<date>`，否则只能靠记忆回退（错误7）。
