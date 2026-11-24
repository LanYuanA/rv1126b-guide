# 8.3 proc、sysfs 与 debugfs 的测量口径

<script setup>
import exampleFile from '../examples/proc-snapshot-demo.sh?url'
</script>

读到内存 40 MiB、CPU 10% 或中断 1200 次，先问这个值由谁生成、统计的是窗口还是瞬间、何时清零。监控工具的第一步是为每个字段定义来源和计量口径。

## 三种虚拟文件系统提供怎样的接口

| 入口 | 常见读取 | 怎样看源码 |
| --- | --- | --- |
| procfs | 系统与进程信息，如 `/proc/stat`、`/proc/meminfo`、`/proc/<pid>/stat` | 从 `proc_create*` 或 proc inode 查回调，很多实现用 seq_file |
| sysfs | 设备或类的属性，如 CPU online、设备运行时电源状态、频率 | 从 kobject/attribute 和 `show()` 跟到设备数据 |
| debugfs | 驱动或子系统专用的调试状态或控制 | 查 `debugfs_create*` 和 fops；路径、格式、权限和构建可能变化 |

厂商驱动也可能在 procfs 增加自己的文件。Rockchip CIF 的 procfs 注册所用名字来自 `dev_name(dev->dev)`，实际节点按当前运行时检查。debugfs 预期用于调试，解析器需处理缺失和格式变化。现代内核的 tracefs 可以在 `/sys/kernel/tracing`，部分环境还能从 debugfs 下的 tracing 路径访问。用挂载信息区分文件系统、目录与权限。 [Linux procfs](https://docs.kernel.org/6.1/filesystems/proc.html) · [Linux debugfs](https://docs.kernel.org/6.1/filesystems/debugfs.html)

源码摘录 `kernel-6.1/drivers/media/platform/rockchip/cif/procfs.c:752–757`

~~~c
dev->proc_dir = proc_create_data(dev_name(dev->dev), 0444,
				 NULL, &rkcif_proc_fops,
				 dev);
if (!dev->proc_dir) {
	dev_err(dev->dev, "create proc/%s failed!\n",
		dev_name(dev->dev));
~~~
源码摘录 `kernel-6.1/drivers/base/cpu.c:206–211`

~~~c
static ssize_t show_cpus_attr(struct device *dev,
			      struct device_attribute *attr,
			      char *buf)
{
	struct cpu_attr *ca = container_of(attr, struct cpu_attr, attr);

~~~

## CPU 是否繁忙，取决于哪组差分

`/proc/stat` 首行 `cpu` 汇总系统统计，后续 `cpuN` 对应 CPU。SDK 里的 `show_stat()` 从各 CPU 获取内核的 CPU 状态时间，加到 user、system、idle、irq 等类，再转换为用户态口径。

~~~c
kcpustat_cpu_fetch(&kcpustat, i);

user        += cpustat[CPUTIME_USER];
nice        += cpustat[CPUTIME_NICE];
system      += cpustat[CPUTIME_SYSTEM];
~~~

它们都是随时间累加的计数。采样两次得到 `Δtotal`。本脚本的“执行”是 user、nice、system、irq 和 softirq 的差分合计，iowait、idle、steal 单独显示。guest 及 guest_nice 已分别计入 user/nice，重复加会扩大分母。CPU 宿主统计单位是 USER_HZ tick，可用 `getconf CLK_TCK` 取得；它与内核调度 `CONFIG_HZ` 有不同口径。汇总差分的工作执行百分比不等同于某个线程的 CPU 百分比。iowait 归属在多核系统并不总能可靠按单个进程解释，计数也可能下降；脚本把倒退窗口标为无效。

源码摘录 `kernel-6.1/fs/proc/stat.c:126–131`

~~~c
struct kernel_cpustat kcpustat;
u64 *cpustat = kcpustat.cpustat;

kcpustat_cpu_fetch(&kcpustat, i);

user		+= cpustat[CPUTIME_USER];
~~~

进程 `/proc/<pid>/stat` 的 utime/stime 可做进程差分，但要保存 starttime 来识别 PID 复用。进程退出后样本可能没有后续值，不能把消失换算成零 CPU。解析 comm 要处理括号内的空格和括号，不能简单按全行第 14、15 列拆；先识别布置在状态字段之前的末尾分隔括号，再按后缀数列。

## MemFree、MemAvailable、CmaFree 不回答同一个问题

~~~c
available = si_mem_available();
~~~

`MemFree` 表示当前空闲页，`MemAvailable` 估计在不交换等条件下还能用于新负载的内存，考虑了可回收内容与保留阈值。CMA 关心保留区域及能够找到连续物理页的情况。 `CmaFree` 是 CMA 空闲量，不能凭总量保证某次特定尺寸的分配一定成功。内核输出里标成 kB 的 meminfo 项按 1024 字节换算，脚本转换为 MiB。

源码摘录 `kernel-6.1/fs/proc/meminfo.c:54–59`

~~~c
available = si_mem_available();
sreclaimable = global_node_page_state_pages(NR_SLAB_RECLAIMABLE_B);
sunreclaim = global_node_page_state_pages(NR_SLAB_UNRECLAIMABLE_B);

show_val_kb(m, "MemTotal:       ", i.totalram);
show_val_kb(m, "MemFree:        ", i.freeram);
~~~

前后两次 MemAvailable 属于两个瞬时快照，差值也会受任务、缓存和分配影响。若想查一个驱动是否泄漏，需要让场景先热身，再反复启动/停止，结合 slab、CMA、DMA-BUF 引用以及 alloc/free 事件。只读一次数值通常无法定位所有者。

## 在 WSL 采两个快照并检查窗口

可<a :href="exampleFile" download="proc-snapshot-demo.sh">下载 proc-snapshot-demo.sh</a>。在项目根目录执行。脚本保留两个时点的 uptime、stat、meminfo、boot ID 与 CPU online，检查启动代次、在线 CPU 端点值和计数方向。

~~~bash
bash learning-site/examples/proc-snapshot-demo.sh
findmnt -T /proc/stat -n -o FSTYPE
findmnt -T /sys/devices/system/cpu/online -n -o FSTYPE
findmnt -n -o FSTYPE,TARGET -t tracefs,debugfs
~~~

本轮 WSL 能读 proc 和 sysfs，在线 CPU 为 0–15，USER_HZ 为 100。曾观到约 1.16% CPU 执行和 5986.68 MiB MemAvailable，随主机负载变化。CMA 指标未提供，debugfs 与 tracefs 已挂载，当前用户却无法读这两个目录。只有两个快照的状态，不能发现窗口内发生又恢复的热插拔。能够读某个目录也不等于其中的所有事件都可用。

把脚本迁移到板端前，先按当前根文件系统能力分别确认这些入口。监测输出每条附上时刻、单位、来源、有效或缺失状态。帧数与 CPU 等累加值用差分，内存状态用快照。采样频率提高时重新测量脚本本身 CPU 与 I/O 开销。对不会证明的场景输出缺失原因，让后续诊断能如实解释数据。

## 本节复盘

1. **为什么 guest 不再加到 CPU 分母？** CPU 汇总里的 guest 已包含在 user/nice。
2. **CmaFree 没有字段和等于零有什么不同？** 缺失是观察能力不足，零才是已暴露统计值的结果。
3. **为什么 PID 一样仍不能直接相减？** 可能曾退出并复用 PID，需要用 starttime 和采样窗口识别同一个进程。

下一节用 ftrace 和 tracepoint 把不同线程及内核事件按时序关联，从总量差分走向单次慢帧定位。 [8.4 ftrace、tracepoint 与跨层时间线](./trace-timeline.md)
