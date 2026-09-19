# 采坑全录 — W1/W2/W3 全部实锤坑（症状/机理/修复/教训）

按时间序编号；★ = 影响过结论判断的大坑。

---

## W1 轮（M1 落地期）

### 1. rank 字节接收高位保留 ★
- 症状：对端 rank 恒被判非法
- 机理：`int r=-1; recv(fd,&r,1,...)` 只写低 8 位，高位保留 0xFF → 负数
- 修复：初始化 `int r=0`（proto v2 同款教训，控制面首字节自报协议的固有陷阱）
- 教训：单字节收进多字节类型时必须显式清零

### 2. 同 socket 重试 connect 必废
- 症状：240 次"重试"全部秒败，貌似网络故障
- 机理：ECONNREFUSED 后 fd 已死，复用 fd 的 connect 永远失败
- 修复：每轮重建 socket
- 教训：TCP 重试的单位是"连接"不是"调用"

### 3. --peers 悬挂指针
- 症状：cfg.peer_ips 指向已 free 的栈/堆，inet_addr 得到垃圾地址
- 机理：CLI 解析临时串 free 后配置仍存指针
- 修复：probe 端改 static std::string 存储
- 教训：C API 存 char* 就等于存下生命周期责任，必须写进文档（API.md 已注明）

### 4. 门铃跨轮超前误判（engine_wait）
- 症状：done(m) 等待期间对端 dbellA 已到 m+1 → 误报协议错误
- 机理：跨轮视角里"超前 1"合法（对端 stage 不依赖本端完成）；轮内严格性归 kernel wait_two
- 修复：engine_wait 去掉该判定；kernel 侧改为有界偏斜容忍（ALGORITHMS §4）
- 教训：同一数值在不同观察层语义不同——分层定义严格性

### 5. op 入口缺 abort 预检
- 症状：对端死后继续 post → QP transport retry 拖 ~3.5s
- 修复：入口查 abort 字 + 门铃 ABORT flag，命中直接走 abort_path
- 教训：post 前的死亡检查是延迟救命的（尤其错误路径总耗时）

### 6. CPU 后端槽步长用 op 字节而非 smax
- 症状：CPU 后端随机错值
- 机理：post 路径按 smax 步长寻槽，CPU 里程碑路径却按当次 bytes
- 修复：统一 `slot × p.smax`
- 教训：槽寻址公式必须单点定义（现已三方同式注释强约束）

### 7. dbell==0 被当 magic 错误
- 症状：偶发"瞬时就报 PROTOCOL"
- 机理：初始 0 值/轮换窗口的 0 是"未到达"，不是损坏
- 修复：wait_two/wait_dbell 零值容忍
- 教训：协议字必须区分"空态"与"坏态"

### 8. docker exec 不传播 timeout 信号 → 僵尸占端口 ★
- 症状：上一轮 probe 僵尸持 9500 端口，下一轮 bind 失败
- 机理：外层 timeout 杀的是 docker exec 客户端，容器内进程存活
- 修复：runbook 跑前/跑后 `pkill -9 ar2_probe`（现已固化进 run_s2.sh/run_reg.sh）
- 教训：容器化编排里信号边界=exec 边界，清理责任在容器内

## W2 轮（M2 调查期）

### 9. host 写 seq 映射字在 graph replay 下有旧值窗口 ★
- 症状：~136 replay 后 kernel 带旧 seq 执行（want=23 obs=1160 实锤）
- 机理：host 跨 replay 重写映射字与 kernel 执行存在竞态窗口
- 修复：seq 改 **device 执行时原子 claim**（atomicAdd_system，SparkRing graph_publish_command 同型）
- 教训：凡 graph replay 会重放的路径，状态写入方必须是"执行时"方

### 10. 判别实验设计（方法论）
- m1 单缓冲 1020 op 全绿 + NOPS=2 必败 → 正确推出"多缓冲 layering 触发"
- 但当时把"数据面损坏"与"协议错账"混为一谈，未料到还有测试器自身因素（见 #13/#15）
- 教训：判别实验的观察工具本身也要被怀疑（对照 #15 教训）

## W3 轮（根治期——本轮 8 个）

### 11. 容忍后首次周校验期望 ==10.0f ★
- 症状：iter50 全 buf "WRONG"
- 机理：时序循环每调用值 ×4（10→40→160…），期望却写死 10.0
- 修复：几何级数期望；随后又发现需 bf16 溢出语义对齐（inf==inf）
- 教训：校验器期望值是代码，错误期望与被测物错误不可区分

### 12. ★★ 跨机二进制分发事故（本窗口最大干扰源）
- 症状：rank0 收到"无指纹"数据；四机结果不一致
- 机理：远端容器挂载**各自宿主机**的目录副本——rsync 之前跑的是旧 probe/旧库，跨版本混跑产生一切假象
- 修复：rsync + 四机 md5 核对（BUILD-TEST §1 固化）
- 教训：与镜像"同 tag 异 ID"同一家族——**内容级校验是唯一裁决**，任何"我刚编译过"的假设都要四机验证

### 13. ★★ probe refill 竞态伪影（"M2 数据冻结"真凶）
- 症状：所有 buf 在同一次 replay"冻结"在旧代值；kernel 金丝雀显示读到的 x 是初值
- 机理：verify 后的 H2D refill 在**默认流**执行，与 ar2 流（非阻塞）**无同步**——refill 赢得竞态则
  整代增长被重置；叠加期望公式错位，呈现为"协议层数据损坏"
- 定位：整数指纹（buf 间可区分）+ 引擎每 op 槽快照 + kernel 金丝雀三级取证；NO_GRAPH 二分排除 graph
- 修复：时序循环**删除 refill**，期望从 verify 态起算
- 教训：**校验器的每一步 host↔device 交互都是被测系统的隐形邻居**——异步流体系里没有"纯观察者"；
  伪影的特征是"确定性复现 + 与观察模式相关"（改校验周期，故障点跟着动 = 强烈信号）

### 14. 宿主机 glibc > 容器 glibc
- 症状：容器内 `GLIBC_2.38 not found`
- 机理：宿主 2.38 构建的动态二进制进 2.35 容器
- 修复：baked 镜像容器内构建（自带 CUDA 13.0；cmile pip 装）
- 教训：交付二进制的 glibc 下界 = 目标运行环境，不是构建机

### 15. 校验器观察者效应误读
- 症状：CHECK_EVERY=1 后"故障 onset"从 416 op 提前到 ~17 op → 误判为"时序敏感竞态"
- 机理：onset 只是**首个被采样到的错误点**，采样密度改变当然移动它；确定性复现（逐字节相同）其实是
  伪影的指纹而非竞态的
- 教训：区分"onset 移动"（采样问题）与"故障是否发生"（发生学问题）；真竞态=每次不同，伪影=完全一致

### 16. log_mark 引用绑定 bug
- 症状：取证环同 seq 散落多个槽、时间戳为负
- 机理：`OpLogE &e = arr[i]` 在环推进后仍绑旧槽（引用在函数入口绑定）
- 修复：推进后重新绑定
- 教训：容器/环结构里"先移动游标再取引用"的顺序要用代码结构强制

### 17. bench 管道 tail 吞输出 + timeout 截断
- 症状：PR 25 分钟被 1500s timeout 杀（exit 143），且 `| tail -30` 导致中间输出全丢
- 修复：`python3 -u` 直写日志文件 + 后台 + 加大时限
- 教训：长基准永远直写文件；前台管道改变缓冲与退出语义

### 18. pgrep 自匹配
- 症状：轮询命令 `pgrep -f bench_v2` 匹配到自身命令行（含日志路径）→ 误报 "still running"
- 修复：模式避开自身参数或按进程名匹配
- 教训：pgrep -f 的全命令行匹配会咬尾

---

## 伪影 vs 真缺陷的判别手册（沉淀）

| 特征 | 指向 |
|---|---|
| 故障点随观察方式移动（校验周期/日志开关） | 伪影或观察扰动 |
| 逐字节确定性复现（跨运行完全一致） | 逻辑错位（伪影/公式错）而非竞态 |
| 四机完全对称同时故障 | 共因（测试器/环境），分布式协议自身缺陷通常非对称 |
| 单缓冲绿/多缓冲红 | 触发面在缓冲交替层（但也可能只是观察路径不同，先查观察器） |
| 改缓存序内在函数（stwt/ldcv）无变化 | 大概率不是可见性/缓存问题 |
| kernel 金丝雀与 host 快照矛盾 | 优先怀疑两者的读取路径（流/缓存/refill），再怀疑协议 |

## 2026-09-04 E2E 窗口新增

1. **启动期相位错位（E2E #1/#2 定谳）**：vLLM dspark warmup（eager 小 AR）与 capture（原生录制、
   延迟到 replay 执行）在 4 rank 间无全局栅栏。本端 ar2 门铃等不到"已录进 graph"的对端 → 5s 超时。
   教训链：初版抛 ncclInternalError 直接击穿启动链 → 降级版遇非对称 abort 竞态出 GPU IMA →
   终版 fence-arm（捕获后首个大 AR 触发点 + 控制面栅栏）根治。**任何 per-rank 本地判据都不能
   保证跨 rank 分发决策一致；需要全局一致时必须找"全 rank 同逻辑必经"的仲裁点。**
2. **atexit 计数依赖正常退出**：vLLM mp worker 被 SIGKILL（docker stop 的强制段/崩溃路径）不跑
   atexit → 长跑计数丢失。粗粒度 progress 报点（每 65536 op）是必要的兜底。
3. **heredoc 事故残留**：早期编辑把 `'\0'` 写成真实 NUL 字节（语义碰巧等价能编译）、`"\n"` 变
   `\\n`（诊断输出丢换行）。多字节/转义敏感的补丁用 python 直改，勿用非引号 heredoc。
4. **镜像内无 cmake**：libar2 构建 = nvcc 直驱 g++ 手工命令（CMakeLists 仅作规范参考）；
   NCCL 树构建必须挂载在 configure 时的原路径 `/nccl-src`，换路径 = stale obj 链接失败。
5. **env 文件路径笔误**：head 读 `~/w6-kit/w6_env.txt`，追加开关时写到了 `~/w6_env.txt`（家目录）
   → rank0 开关失效。回滚/验证时必须 `docker exec` 查 `/proc/1/environ` 实证，勿信本地文件。
6. **guard 锁交接窗**：两条重启链交接（旧链 health 轮询未退、新链已起）会产生过渡代容器（TCPStore
   broken pipe 噪音）。判断"当前代"以 `docker ps` 启动时间 + 镜像 md5 为准，勿把过渡代当事故。

## 2026-09-04 生产镜像轮新增

7. **fence 触发点的相位盲区（镜像 v1 事故）**：vLLM 目标模型 PIECEWISE 捕获的片间有大量
   eager 大 AR（262-512KB×87），"捕获后首个大 AR" 触发点会在 PIECEWISE 1/16 过早武装 ——
   后续 dspark warmup/capture 相位错位时降级重做无法收敛（对端同逻辑 op 已录进 graph，
   延迟到 replay 才执行 → 本端原生 op 永等 → 30min NCCL watchdog）。修复 = **捕获静默窗**
   （距最近捕获事件 ≥10s 才允许触发；实测段间隔 ≤5s、末段捕获→首服务请求 ≥30s）。
8. **镜像构建清单纪律（v2 教训）**：从基镜像重打集成镜像时只注入了 libnccl 漏了 libar2
   （dlopen 失败→静默降级，栈健康但 V5 休眠）。集成镜像三件套清单：libnccl 同路径替换 +
   /opt/ar2/lib + ld.so.conf.d + ldconfig + ENV 烘焙，每步容器内 md5/dlopen 验证后才 commit。
9. **诊断打印阈值要与人群匹配**：pre-arm 每 8192 op 报一次的阈值在真实负载（每请求几百 AR）
   下永不触发，形同虚设；服务期取证用"首事件即报 + 大请求驱动"（120K-token prefill 才压出
   armed 与直方图）。
10. **docker commit 后 registry tag 更新要四机 pull**：同名 tag 重新 push 后本地缓存仍是旧
    digest，四机 `docker pull` 是换代的必要步骤（否则 rm+run 起的还是旧层）。
11. **GB10 统一内存 × 双 CUDA 上下文（R3, 2026-09-04）**：生产 vllm 常驻即近乎占满统一内存,
    旁路进程建 CUDA 上下文**偶发**失败 —— 表现为跨 rank 混合 `NOMEM(-2)/VERBS(-6)/CUDA(-11)`
    且逐次不同、整轮重试即过; torch 侧 `set_device` 直接 OOM。**推论: 旁路 NCCL/torch 基准与
    常驻生产不共容**（NCCL RTR 超时报错是伴生症状, 勿误诊为 GID/子网问题）。处置: ar2_probe
    类微上下文工具 + 整轮重试; 需要原生 NCCL 参考数据时用档期窗口数据或另开窗口。
12. **"0 值才 env 回退" × defaults 非 0 预填 = env 静默死代码（R3）**：`ar2_config_defaults`
    原预填 timeout=5000/smax=65536/nslots=2, 而 ar2_init 的 env 回退只认 0 值字段 →
    `AR2_SMAX`/`AR2_TIMEOUT_MS`/`AR2_NSLOTS` 从未生效过（大尺寸微基准被静默钳在 64KB 一整轮
    才定位）。模式教训: 凡"哨兵值触发回退"的配置面, defaults 与哨兵必须成对审计。
13. **共享 CQ 多 QP 的 CQE 收割必须计数收齐（R3）**：每 QP 尾 WR 均签名（wr_id=seq）,
    只收 1 个 CQE 会让残留 CQE 在下一 op 的 wr_id 校验处误报 PROTOCOL —— reap_bell 按期望
    个数收齐才算 burst 完成。

## 2026-09-04 M2GI 窗口新增

12. **op_submit 曾丢弃调用方流参数（已修）**
CUDA 后端 op_submit 的流参数原为无名形参 (恒落内部流)。m1 路径因 host 阻塞 (done_wait)
数据正确性不受影响 → 断陷不可见; **图捕获直接致命**: kernel 录不进调用方图, 捕获期空转
+ seq 错账 → 重放挂死。修复 = 调用方流优先 (`s ? s : stream`)。教训: "契约注释写了"
(657 行 ext_stream 注释) ≠ 实现执行了。

13. **NOMEM 伞掩真实 CUDA 错误（已修）**：arena_alloc 任何 cudaHostAlloc 失败一律归 AR2_ERR_NOMEM —— 实际生产中真错是
`cudaErrorStreamCaptureUnsupported` ("operation not permitted when stream is capturing"):
vLLM FULL 捕获的外层上下文已开 capture, 捕获中 cudaHostAlloc 被门禁拒绝。
教训: ①伞形错误码必须落原始 cudaGetErrorString; ②**ar2 会话必须在 eager 期建好**
(V5 hook 同款时机), 任何"捕获中再初始化"的设计都会撞这门禁。

14. **图内集成 M2GI 断陷三连（已修）**：① dspark 8tk 图 87 op 超 AR2_MAX_LAYER_OPS=64 → register 拒绝 (现 128);
② 奇字节尺寸 op (非 16 对齐) 不能进 journal, 控制器须预检回原生而非降级;
③ bf16 正确性判据的整数域: 双 AR 链总放大 4×4, 数据 |x|≤32/W∈[1,4] 时中间量超 256
(bf16 精确整数上界) → ar2 两轮求和序与 NCCL 序的 ULP 级合法差异被误判为数据损坏
(单元测试实锔 maxdiff=16); 测试须收敛数据域使全部中间量 ≤256。
