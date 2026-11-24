# 8.5 perf 与 CPU 热点

<script setup>
import exampleFile from '../examples/perf-workload.c?url'
</script>

一个进程用了 400 ms 才返回。它可能一直计算，也可能绝大多数时间都在睡眠。先用事件计数看 CPU 资源，再用采样看 CPU 运行时间分布，两类数据要与墙钟和等待证据配合。

## 计数与采样各回答一个问题

| 方式 | 工作方式 | 怎么读 |
| --- | --- | --- |
| `perf stat` | 为目标进程或 CPU 记录一组事件的总计数 | 看 cycles、instructions、task-clock 以及 elapsed；解释作用域和复用比例 |
| `perf record` | 事件达到周期或采样频率后保存指令位置，可带调用栈 | 看样本在函数、进程与映射间的分布，以及符号是否完整 |
| off-CPU 时间线 | 跟踪睡眠、唤醒、重新切入 | 用于解释没有出现在 CPU 采样里的阻塞 |

`cycles` 和 `instructions` 在硬件 PMU 可用时计量 CPU 周期与指令，受 CPU 频率、硬件支持和事件范围影响。IPC 是 instructions/cycles，要来自相同窗口及可比较计数，不能等同应用吞吐。 `task-clock` 是任务被调度运行的时间。一个任务等待 I/O 或下一帧时，墙钟在增加，task-clock 基本不增加。多任务、多线程、进程继承和系统范围的含义均应明确。

## 事件 fd、采样与符号怎样挂在一起

用户态 perf 通过 `perf_event_open` 提交 `perf_event_attr` 及进程/CPU 选择。内核检查事件、权限与特定 PMU，并把它接入对应上下文。计数与采样都要检查支持状态。用 `:u` 将硬件事件限制到用户态，这里不需要对整个系统采样。

~~~c
err = security_perf_event_open(&attr, PERF_SECURITY_OPEN);
~~~

event 字符串能在工具解析，只说明可以尝试。若显示 not supported，查 PMU 和实际事件；若报权限错误，查 `perf_event_paranoid`、运行 scope 与能力。计数器不足时事件复用，需保留实际运行比例。目标程序、共享库和内核符号分别按构建映射。 `--call-graph fp` 基于 frame pointer，缺失时链会断或留下地址；DWARF 展开可作为有额外代价的选择。Self 样本是该函数自身指令位置的份额，Children 还会归入子调用的累计样本。 [Linux perf 权限及数据范围](https://docs.kernel.org/admin-guide/perf-security.html)

源码摘录 `kernel-6.1/kernel/events/core.c:12357–12362`

~~~c
/* Do we allow access to perf_event_open(2) ? */
err = security_perf_event_open(&attr, PERF_SECURITY_OPEN);
if (err)
	return err;

if (!attr.exclude_kernel) {
~~~

## 编译一个可控制的 CPU/等待对照

在 WSL 仓库根目录执行。可<a :href="exampleFile" download="perf-workload.c">下载 perf-workload.c</a>。程序两个模式均约运行 400 ms，同时打印进程 CPU 时间。cpu 在标明不内联的 `compute_batch()` 循环，wait 用 nanosleep 代表阻塞。

~~~bash
mkdir -p output
lab=$(mktemp -d "$PWD/output/perf-workload.XXXXXX")
cc -std=c11 -O2 -g -fno-omit-frame-pointer -Wall -Wextra -Werror \
  learning-site/examples/perf-workload.c -o "$lab/perf-workload"
"${perf_bin:-perf}" stat -e task-clock:u,cycles:u,instructions:u -- "$lab/perf-workload" cpu
"${perf_bin:-perf}" stat -e task-clock:u,cycles:u,instructions:u -- "$lab/perf-workload" wait
"${perf_bin:-perf}" record -e cycles:u -F 199 --call-graph fp -o "$lab/perf.data" -- "$lab/perf-workload" cpu
"${perf_bin:-perf}" report --stdio --no-children --percent-limit 5 -i "$lab/perf.data"
~~~

这台 WSL 没有系统 perf 命令。本轮将 Ubuntu 24.04 的 `linux-tools-6.8.0-151` 和 `libtraceevent1` 解包到工作区，使用其中的用户态 perf 6.8.12 连接 WSL 的运行内核。当前工作区已解包，可以从第二段设置开始。需要复建时，第一段下载此次使用的 Ubuntu 包。

~~~bash
mkdir -p output/perf-lab/{debs,root}
(cd output/perf-lab/debs && apt-get download linux-tools-6.8.0-151 libtraceevent1)
for deb in output/perf-lab/debs/*.deb; do dpkg-deb -x "$deb" output/perf-lab/root; done
~~~

~~~bash
perf_root="$PWD/output/perf-lab/root"
export LD_LIBRARY_PATH="$perf_root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
perf_bin="$perf_root/usr/lib/linux-tools-6.8.0-151/perf"
"$perf_bin" --version
~~~

若工具无法用，可先执行二进制的 cpu/wait 模式比较墙钟及进程 CPU 时间。当前 WSL 实际支持该轮按子进程采集的三种事件，不能把它推广成 ARM64 板端的 PMU 支持结论。要在板上确认能力先查工具版本、目标事件和权限。

| WSL 用例 | 本轮墙钟 | 进程自身 CPU 时间 | perf task-clock |
| --- | --- | --- | --- |
| cpu | 400.02 ms | 370.23 ms | 371.48 ms |
| wait | 428.32 ms | 0.22 ms | 0.95 ms |

perf 的计数还包含工具监控子进程启动/退出等与程序自行打点不完全一致的区间，这两组数字可略有差别。199 Hz 的记录拿到 82 个样本，无 lost sample 记录，Self 分布显示 `compute_batch` 约占 99.98%。栈里有 libc 的未解析地址，报告如实保留。进程很短、频率较低或机器负载不同都会改变样本数。结果说明可控计算路径的热点，等待对照说明没有热点不代表用户没等待。

## 应用于摄像头的一次慢帧

在同源规格下先分开测正常和慢运行的用户态算图、拷贝、编码及磁盘端，再使用进程/线程 scope 查成本。在 CPU 热点看到转换函数，可以先验证是否出现额外颜色转换或复制。若 CPU 无热点而时间差大，查看上一节的 sched 和缓冲队列事件，以及块层 I/O。修改之后复测端到端吞吐、耗时和图像验收，避免只比较单函数百分比。

## 本节复盘

1. **为什么 400 ms 的等待测试 task-clock 很小？** 它主要在阻塞，调度器没有让它占用 CPU 执行。
2. **函数占 50% 样本，优化后整体一定快 50% 吗？** 样本是指定事件、时段和范围的分布。还要定量判断可加速比例、等待与并发瓶颈。
3. **cycles 读取失败能否宣布板端没 PMU？** 先限定目标进程、事件、工具、能力和范围，区分权限、虚拟化与硬件事件不可用。

下一节核对抓分配事件所需的内核 BPF 入口、挂点和 BTF。 [8.6 eBPF、BTF 与板端配置判定](./ebpf-prerequisites.md)
