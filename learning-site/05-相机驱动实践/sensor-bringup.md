# 从一块待适配的模组，到第一条出流请求

原厂 RV1126B 已经驱动过 IMX415。把这次成功记录留作对照，假设现在收到的是一块还没有 sensor 节点的新板：第一次修改什么，怎样知道改对了，哪些结果只能等上电后验证？下面先依靠本地 SDK 与历史记录练习，不改工作中的设备。

<a id="checklist"></a>

新板、模组与出图基线的准备见[5.1 接手未适配模组，先写移植清单](module-checklist.md)。

<a id="first-id"></a>

普通上电和芯片 ID 的证据见[5.2 第一次上电、复位、XCLK 与读 ID](first-power-id.md)。

<a id="structure"></a>

实例、回调与资源收尾见[5.3 拆开一个完整 sensor 驱动](sensor-driver.md)。

<a id="mode-card"></a>

寄存器表、线性模式与控制见[5.4 寄存器表、模式、曝光与增益](sensor-mode.md)。
