# 8.8 FrameScope 的采集、关联与可验证诊断

<script setup>
import commandFile from '../examples/framescope.sh?url'
import parserFile from '../examples/framescope-replay.awk?url'
import inputFile from '../examples/framescope-replay.tsv?url'
</script>

备录变慢后预览也卡，工具要回答的是哪块缓冲什么时候归还、哪条支路一直持有它、还有哪些证据缺失。先实现一个小的离线回放入口，把相机槽位、支路引用、分配地址与停止窗口关联起来。

## 按采集、关联和报告分工

| 层 | 这版已有的输入/实现 | 接到板端还需要 |
| --- | --- | --- |
| 采集及能力 | 历史 V4L2 出队日志、标准化事件夹具；8.3 可单独做 proc 快照 | 应用埋点、真实 tracefs 事件与能力标记；可选的 eBPF 后端 |
| 关联 | 回放按单 session、共同单调时钟、队列与槽位归并 | 相机实际 ID 和归还钩子，统一日志与 trace 时钟 |
| 报告 | 间隔、序号缺口、支路持有、停止时活跃字节、数据不完整提示 | 事件窗口背景、采集影响、稳定重复和运行态证据 |

工具的数据字段要带来源、单位、时钟、session 与上下文。历史出队日志只有帧元数据，可推导观测序号及 EOF 间隔，缺少归还、调用者调度或分配。标准化轨迹是可手算的合成对照，用来检验关联规则。没有对应后端时保留缺失状态。

参考 BCC 的分配地址和栈聚合，Perfetto 的跨层时序及丢失元数据，libcamera 的 request/stream 完成。这版自己实现的是**同一个启停会话中的槽位和支路生命周期，加上资源活跃量的对应**。后续增加带时间戳的采集后端仍可复用回放格式。 [BCC memleak](https://github.com/iovisor/bcc/tree/master/libbpf-tools) · [Perfetto ftrace](https://perfetto.dev/docs/getting-started/ftrace) · [libcamera Pipeline Handler 指南](https://github.com/libcamera-org/libcamera/blob/master/Documentation/guides/pipeline-handler.rst)

## 槽位复用为什么要带交付序号

同一块 mmap 内存的 index 在 STREAMON 生命周期里反复复用。每次用户得到不同的 sequence，必须同时记队列、槽位和此次帧号。再次 DQ 的时点一定要和上次 QBUF 区分。支路持有期是进入、退出处理引用的时间，槽位总持有期则从 DQBUF 到同帧 QBUF。

~~~awk
frame = frame_key(queue, $6 + 0, $7 + 0)
branch = frame SUBSEP $8
~~~

`hold` 增加支路引用，`release` 记录各自占用。从所有支路收齐引用再 QBUF。若应用过早还槽，脚本拒绝完成样本。这与驱动的所有权约束对应，真实应用还需加锁或明确跨线程移交。对照慢支路实验时先看改变该分支速度后其它支路是否恢复。

## 内存地址如何配对，怎样防止误报泄漏

alloc 记录地址、大小、分配时 PID/上下文与一个栈标识。free 按地址删记录，释放者可与分配者不同。未匹配释放可能因为对象先于窗口分配，也可能是采集丢失。当前活跃量按地址去重，不重复叠加页层和对象层。窗口内活跃对象按原分配上下文及栈聚合，分配大小报告 ≤64、65–4096、>4096 三桶。栈是输入标签，符号化还需与运行内核的符号匹配。地址重复、表容量不足、时钟倒退和跨域输入会被拒绝，已知掉事件会降低报告质量。

每轮停止时看待归还槽位、活跃量及足够冷却后的状态。首轮预分配一个池，之后各轮停流保持相同活跃量，可能只是长寿命缓存。只有可复现的增长、资源归属、完整 alloc/free 跟踪与受控干预，才支持更具体的泄漏判断。

## 在 WSL 回放三类已知输入

工具入口可<a :href="commandFile" download="framescope.sh">下载</a>，另需同目录下的<a :href="parserFile" download="framescope-replay.awk">解析脚本</a>与间隔工具；<a :href="inputFile" download="framescope-replay.tsv">回放轨迹</a>可单独检查。在仓库根目录执行。

~~~bash
bash learning-site/examples/framescope.sh replay learning-site/examples/framescope-replay.tsv
bash learning-site/examples/framescope.sh v4l2-log output/camera-check/capture.log
~~~

| 输入条件 | 实验结果 | 观察允许说到哪里 |
| --- | --- | --- |
| main 序号 11 直接到 13 | 一个缺口 | 观测缺一条，可能是丢帧、事件或日志 |
| 备录保留槽位 0 的第 10 帧 | 备录持引用 89 ms，总持槽 92 ms，峰值同时在途 2 | 明确该合成例中延迟归还的消费者，实际还要干预验证 |
| 三次停流仍有同一池 | 每次 4096 B、待归还槽 0 | 相邻停流状态稳定，不能称作泄漏 |
| 原厂短采集 | 31 帧、无序号缺口、P95 33.377 ms | 能说明这一秒出队，依然缺谁在持有及内存数据 |

反例将一个环节改成其它时钟域时应拒绝；注入 lost 后应保留观察并标记限制；支路引用没释放就 QBUF 时必须报输入无效。这一批做了宿主回放和历史导入，在线 kmem、真实栈与板端帧关联仍待采集接口。

## 以后怎样评价工具而不是被工具影响

为每次实验设相同的 workload、session 标记和清理条件，先无工具测基本数据，再加低频 proc 快照、再加事件。比较采集 CPU、RSS、写入字节、事件丢失和帧间隔尾部，复用同一输入对照。高频档需要有界缓冲、覆盖/丢失标记、停止后资源释放。先保留每个事件和阈值，再在报告里引用完整区间。 [8.1 基线和观察开销](./performance-baseline.md)

## 本节复盘

1. **为什么 index 不能单独作为帧键？** 同一个槽会被反复占用，必须和队列与当前 sequence（及 session）结合。
2. **free 的 PID 和分配者不同就会漏配吗？** 按地址配对；PID 是当时执行上下文，用于辅助分类。
3. **怎样从相关性推进到原因？** 只改变涉嫌的消费者速度或队列配置，比较归还时间、源和各支路指标，还应复现与恢复。

下一节将这个判断放进可量化的重复启动、并发和恢复矩阵。 [8.9 稳定性、并发回归与恢复](./camera-regression.md)
