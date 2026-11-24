# 8.2 内核日志、dynamic debug、符号与调用栈

<script setup>
import exampleFile from '../examples/kernel-symbol-demo.sh?url'
</script>

板上已经能取得 4K 图，dmesg 却报 vblank 只有 859 µs。先找谁打印、值怎么来的，再用同次采集的帧记录验证哪些后果真实发生。另一类故障只有回溯地址，要用同一构建的符号定位。

## 先保留失败的时间窗口

日志的 level、设备前缀、单调时间和上下文应一起保存。 `dmesg` 读的是内核环形缓冲，过多日志会覆盖起点。串口还受 console loglevel 和输出速度影响，其显示与环形缓冲内容可能不同。现场记录操作开始、驱动 STREAMON/STREAMOFF、告警和相关出队的时间。不要只抄结论词；保存原始摘录和采集命令。

~~~bash
rg -n 'vblank need|data_rate_mbps|imx415 .*s_stream' output/camera-check/dmesg-after.log | tail -12
bash learning-site/examples/frame-intervals.sh output/camera-check/capture.log
~~~

本轮历史记录有 vblank 告警，同时有 31 次出队、0 序号缺口。一秒左右的观察窗口只能证明这一轮短采集能出图，长期时延、错误计数与负载敏感性还需测量。

## 沿打印表达式追输入、单位和阈值

SDK 的 `rkcif_check_vblank_value()` 用 `rkcif_get_linetime()` 返回的行时间乘当前 vblank 行数，再把纳秒除以 1000。对比的是 online ISP 的驱动阈值 1000 µs。

~~~c
vblank_us = tline * vblank;
vblank_us = div_u64(vblank_us, 1000);
~~~

继续追上游， `rkcif_get_linetime()` 从 sensor 的帧间隔求默认整数 fps，用 `1e9 / fps` 得帧周期 ns，再除以默认 VBLANK 与 raw height 之和。警告乘的是**当前** vblank；算行时间用的是**默认**的参考行数。当前值、默认值、裁切高度和 sensor 模式高度各有来源，排查时要用正确字段。

~~~c
line_time = div_u64(1000000000, def_fps);
line_time = div_u64(line_time, vblank_def + sensor->raw_rect.height);
~~~

拿候选模式里 30 fps、RAW 高 2192、VTS 2250 为例，默认 vblank 为 58。若当前值也为 58，则行时间约 14814 ns，整数运算得 859 µs，与历史值一致。这给出一组可解释输入，当前实际控件与输出路径还要现场采集。按此模型大约要 68 行才能满足阈值，但更改它会改变帧周期和最大曝光。判断影响时先做读回或抓时序，再和真实掉帧、坏帧、延迟分布对照。

<Sdk id="vblank" />
<Sdk id="cif-line-time" />

## dynamic debug 控制的是打印调用点

支持时，编译器为 `pr_debug`、`dev_dbg` 等调用点保留动态元数据，`control` 展示文件、行号、模块、函数、flags 与格式。可以按 file、func、format、line 等条件筛选，命令结尾的 `+p` 或 `-p` 控制打印。定位到一个实际已编译调用点后，先查当前 flag，然后只修改必要项，结束恢复初始状态。

~~~bash
for control in /proc/dynamic_debug/control /sys/kernel/debug/dynamic_debug/control; do
  if test -r "$control"; then
    rg 'imx415\.c|rockchip/cif/' "$control" | sed -n '1,16p'
  fi
done
~~~

示例只读。若为了裁剪关闭相应选项、目标模块未加载，或当前用户不能读路径，catalog 可能不可用。这条 vblank 走 `v4l2_warn`，它也可能根本不在 catalog 中。 `v4l2_dbg` 还有自己的 level/变量门控，先读宏再选择开关。全量打印会显著扰动时序和存储，按复现窗口控制。 [Linux 6.1 dynamic debug](https://docs.kernel.org/6.1/admin-guide/dynamic-debug-howto.html)

## 用同构建的符号验证回溯

函数符号加偏移表示出错或采样指令在函数里的位置，末尾的 `/size` 可辅助排除同名函数或不一致构建。模块应给相同的未剥离 `.ko`，内核使用 `vmlinux`。先核对 Build ID、构建版本、配置与编译器，检查 DWARF 行号表。只有绝对 runtime PC 时，要根据内核地址随机偏移或模块加载地址还原为 ELF 位置。内联和优化可能把一条指令关联到多层调用，从顶层函数名还要继续确认现场。

在 WSL 仓库根目录执行。实验使用已有候选 ARM64 `vmlinux`，输入一个已知函数偏移和一个刻意错误的函数尺寸。可<a :href="exampleFile" download="kernel-symbol-demo.sh">下载 kernel-symbol-demo.sh</a>。

~~~bash
bash learning-site/examples/kernel-symbol-demo.sh
~~~

本轮定位 `meminfo_proc_show+0x10/0x860` 到 SDK `fs/proc/meminfo.c:33`。把尺寸改为 `/0x1`，输出 size mismatch 与 no match。这个 SDK 版本的脚本在该反例仍返回 0，因此外层检查实际解析内容。正确位置依赖本地 DWARF，原厂板端符号要与实际固件重新核对。这是符号化演练，没有触发内核崩溃。

## 本节复盘

1. **日志消失意味着时序改善吗？** 先验证 VBLANK、行时间与真实帧指标。过滤或关打印也会让日志变少。
2. **为什么没有 debug 输出，不一定是没走代码？** 可能是调用点没编进、动态开关或 V4L2 level 阻断，或上下文采集窗口错。
3. **能用另一版 vmlinux 定位吗？** 需要同构建并核对 Build ID、符号大小与地址。编译优化和源文件差异都可能改变指令位置。

下一节把日志外的 proc、sysfs、debugfs 数字变成清楚的采集指标。 [8.3 proc、sysfs 与 debugfs 的测量口径](./kernel-metrics.md)
