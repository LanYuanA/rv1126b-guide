# 从 IMX415 输出的 RAW 追到 ISP 的输入端

读到 ID 只走了 I2C。要判断第一帧在哪一段消失，接下来分别观察承载信号的线、线上传的包、接收端的路由和内核发布的媒体图。以下以[四 lane 线性模式](sensor-mode.md)为起点，WSL 命令在工作区根目录执行。

<a id="dphy"></a>

物理线路和带宽估算见[5.5 MIPI D-PHY 的物理链路](dphy.md)。

<a id="packets"></a>

包头、虚拟通道和 RAW10 载荷见[5.6 CSI-2 的包、数据类型与虚拟通道](csi2-packets.md)。

<a id="receiver"></a>

接收路径和帧证据见[5.7 Rockchip DPHY、CSI 接收器与 CIF](rockchip-receiver.md)。

<a id="graph"></a>

实体、pad、链接和运行格式见[5.8 Media Controller 的 entity、pad 与 link](media-graph.md)。

<a id="async"></a>

远端匹配与注册顺序见[5.9 V4L2 subdev 与异步绑定](subdev-async.md)。
