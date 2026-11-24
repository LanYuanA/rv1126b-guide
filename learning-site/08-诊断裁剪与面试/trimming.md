# 8.7 Kconfig、内核裁剪与可恢复的适配

<script setup>
import exampleFile from '../examples/kconfig-compare-demo.sh?url'
</script>

内核变小了还能不能启动、出图、排错，取决于整条设备路径。先试一项作用范围清楚的配置，观察依赖求解和真实对象，然后再扩大到整机镜像与运行回归。

## 先用依赖图标出一个可启动的最小链路

~~~text
启动介质 → bootloader → Image + DTB → init 与根文件系统
板级资源 → OF / pinctrl / GPIO / clock / regulator / runtime PM
控制总线 → I2C core / rk3x / IMX415
像素传输 → DPHY / CSI / CIF / ISP / MMU / VB2 / V4L2
业务能力 → rootfs 的 RKAIQ / IQ / 插件 / 编码库 / 写盘
可恢复性 → 串口 / 日志 / 原镜像 / 能操作的恢复介质
~~~

只查 `lsmod` 会错过 built-in。只看一次启动没绑定驱动，也不能说明其他板型和工作模式可去掉它。为每个候选项记录 Kconfig、Makefile、设备树 compatible、模块或内建产物、设备绑定和回归场景。启动早期必需的根存储、文件系统与访问路径若编成模块，需要在挂根之前可被 initramfs 等机制加载。

## .config 是求解结果，手改前后要做两次 diff

- bool 常用 y/n，tristate 在允许时可选 m。内建对象进入内核镜像，模块通常单独提供及加载。
- `depends on` 限制符号可选上限，也影响菜单可见性。
- `select` 可反向启用其他符号，未必自动满足被选符号自身所有依赖。见到看似共变的项，要查谁发起选择。
- `olddefconfig` 在已保存配置基础上补默认并求解。 `scripts/config` 写进文件只表示提出请求，最后读取生效配置和 `scripts/diffconfig` 才能确认。 [Linux 6.1 Kconfig 语义](https://docs.kernel.org/6.1/kbuild/kconfig-language.html)

选 `IKCONFIG_PROC` 做隔离实验。 `IKCONFIG` 控制是否嵌入配置并由 `kernel/Makefile` 决定是否编进 `configs.o`。 `IKCONFIG_PROC` 进一步依赖 `IKCONFIG && PROC_FS`，控制 `/proc/config.gz` 注册部分。关闭子项时，编入的 gzip 配置仍可用于镜像提取。强制填 y 后再关闭父项，最后求解会移除子项。

~~~c
entry = proc_create("config.gz", S_IFREG | S_IRUGO, NULL,
                    &config_gz_proc_ops);
~~~

<Sdk id="ikconfig-dependencies" />
<Sdk id="ikconfig-proc-create" />

这个例子把导出接口当作可识别变化。开发模式通常需要它核对实板配置，发行模式是否保留应按需求决策。需要 BPF、ftrace 等调试能力时，分别建立调试与产品配置，并逐项评价构建、运行和回退。

## 在不同 O= 目录求解和交叉编译

在 WSL 仓库根目录运行。可<a :href="exampleFile" download="kconfig-compare-demo.sh">下载 kconfig-compare-demo.sh</a>。脚本从 SDK 已成功构建的 ARM64 配置复制输入，在本地 `output/kconfig-compare.*` 建三组目录，最后重新编译其中两组的 `kernel/configs.o`。

~~~bash
bash learning-site/examples/kconfig-compare-demo.sh
~~~

| 用例 | 配置求解结果 | 本轮对照 |
| --- | --- | --- |
| baseline | 与候选参考配置相同 | GNU size text+data+bss = 46700 |
| no-proc-export | 只有 `IKCONFIG_PROC y → n` | 同口径为 46369 |
| dependency-conflict | `IKCONFIG y → n`，IKCONFIG_PROC 移除 | 演示子项请求被依赖约束覆盖 |

GNU size 汇总的两份对象相差 331 字节。汇总同时包含配置内容改变后可能不同的压缩数据以及代码和数据段，不能把这 331 字节换算成最终 Image、boot 分区或运行内存变化。完整镜像比较要使用同源、同工具链、相同压缩和打包层次，并分别记录对象、Image、映像大小及符号文件大小。此次验证的是配置和单对象，无需部署。

## 怎样设计可回退的板端验收

| 阶段 | 保留并检查 |
| --- | --- |
| 基线 A | 固定 git 基线、板型、DTB、工具链、运行配置、镜像和符号，记录 hash 与串口恢复入口 |
| 候选 B | 输入配置 diff 后独立构建，审核传递变化，保留 Image/DTB/模块与新符号 |
| 现场 B | 获确认后验证上电、挂根、串口与 ADB、probe、媒体拓扑、首帧、停流重开，再逐支路加压力 |
| 回 A | 按约定恢复并重复关键指标，检查温度、任务负载和偶发波动 |
| 报告 | 对照启动里程碑、镜像字节、帧间隔、错误计数、可用内存与恢复时间 |

若候选起不来，拿最后一个明确里程碑定位在 bootloader、内核早期、挂根还是应用。一旦有回退判据，按已确认方案回原镜像，保留候选证据再改。对本板还要区分 sensor probe、媒体链建立与最终得帧三个阶段。当前没改板端配置或刷写，完整镜像收益、启动和相机回归待现场。

## 本节复盘

1. **为什么向 .config 写 y，构建后却没有该项？** Kconfig 要解布尔和 tristate 依赖。读最终配置及 diff 解释父依赖和反向选择。
2. **vmlinux 小了，板端 boot 就一定小吗？** 比较的是不同产物。必须在同一层次对比相同压缩与打包方式。
3. **怎样证明裁剪没有损伤相机？** 验证启动与恢复、驱动绑定、媒体拓扑、首帧、稳定运行和各消费支路，并与 A 基线复测。

下一节把测量口径落到 FrameScope，记录工具如何收、怎么关联及什么时候必须输出证据不足。 [8.8 FrameScope 的采集、关联与可验证诊断](./framescope.md)
