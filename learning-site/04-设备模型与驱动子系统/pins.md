# 从接插件上的五根信号读 IMX415 的上电代码

第一次读 ID 之前，CPU 要能驱动 I2C3，模组要得到电源、退出复位并取得输入时钟。按这几个条件回读第一路 DTS，可以把 pinctrl、GPIO、时钟、供电和运行时电源管理放到同一次探测里。本文所有命令在 WSL 的项目根目录执行，读的是 SDK 和历史日志。

<a id="pinmux"></a>

管脚复用、状态与电气设置见[4.6 pinctrl 子系统](pinctrl子系统.md)。

<a id="gpio"></a>

GPIO 描述符与逻辑电平见[4.7 GPIO/gpiolib 子系统](GPIO子系统.md)。

<a id="clock"></a>

时钟树与 XCLK 使能见[4.8 Common Clock Framework](clock-framework.md)。

<a id="rails"></a>

电源提供者和普通上电时序见[4.9 regulator 与供电时序](regulator.md)。

<a id="reset"></a>

SoC 复位控制器和模组 XCLR 见[4.10 reset controller 与复位 GPIO](reset.md)。

<a id="pm"></a>

引用与开停流见[4.11 runtime PM 与系统休眠](runtime-pm.md)。
