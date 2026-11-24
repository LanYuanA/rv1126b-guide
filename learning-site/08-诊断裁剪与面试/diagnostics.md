# 内核诊断的工具与入口

- [8.1 性能基线、采样与测量误差](./performance-baseline.md)
- [8.2 内核日志、dynamic debug、符号与调用栈](./kernel-debug-log.md)
- [8.3 proc、sysfs 与 debugfs 的测量口径](./kernel-metrics.md)
- [8.4 ftrace、tracepoint 与跨层时间线](./trace-timeline.md)
- [8.5 perf 与 CPU 热点](./perf-hotspots.md)
- [8.6 eBPF、BTF 与板端配置判定](./ebpf-prerequisites.md)

## 工具各自回答什么问题

| 问题 | 首选证据 | 容易漏掉什么 |
| --- | --- | --- |
| 程序在哪个系统调用失败 | errno、strace 只跟 openat/ioctl/poll，结合驱动日志 | strace 有扰动，且看不到硬件内部传输 |
| 谁占 CPU，等待在哪里 | `/proc/stat` 差分、线程状态、perf stat/record（可用时） | 采样热点解释 CPU 时间，阻塞线程可能很少被采到 |
| IRQ 与采集线程切入相隔多久 | irq、sched tracepoints，VB2 或驱动完成时间戳 | 先辨时钟、丢事件和 PID 迁移。irq 入口到退出不是完整帧耗时 |
| 哪条调用路径分配内存 | kmem tracepoints、大小、调用点、alloc/free 地址配对 | 同地址可复用、事件可能漏、Slab 有缓存，增长不等于泄漏 |
| 崩溃 PC 在哪一行 | 同构建的 `vmlinux` / .ko 和 `scripts/faddr2line` | 地址随机化、模块基址、符号偏移及编译优化会影响解释 |

板端只读探测示例。tracefs 可能挂在另一位置或没有访问权限，必须记录实际情况。

~~~bash
adb shell 'for t in /sys/kernel/tracing /sys/kernel/debug/tracing; do if test -r "$t/available_events"; then echo "$t"; grep -E "^(irq:|sched:|kmem:)" "$t/available_events" | head -24; cat "$t/trace_clock"; fi; done'
adb shell 'command -v perf; command -v trace-cmd; cat /proc/pressure/memory 2>/dev/null'
~~~

后续独立采集窗口才考虑开启事件，记录原状态并在实验后恢复。ftrace 做事件记录，perf 可做计数/采样，dynamic debug 按调用点切换日志，lockdep、KASAN、kmemleak 对应锁依赖、内存错误和疑似孤立对象。这些调试能力有配置和运行代价，适合在可恢复实验内核按问题选择。[Linux 6.1 ftrace](https://docs.kernel.org/6.1/trace/ftrace.html)

**验收**　给出一条会推翻自己怀疑的观察。例如应用变慢时 EOF 仍准时而用户线程长时间 runnable，应先查调度和下游消费。评估内核裁剪时，可以在隔离配置中复用这些观测。[内核裁剪](trimming.md)
