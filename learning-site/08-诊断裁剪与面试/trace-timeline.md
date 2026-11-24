# 8.4 ftrace、tracepoint 与跨层时间线

<script setup>
import exampleFile from '../examples/trace-timeline-demo.awk?url'
import inputFile from '../examples/trace-timeline-demo.tsv?url'
</script>

慢出队可能来自硬件晚到、驱动晚完成、线程已被唤醒却一直等 CPU，或者应用已经运行但还在处理。记录每个边界，才能说清是哪一段变长。

## 先从事件定义知道记录了什么

tracefs 提供可用事件、格式、过滤、当前时钟和每 CPU 缓冲。ftrace 有函数追踪和事件记录等方式。事件追踪记录已有 tracepoint，在编译和运行环境允许时按事件打开。文件 `events/组/名/format` 定义字段、偏移和格式。 `common_pid` 是产生事件时当前线程，`sched_wakeup` 的被唤醒 PID 和 `sched_switch` 的 next_pid 可能不同于它。

| 端点 | 示例事件和关键字段 | 解释边界 |
| --- | --- | --- |
| IRQ action | irq_handler_entry/exit，irq 与当前 CPU | action 处理耗时，仍缺硬件触发至入口的等待 |
| 提交完成缓冲 | VB2 buf_done 或可关联的驱动事件 | 还需匹配目标队列与帧，某些版本事件只有队列或槽号 |
| 任务变 runnable | sched_wakeup 的目标 TID | 线程已具备运行条件，事件产生 CPU 可以不同于运行 CPU |
| 获得 CPU | sched_switch 的 next_pid | 这次切入时刻，若有再次被换出还要继续跟踪 |
| 应用拿到帧 | 同进程给 DQBUF 返回额外打点 | 读取驱动元数据中的 EOF 只代表另一时间边界 |

内核 VB2 里出现在唤醒之前的 tracepoint 可用来标记完成阶段。下面是同一函数的两个关键调用。

~~~c
trace_vb2_buf_done(q, vb);
~~~

驱动若将缓冲返回到 QUEUED 状态，分支直接返回。在通知等待者的分支会调用 `wake_up(&q->done_wq)`。sched_wakeup 再用内核调度器的记录判断具体目标。缓冲标志、匹配键和是否确实有等待者都应验证。 [Linux tracepoint 事件格式](https://docs.kernel.org/6.1/trace/events.html)

<Sdk id="trace-irq-fields" />
<Sdk id="trace-sched-switch" />
<Sdk id="trace-vb2-and-wakeup" />

## 跨 CPU 时间为什么不能直接相减

trace clock 的 `local` 追求低开销，多 CPU 之间可能不同步；跨 CPU 配对需要选择并验证合适的共同时间域。 `global` 的跨 CPU 顺序不自动等价于用户态的 CLOCK_MONOTONIC，优先检查实例实际支持的时钟与对应关系，必要时记录应用和 trace 的同一锚点。用整数 ns 存储采样，并把 CPU、目标线程和数据来源跟在时间旁。不同端点出现相同时间戳时按事件顺序和明确因果判定，不能仅凭两个文本数字猜顺序。

同 CPU 的 IRQ entry/exit 遇到嵌套可按栈配对。线程从 CPU 1 被唤醒，可能在 CPU 2 切入，按目标 TID 匹配。生产者与消费者有并发时，还要按目标 fd 或队列关联 buffer 与序号。同一个出队可能经过多次切入、再次阻塞及信号重试，记录窗口里只看到第一次切入时必须保留不完整状态。 [Linux ftrace 时钟、实例与缓冲](https://docs.kernel.org/6.1/trace/ftrace.html)

## 用可控轨迹拆两个慢帧

在 WSL 仓库根目录执行。可<a :href="exampleFile" download="trace-timeline-demo.awk">下载配对脚本</a>和<a :href="inputFile" download="trace-timeline-demo.tsv">标准化轨迹</a>。输入声明已统一为整数纳秒，每次只有一个在途帧，IRQ=43、目标 TID=412，第一帧 IRQ 中嵌了一次其他 IRQ，第二帧在 CPU 3 切入。脚本使用已知的事件先后和序号，实际 trace 必须先确认关联规则。

~~~bash
LC_ALL=C awk -v camera_irq=43 -v capture_pid=412 \
  -f learning-site/examples/trace-timeline-demo.awk learning-site/examples/trace-timeline-demo.tsv
~~~

| 帧 | IRQ action | 退出到缓冲完成 | 完成到唤醒 | 唤醒到切入 | 切入到出队返回 |
| --- | --- | --- | --- | --- | --- |
| 18 | 12 µs，含 4 µs 嵌套 | 11 µs | 3 µs | 53 µs，CPU 2 | 13 µs |
| 19 | 11 µs | 11 µs | 2 µs | 65 µs，CPU 3 | 17 µs |

拿帧 18 算，IRQ exit 1,012,000 ns 到 DQBUF 1,092,000 ns 是 80 µs。能定义为该线程 runnable 等待的是 wakeup 1,026,000 到 switch 1,079,000 之间的 53 µs。以明确的事件丢失行替换唤醒时，脚本返回错误。若根本缺失 wakeup 或匹配不到 IRQ 栈，也应拒绝把结果当完整延迟。

## 实板只读探测与采集窗口

先确定当前板端、运行权限、挂载与可用事件。当前 WSL 的 tracefs 已挂载，普通用户无法读目录，本轮采用人工轨迹。板端也按实际输出判断。

~~~bash
adb shell 'for t in /sys/kernel/tracing /sys/kernel/debug/tracing; do
  if test -r "$t/available_events"; then
    cat "$t/trace_clock"
    grep -E "^(irq:irq_handler_|sched:sched_(wakeup|switch)|vb2:vb2_buf_done|kmem:)" "$t/available_events" | head -25
    test ! -r "$t/events/sched/sched_wakeup/format" || cat "$t/events/sched/sched_wakeup/format"
  fi
done'
~~~

现场有授权和权限时，在任务独立的 trace instance 上用明确的事件过滤和很短的观察窗，记录时钟、CPU mask、缓冲大小及 per-CPU stats，包括 overrun、commit overrun 和 dropped events。结束后导出记录，再撤掉本次创建的采集状态。如果必须共用实例，先记录原设置与其它使用者，按变化项恢复。 `trace_pipe` 会消耗记录，共用采集时先确定读取者。任何丢失都应进入数据质量字段，避免错误配对。

## 本节复盘

1. **为什么 IRQ exit 到 DQBUF 不能全归到调度延迟？** 它包含缓冲交付、唤醒、runnable 等待及运行后的处理。
2. **为什么线程被 CPU 1 唤醒却在 CPU 3 记录切入？** 唤醒是调度动作，目标可排在另一个 CPU 上。按 TID 和共同时间域配对。
3. **窗口缺一条 wakeup 可以用相邻事件补吗？** 只能作为假设。给不完整状态，并查丢事件、范围、过滤器和目标 ID。

下一节用 perf 区分 CPU 热点与不占 CPU 的等待。 [8.5 perf 与 CPU 热点](./perf-hotspots.md)
