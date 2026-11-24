# RV1126B 驱动开发路线

从一块新板开始，最后交付三个可验收的东西：一条能解释到硬件与内核的成像链，一套经过测量的并发相机方案，一份能说明性能变化和误报边界的调试报告。已有默认固件能出图，适合作为“尚未适配的新板”实验的对照组。学习时每次只做一小节，记录观察、推理和疑问，确认后再往下走。

## 八卷开发路线

[按 84 章查看完整学习大纲](学习大纲.md)。

卷序对应工作区分章计划。下方与分章计划一同提供八卷正文入口。

### 卷1　接手 RV1126B 与开发环境

- [1.1 认识 RV1126B、摄像头模组与原理图](../01-开发环境/board.md#hardware) · [1.2 分清 WSL、串口、ADB 与目标机](../01-开发环境/board.md#terminals) · [1.3 Linux 命令、文件权限、进程与日志](../01-开发环境/board.md#files)
- [1.4 Git、SDK 目录与源码检索](../01-开发环境/board.md#source-search) · [1.5 用 C 表达驱动里的数据和回调](../01-开发环境/function-pointers.md)
- [1.6 编译、链接、ELF、符号与交叉工具链](../01-开发环境/build.md#elf) · [1.7 从上电读到 PID 1](../01-开发环境/boot.md)

### 卷2　从应用接口到第一个字符驱动

- [2.1 应用文件 I/O 与 errno](../02-应用与字符驱动/file-io.md) · [2.2 ARM64 同步异常与系统调用](../02-应用与字符驱动/arm64-syscall.md) · [2.3 VFS 中的路径、设备号与一次打开](../02-应用与字符驱动/first-lesson.md#vfs)
- [2.4 模块、内建驱动与 Kbuild](../02-应用与字符驱动/kbuild.md) · [2.5 字符设备号与 file_operations](../02-应用与字符驱动/char-fops.md) · [2.6 传统 register_chrdev 注册法](../02-应用与字符驱动/register-chrdev.md) · [2.7 显式 cdev](../02-应用与字符驱动/cdev.md)
- [2.8 misc 与会话](../02-应用与字符驱动/miscdevice.md) · [2.9 接口约定](../02-应用与字符驱动/io-contract.md) · [2.10 错误回退与卸载](../02-应用与字符驱动/driver-lifetime.md)

### 卷3　Linux 内核核心子系统

- 源码主线：[调度器](../03-Linux内核/调度器实现.md) · [内存管理](../03-Linux内核/内存管理实现.md) · [文件管理与 VFS](../03-Linux内核/文件管理.md)

- [3.1 进程、线程与资源共享](../03-Linux内核/process.md#tasks) · [3.2 调度器与唤醒延迟](../03-Linux内核/调度器实现.md)
- [3.3 ARM64 中断与通用 IRQ 子系统](../03-Linux内核/irq.md) · [3.4 延后处理、等待队列与 completion](../03-Linux内核/deferred-work.md) · [3.5 锁与对象寿命](../03-Linux内核/locking.md) · [3.6 时间戳与帧间隔](../03-Linux内核/kernel-time.md)
- [3.7 虚拟内存、页表与缺页](../03-Linux内核/virtual-memory.md) · [3.8 物理页、伙伴系统与 CMA](../03-Linux内核/page-allocation.md) · [3.9 SLUB、kmalloc 与内存分配上下文](../03-Linux内核/slub.md)
- [3.10 文件系统、挂载与打开文件的寿命](../03-Linux内核/文件管理.md) · [3.11 页缓存、脏页与写回](../03-Linux内核/writeback.md) · [3.12 块层、存储请求与尾延迟](../03-Linux内核/block-io.md)

- [3.13 DMA 与缓冲所有权](../03-Linux内核/dma-ownership.md) · [3.14 IOMMU、IOVA 与 scatter-gather](../03-Linux内核/iommu.md) · [3.15 DMA-BUF 导出、导入与同步](../03-Linux内核/dmabuf.md)

### 卷4　Linux 设备模型与板级资源

- 框架源码：[pinctrl](../04-设备模型与驱动子系统/pinctrl子系统.md) · [GPIO](../04-设备模型与驱动子系统/GPIO子系统.md)

- [4.1 device、driver、bus 与 sysfs](../04-设备模型与驱动子系统/device-bus.md) · [4.2 platform 总线、资源与 MMIO](../04-设备模型与驱动子系统/platform-mmio.md) · [4.3 传统板文件与 platform_data](../04-设备模型与驱动子系统/legacy-board.md)
- [4.4 DTS、DTSI、binding 与 DTB](../04-设备模型与驱动子系统/devicetree.md) · [4.5 OF 匹配、probe、remove 与延迟探测](../04-设备模型与驱动子系统/of-probe.md)
- [4.6 pinctrl 子系统](../04-设备模型与驱动子系统/pinctrl子系统.md) · [4.7 GPIO/gpiolib 子系统](../04-设备模型与驱动子系统/GPIO子系统.md) · [4.8 Common Clock Framework](../04-设备模型与驱动子系统/clock-framework.md) · [4.9 regulator 与供电时序](../04-设备模型与驱动子系统/regulator.md) · [4.10 reset controller 与复位 GPIO](../04-设备模型与驱动子系统/reset.md) · [4.11 runtime PM 与系统休眠](../04-设备模型与驱动子系统/runtime-pm.md)
- [4.12 I2C 核心、控制器与 IMX415 client](../04-设备模型与驱动子系统/i2c.md)
  - [I2C 上篇 · 两根线与三种地址](../04-设备模型与驱动子系统/i2c-wire.md)
  - [I2C 中篇 · 从设备树到寄存器读](../04-设备模型与驱动子系统/i2c-probe.md)
  - [I2C 下篇 · 中断、等待与故障定位](../04-设备模型与驱动子系统/i2c-irq.md)

### 卷5　从空白适配到 IMX415 第一帧

- [5.1 接手未适配模组，先写移植清单](../05-相机驱动实践/module-checklist.md) · [5.2 第一次上电、复位、XCLK 与读 ID](../05-相机驱动实践/first-power-id.md) · [5.3 拆开一个完整 sensor 驱动](../05-相机驱动实践/sensor-driver.md) · [5.4 寄存器表、模式、曝光与增益](../05-相机驱动实践/sensor-mode.md)
- [5.5 MIPI D-PHY 的物理链路](../05-相机驱动实践/dphy.md) · [5.6 CSI-2 的包、数据类型与虚拟通道](../05-相机驱动实践/csi2-packets.md) · [5.7 Rockchip DPHY、CSI 接收器与 CIF](../05-相机驱动实践/rockchip-receiver.md)
- [5.8 Media Controller 的 entity、pad 与 link](../05-相机驱动实践/media-graph.md) · [5.9 V4L2 subdev 与异步绑定](../05-相机驱动实践/subdev-async.md)
- [5.10 RKISP 与视频设备节点](../05-相机驱动实践/rkisp-video-node.md) · [5.11 VB2 缓冲队列、DMA 与帧完成](../05-相机驱动实践/vb2-queue.md)
- [5.12 独立实现 C 采帧与图像验证](../05-相机驱动实践/capture-client.md)

### 卷6　相机应用、编码与多路分流

- [6.1 GStreamer 元素、pad 与 caps](../06-相机应用与分流/gst-elements.md)
- [6.2 pipeline 状态、时钟、PTS 与 bus](../06-相机应用与分流/gst-timing.md) · [6.3 v4l2src、appsink 与内存协商](../06-相机应用与分流/gst-appsink.md)
- [6.4 tee、queue、背压与丢帧策略](../06-相机应用与分流/gst-queues.md) · [6.5 Rockchip VI、VPSS、VENC 与 MPP](../06-相机应用与分流/rockchip-media.md)
- [6.6 H.264/H.265、GOP、封装与分段](../06-相机应用与分流/video-segments.md) · [6.7 单 sensor 的预览、主录、备录与拍照](../06-相机应用与分流/multistream.md)
- [6.8 快门前后缓存与动态照片](../06-相机应用与分流/motion-photo.md)
- [GStreamer 的 WSL 环境](../06-相机应用与分流/gstreamer.md)

### 卷7　成像、ISP 与高级控制

- [7.1 光学、曝光、噪声与 Bayer 采样](../07-成像与调校/optics-exposure.md)
- [7.2 RAW10、RAW12、NV12 与色彩解释](../07-成像与调校/pixel-layout.md) · [7.3 ISP 图像处理流程](../07-成像与调校/isp-pipeline.md)
- [7.4 RKAIQ、统计节点、参数节点与 IQ](../07-成像与调校/rkaiq-control.md) · [7.5 自动曝光 AE](../07-成像与调校/auto-exposure.md)
- [7.6 自动白平衡 AWB](../07-成像与调校/auto-white-balance.md) · [7.7 自动对焦 AF 与镜头执行器](../07-成像与调校/auto-focus.md)
- [7.8 多曝光 HDR 与运动伪影](../07-成像与调校/hdr-exposure.md) · [7.9 AI ISP 的输入契约与性能代价](../07-成像与调校/ai-isp.md)
- [7.10 光学变焦、数字变焦与自动取景](../07-成像与调校/advanced.md)

### 卷8　内核诊断、裁剪、FrameScope 与答辩

- [8.1 性能基线、采样与测量误差](../08-诊断裁剪与面试/performance-baseline.md)
- [8.2 内核日志、dynamic debug、符号与调用栈](../08-诊断裁剪与面试/kernel-debug-log.md) · [8.3 proc、sysfs 与 debugfs 的测量口径](../08-诊断裁剪与面试/kernel-metrics.md)
- [8.4 ftrace、tracepoint 与跨层时间线](../08-诊断裁剪与面试/trace-timeline.md) · [8.5 perf 与 CPU 热点](../08-诊断裁剪与面试/perf-hotspots.md)
- [调试工具与告警排查](../08-诊断裁剪与面试/diagnostics.md)
- [8.6 eBPF、BTF 与板端配置判定](../08-诊断裁剪与面试/ebpf-prerequisites.md) · [8.7 Kconfig、内核裁剪与可恢复的适配](../08-诊断裁剪与面试/trimming.md)
- [8.8 FrameScope 的采集、关联与可验证诊断](../08-诊断裁剪与面试/framescope.md) · [8.9 稳定性、并发回归与恢复](../08-诊断裁剪与面试/camera-regression.md)
- [8.10 项目报告、简历陈述与面试答辩](../08-诊断裁剪与面试/defense.md)

## 按现象查找排查入口

| 你手上有什么 | 去哪里找下一个证据 |
| --- | --- |
| 一块板和 SDK，尚不清楚哪份代码在运行 | 卷 1。先拿板型、运行配置、设备树和编译产物 |
| 能读 ID，但还没有彩色像素 | 卷 4–5。找 sensor stream、每段实体/pad、ISP 输出队列 |
| 有图但某一分支慢、内存涨、关流后不回落 | 卷 3、6、8。用缓冲所有权、调度和写回设计单变量对照 |
| 要准备面试并给出具体工作量 | [案例答辩](../08-诊断裁剪与面试/defense.md)与[原作者资料](references.md)。把答案里的推断换成自己的证据 |

## 怎么动手，什么算真的做过

1. 命令标有 WSL 时，从项目根目录开始。`adb shell '...'` 里的命令由板端执行。独立代码块各自从标明的目录开始。短源码在正文中直接显示，代码块上方标注 SDK 文件和行号。需要查看完整函数时，在相应版本的 SDK 中打开所标文件。内核基线提交为 `a04e4b3c`。
2. [字符驱动](../02-应用与字符驱动/char-driver.md)、[采集客户端](../05-相机驱动实践/capture-client.md) 和 [GStreamer 应用](../06-相机应用与分流/gst-appsink.md) 在正文分段解释关键源码，并提供独立实验文件。先猜输出，再改一个条件。把第一条错误、排除它所需的观察、修改与回归按顺序写进同一主题笔记。
3. 已有**板端**证据是原厂 6.1.141、3-001a 读到 0xe0、单路 4K NV12 短采集。此次**WSL 本地验证**包括 AArch64 模块与应用编译、离线 DTB 修改、Kconfig 差分、合成分流、日志重算。独立编译的内核和便笺模块仍待板端启动/加载。HDR、AI ISP、镜头能力、四路并发和相册兼容要按卷 6、7 的条件另验。
4. 没有板子时可以先做 fd、pipe、匿名内存、文件引用、合成视频和合成日志。涉及真实推流时先核对节点与占用。停止服务、重启和刷机要在明确恢复方案并确认之后开展。

第一节的学习成果是一份可核对的板卡基线。要优先理解驱动形状，可以先从 [03 fd 与字符设备](../02-应用与字符驱动/first-lesson.md) 读到 [04 手写驱动](../02-应用与字符驱动/char-driver.md)，再回卷 1 确认构建环境。
