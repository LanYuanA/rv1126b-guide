# 设备树到应用取帧

先复用已验证的原厂链路，沿实物和本地 6.1.141 SDK 学习。每一层都建立自己的通过条件。

| 小节 | 从哪里读 | 用什么证明 |
| --- | --- | --- |
| 板级描述 | `rv1126b-alientek.dtsi` 的 I2C3、IMX415 和 DPHY endpoint | 运行设备树、原理图、GPIO 极性与 pinmux 对应 |
| Probe | `imx415.c` 的匹配表、获取资源、power-on、读 ID | `3-001a` 绑定及 `Detected imx415 id 0000e0` 日志 |
| 传感器控制 | 寄存器表、V4L2 controls、模式选择、runtime PM | 确认线性模式、RAW10、lane 数与格式。切换实验另开步骤 |
| 接收链路 | DPHY、CSI-2、CIF、ISP、media entity/pad/link | `media-ctl -p` 与活动格式，逐段定位不匹配 |
| 应用取帧 | open、QUERYCAP、REQBUFS、QBUF、STREAMON、DQBUF | 序号、时间戳、stride、有效字节和可查看预览 |
| 正常退出 | STREAMOFF、解除映射、close 与资源归还 | 日志、采集进程、队列和资源回到可解释的状态 |

## 新板从零适配的全景图

~~~text
开发：原理图、模组时序 → 板级 DTS / 驱动配置 → 编译 DTB 和内核
启动：引导器选 DTB → 总线创建设备 → match / probe → 硬件读 ID → 发布 subdev
连接：DPHY / CSI / CIF / ISP 各自 probe → graph 与异步绑定 → 捕获节点可用
使用：应用 open → VFS → V4L2 → 设格式、空缓冲入队、开流 → sensor 发 RAW
返回：CSI 接收 → CIF / ISP / DMA → 帧完成 IRQ → VB2 唤醒 → 应用 DQBUF
消费：GStreamer source → caps / 队列 → 预览、录像或 JPEG → 归还缓冲
~~~

| 想跟哪一段代码 | 正文 |
| --- | --- |
| 从新板补 DTS 到 pinmux、上电和读取 ID | [设备树](../04-设备模型与驱动子系统/devicetree.md) → [GPIO、pinctrl、clock、regulator](../04-设备模型与驱动子系统/pins.md) → [I2C 与 probe](../04-设备模型与驱动子系统/i2c.md) |
| 从传感器模式表到真正送出像素 | [IMX415、CSI 与 media graph](../05-相机驱动实践/sensor.md) → [V4L2 与 VB2](../05-相机驱动实践/capture.md) |
| 从 API 到第一次自己写的采集应用 | [完整单帧 C 程序](../05-相机驱动实践/capture-client.md) → [GStreamer pad 与 caps](../06-相机应用与分流/gst-elements.md) |
| 从“有图”到实际产品 | [3A、HDR 与镜头](../07-成像与调校/imaging.md) → [分流和动态照片](../06-相机应用与分流/multistream.md) |

## 三条关系

- **设备建立**从 DTS 到 I2C client，随后 match 和 probe，媒体组件各自注册后组成管线。
- **控制**从应用 ioctl 经 V4L2/VB2 到 RKISP 和相关 subdev。传感器寄存器经 I2C 写入。
- **数据**从 IMX415 的 Bayer RAW 经 CSI 接收、ISP、DMA 到缓冲区。驱动提交完成缓冲，应用从 mmap 的内存读取数据。

已实测的是默认固件一次短时 4K NV12 采集，期间保留 3A 服务。记录中的 vblank 警告属于后续排错案例。移植前先看[未适配模组的移植清单](../05-相机驱动实践/module-checklist.md)，再从[完整 sensor 驱动](../05-相机驱动实践/sensor-driver.md)追踪回调。 [Linux 6.1 V4L2 应用文档](https://github.com/torvalds/linux/tree/v6.1/Documentation/userspace-api/media/v4l) · [VIMC 虚拟媒体链路](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/media/vimc.rst)

## 建立一次最小只读证据链

在普通 ADB 可使用的 WSL 终端查询运行节点与媒体图。

```bash
adb devices -l
adb shell 'readlink -f /sys/bus/i2c/devices/3-001a/of_node'
adb shell 'readlink -f /sys/bus/i2c/devices/3-001a/driver'
adb shell 'dmesg | grep -i imx415 | tail -n 20'
adb shell 'v4l2-ctl --list-devices'
adb shell 'media-ctl -d /dev/media3 -p'
```

先核对设备编号。当前参考固件中第一路的驱动链接指向 IMX415。读到 ID 才能确认发生了硬件检测。媒体图则帮助从接收端找到 ISP 输出。若出现节点缺失，先确认设备有没有连上、编号有无变化以及工具权限，再检查是否停在更早的一层。主动采帧前核对运行中的服务与节点占用。

**本节验收** 画出控制线和像素线，给每一层写一条可观察证据。复盘可以从“相机有 I2C 应答，为什么仍可能没帧”开始。
