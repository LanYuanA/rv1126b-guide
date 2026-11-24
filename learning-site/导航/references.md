# GitHub 资料与面试题

## Linux 底软与内核

- **题目索引**可从社区汇总挑选 VFS、内存分配、中断、工作队列与启动题目。答案需要用实际架构和内核版本核对。 [0voice/linux_kernel_wiki](https://github.com/0voice/linux_kernel_wiki)
- **嵌入式 Linux 实验**可参考 Bootlin 的驱动模型说明与配套实验步骤。 [bootlin/training-materials](https://github.com/bootlin/training-materials)
- **版本依据**优先用本地 Rockchip SDK 的 Documentation 和源码。公开引用用 Linux v6.1 文档了解公共接口，厂商分支行为以本地版本为准。 [Linux v6.1 Documentation](https://github.com/torvalds/linux/tree/v6.1/Documentation)

## 相机驱动

相机类资料多是驱动实例和框架教程。首轮调研有可借鉴的案例，适合从源码和实验中编写项目自己的面试题。

- **从拓扑开始**看虚拟 sensor、debayer、scaler 与 capture 的关系。 [Linux VIMC 文档](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/media/vimc.rst)
- **对照相机应用框架**了解 libcamera 如何利用 V4L2/Media Controller 组织管线。 [libcamera Pipeline Handler 指南](https://github.com/libcamera-org/libcamera/blob/master/Documentation/guides/pipeline-handler.rst)
- **看真实 sensor 驱动**追踪模式表、控制、供电和 subdev。使用主线同类驱动理解结构，再回到本地 IMX415 和板级 DTS。 [Linux v6.1 IMX219 驱动](https://github.com/torvalds/linux/blob/v6.1/drivers/media/i2c/imx219.c)
- **看跨平台实验案例**了解另一个作者的 SerDes 与媒体拓扑调试思路。阅读时留意 SerDes 聚合链路与本板单颗 IMX415 直连方案的差异。 [GMSL2 调试日志](https://github.com/Ztwon/GMSL2)

要练习有答案、反例和证据的连环追问，请进入[项目案例答辩](../08-诊断裁剪与面试/defense.md)。要理解开源项目中哪些机制可复用、哪些需要自己实现，请读[FrameScope 的设计与验证](../08-诊断裁剪与面试/framescope.md)。

## 第一批复盘题

| 面试问题 | 答案要覆盖什么 |
| --- | --- |
| 为什么硬中断不能睡眠？ | 解释当前执行上下文与调度条件，区分线程化 IRQ 和 workqueue，再回到这版驱动的完成路径。 |
| inode、dentry、file 和 fd 分别是什么？ | 先讲路径与对象，再用同一字符设备被打开两次说明 fd 与设备号的关系。 |
| mmap 为何仍可能发生缺页？ | 讲映射建立与具体页访问的区别，比较普通文件映射与驱动缓冲映射的适用路径。 |
| probe 成功但 DQBUF 超时怎么查？ | 对照 sensor stream、CSI 接收、缓冲提交和 VB2 唤醒四层证据。 |
| RAW10、NV12 和 JPEG 各在什么位置？ | 画 sensor 到 ISP 再到应用编码的链路，说明数据布局、stride 与位深。 |
| 预览正常但录像卡顿怎么查？ | 区分采集、编码、写盘和队列积压，说明如何通过同场景对照排除其他原因。 |

这里的主题索引和面试问题参考了 AIInfraGuide 的组织思路。 [AIInfraGuide](https://caomaolufei.github.io/AIInfraGuide/)

## 两道示范题怎么答

### 为什么没有帧时要等 DQBUF？IRQ 触发后应用会立即运行吗？

应用等待的是采集队列上出现可取出的缓冲。硬件完成后，驱动通过 VB2 标记状态并唤醒等待者。唤醒使进程具备被调度的条件，接下来何时运行还取决于 CPU、优先级及竞争。排查时可以分别寻找帧完成、队列完成、唤醒、调度切入与应用出队的时间点。非阻塞模式下，暂时没有缓冲时需处理 `EAGAIN`。 [Linux 6.1 VB2 实现](https://github.com/torvalds/linux/blob/v6.1/drivers/media/common/videobuf2/videobuf2-core.c)

### 为什么录像卡顿不能直接归因于 MIPI？

预览和录像可能共享采集，也有各自的处理队列。先看采集序号和时间戳是否连续，再比对编码输入和输出、写入等待和缓冲占用。例如采集仍连续但录像等待写入的队列增长，说明应优先验证存储和背压。调整单个写入条件并复测，才有证据判断变化来自哪里。这个例子是排查方法，当前项目尚未跑录像对照。


## 章节组织参考

本地《I.MX6U 嵌入式 Linux 驱动开发指南 V1.9》的目录和第四十五章可用于参考章节组织。该章先分别解释 pinctrl 与 GPIO，再进入控制器代码、设备树和驱动实验。本项目采用相近的阅读顺序，接口和寄存器行为以本工作区 Linux 6.1 SDK 为准。语雀两页取到了标题与公开简介，详细内容以本地 PDF 实际可读部分为参考。[嵌入式 Linux 内核驱动基础](https://alientek.yuque.com/nfzuim/tsl6qb/hfvf2aos235i3p3b) · [GPIO 子系统](https://alientek.yuque.com/nfzuim/tsl6qb/lr37y36rw8y9x9wn)
