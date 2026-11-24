# 8.6 eBPF、BTF 与板端配置判定

<script setup>
import exampleFile from '../examples/bpf-entry-probe.c?url'
</script>

原厂 RV1126B 为什么有 kmem 追踪事件却不能直接运行 eBPF 分配监测？先看运行内核的系统调用入口，再查准备附着的事件和程序需要的类型数据。这些条件各自有独立验证办法。

## 从 loader 到输出的五步

| 步骤 | 内核做什么 | 失败时优先看 |
| --- | --- | --- |
| 调用 `bpf()` 管理对象 | 根据命令处理 map、program 等文件描述符 | 运行内核 BPF_SYSCALL、调用策略与实际 errno |
| 加载程序 | 某类程序经 verifier，验证可达路径、内存访问与 helper 使用 | 程序类型、指令与 verifier 日志 |
| 挂载 | 关联 tracepoint、kprobe、fentry 或其它事件类型 | 目标 event/符号是否存在，该 attach 类型及配置、权限 |
| 保存状态 | 用 map 保持跨事件数据，如指针至分配记录与栈 ID | 键范围、容量、并发、删除与溢出 |
| 输出 | 用户态读取 map，或消费 ring buffer 等渠道 | 丢事件、消费速率、时间戳与窗口 |

SDK 的 `bpf()` 入口把 cmd、attr 及 size 传到内部处理函数，`BPF_PROG_LOAD` 路径调用 `bpf_check`。verifier 负责约束内核内运行的程序。JIT 影响支持的执行方式/速度；把 JIT 配置打开与存在用户态 bpf 系统调用要分别看。你在原厂固件里看到 `CONFIG_BPF=y`，只说明 BPF 公共代码相关条件已满足，历史导出的 `CONFIG_BPF_SYSCALL` 则未启用。所以即使 ADB shell 为 root，常规 loader 在入口仍缺这一功能。

~~~c
return __sys_bpf(cmd, USER_BPFPTR(uattr), size);
~~~

源码摘录 `kernel-6.1/kernel/bpf/syscall.c:5122–5127`

~~~c
SYSCALL_DEFINE3(bpf, int, cmd, union bpf_attr __user *, uattr, unsigned int, size)
{
	return __sys_bpf(cmd, USER_BPFPTR(uattr), size);
}

static bool syscall_prog_is_valid_access(int off, int size,
~~~
源码摘录 `kernel-6.1/kernel/bpf/syscall.c:2641–2646`

~~~c
err = bpf_check(&prog, attr, uattr);
if (err < 0)
	goto free_used_maps;

prog = bpf_prog_select_runtime(prog, &err);
if (err < 0)
~~~

## tracepoint、kprobe 和 BTF 各自适用什么情况

- **tracepoint** 是源码定义的事件点，有意提供特定字段。直接用 ftrace 记录已提供的事件，不必经由 BPF loader。要把某类 BPF 程序附着到它，再检查本内核的 BPF、事件及附着方式相关配置。
- **kprobe** 是动态函数/指令探测机制。SDK 里 `KPROBES` 与 `KPROBE_EVENTS` 分别控制底层探测和相应事件。原厂当时 KPROBES 未启用，这会影响以 kprobe 为前提的功能；已有的普通 tracepoint 仍可独立存在。
- **BTF** 提供结构、字段和函数等类型描述。libbpf 可以用目标内核 BTF 处理 CO-RE 对类型访问的重定位。一些附着类型还需要相关 BTF ID。缺 BTF 会阻断依赖它的程序和 loader。有些固定上下文和接口的 BPF 程序不依赖目标 BTF，仍要满足系统调用和附着条件。
- **配置依赖**　这份 6.1 源码的 BPF_EVENTS 依赖 BPF_SYSCALL、PERF_EVENTS 与 kprobe 或 uprobe 事件条件，不能只看事件文件名就推断可挂。DEBUG_INFO_BTF 还依赖 BPF_SYSCALL 和编译时调试选项，生成时要核对 pahole 与 DWARF。 [Linux 6.1 BTF 说明](https://docs.kernel.org/6.1/bpf/btf.html)

源码摘录 `kernel-6.1/kernel/trace/Kconfig:696–701`

~~~text
config BPF_EVENTS
	depends on BPF_SYSCALL
	depends on (KPROBE_EVENTS || UPROBE_EVENTS) && PERF_EVENTS
	bool
	default y
	help
~~~
源码摘录 `kernel-6.1/lib/Kconfig.debug:349–354`

~~~text
config DEBUG_INFO_BTF
	bool "Generate BTF type information"
	depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
	depends on !GCC_PLUGIN_RANDSTRUCT || COMPILE_TEST
	depends on BPF_SYSCALL
	depends on !DEBUG_INFO_DWARF5 || PAHOLE_VERSION >= 121
~~~

## 在 WSL 对比“缺入口”和“权限受限”

用一个只请求单元素 ARRAY map 的独立 C 示例。成功后立刻 close。它不会探测其他进程或附着 BPF 程序。可<a :href="exampleFile" download="bpf-entry-probe.c">下载 bpf-entry-probe.c</a>。

~~~bash
mkdir -p output
lab=$(mktemp -d "$PWD/output/bpf-entry.XXXXXX")
cc -std=c11 -Wall -Wextra -Werror learning-site/examples/bpf-entry-probe.c -o "$lab/bpf-entry-probe"
"$lab/bpf-entry-probe"
~~~

WSL 实测返回 EPERM，当前 `kernel.unprivileged_bpf_disabled=2`，可读 `/sys/kernel/btf/vmlinux`，前四字节 `9f eb 01 00`。由此不能宣布 WSL 可以加载监测程序。对于只给出 ENOSYS 的机器，还需用运行内核配置或容器策略区分编译缺入口与运行环境模拟不可用。原厂板端的历史证据来自运行内核配置，另有本地候选配置，可分别核对。

~~~bash
cfg=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal/.config
rg 'CONFIG_(BPF|BPF_SYSCALL|BPF_JIT|KPROBES|FTRACE|TRACEPOINTS)(=| is not set)' "$cfg"
cat /proc/sys/kernel/unprivileged_bpf_disabled
od -An -tx1 -N4 /sys/kernel/btf/vmlinux
~~~

当板端可连时，用实际 `uname -r`、`zcat /proc/config.gz`、事件目录、BTF 路径与 loader 的报错组成同一次检查。有些根文件系统没有导出 config.gz，缺文件时应回查同构建配置。当前历史板端仍是线性采集配置，尚未启动为 BPF 增强构建或采集到真实分配 BPF 事件。

## 从成熟工具理解内核的资源寿命

BCC memleak 可以作为分配/释放配对、栈 ID 与聚合的参考。它部分模式用 kmem tracepoint，例如看它如何记录 `kmalloc` 和处理 `kfree`，以及保存未归还地址。另有用户进程分配的探针入口。比较时区分它的 map 聚合与另行设计的 ring buffer 方案。独立工具如果用 ring buffer 把事件送到用户态，需要计数 reserve 失败、消费落后与跨窗口截断；收到“不见 free”先判是否掉事件、窗口起点缺 alloc、释放还未发生或地址被复用。 [BCC memleak 原实现](https://github.com/iovisor/bcc/blob/master/tools/memleak.py) · [Linux BPF ring buffer](https://docs.kernel.org/bpf/ringbuf.html)

这条链可以学到内核分配上下文、页与 slab 的对象层级、缓冲生命周期、唤醒及采样开销。先用已经证实可见的普通 tracepoint 或离线日志验证配对，对端到端帧和内存做关联。BPF 后端满足前置条件时再接入运行与丢失验证。

## 本节复盘

1. **为什么板上是 root，工具仍无法加载？** 权限无法增加构建时缺失的系统调用。先确定运行内核配置，再独立核对权限及挂点。
2. **KPROBES 没开是否等于没有 tracepoint？** 普通 tracepoint 可独立存在，其字段、记录与可附着方式还要逐项检查。
3. **BTF 文件可读，能证明 BPF 能运行吗？** 只能证明类型数据存在。真实加载和 attach 还有入口、程序类型、权限与目标事件等条件。

下一节把这些依赖和相机启动依赖写进可回退的内核配置实验。 [8.7 Kconfig、内核裁剪与可恢复的适配](./trimming.md)
