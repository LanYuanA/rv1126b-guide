# 从一颗 IMX415 认清 device、driver 与 bus

新板上焊着 I2C 控制器，插座上接着 IMX415。Linux 刚启动时，哪一行代码能证明摄像头存在？要回答这个问题，先把“板上接了什么”“固件描述了什么”“内核创建了什么”“实际应答了什么”分开。下面一直跟第一路 I2C3。

<a id="objects"></a>

设备、总线和驱动的注册与绑定见[4.1 device、driver、bus 与 sysfs](device-bus.md)。

<a id="platform"></a>

寄存器、IRQ 和时钟资源见[4.2 platform 总线、资源与 MMIO](platform-mmio.md)。

<a id="board-data"></a>

旧式板级 C 数据见[4.3 传统板文件与 platform_data](legacy-board.md)。
