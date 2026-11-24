# 5.5 MIPI D-PHY 的物理链路

<script setup>
import exampleFile from '../examples/dphy-budget.awk?url'
</script>

I2C 已经读到 ID，像素接下来要过另一组线。先看一条数据 lane 一秒要搬多少位，再去确认实际 lane 排列、接收状态及计数。

## 用同一模式算四 lane 和两 lane

在 WSL 仓库根目录运行。第一条打印本板接收端候选 lane，第二条是原厂历史中的接收驱动配置值。最后按同一模式与名义速率做离线比较。<a :href="exampleFile" download="dphy-budget.awk">下载有效载荷演算</a>。

~~~bash
dts=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi
rg -n -A4 'csi_dphy_input0: endpoint' "$dts"
rg -m1 'rockchip-csi2-dphy0: dphy0, data_rate_mbps 892' output/camera-check/dmesg-after.log
awk -f learning-site/examples/dphy-budget.awk
~~~

本例用 3864×2192、30 fps、10 位计算单个有效 Bayer 样本，载荷约为 2.541 Gbit/s。模式菜单的 446 MHz 按双边沿换算为名义 892 Mbit/s 每数据 lane。历史日志的 892 也是驱动计算值。

| 假设 lane 数 | 平均每 lane 有效载荷 | 相对 892 Mbit/s |
| --- | ---: | ---: |
| 4 | 635.242 Mbit/s | 71.22% |
| 2，保持其他条件 | 1270.483 Mbit/s | 142.43% |

两 lane 在这些固定假设下连平均有效载荷都容纳不了。四 lane 的平均值通过只是一项必要条件。包头、校验、嵌入行、高速切换和实际发送窗口都会影响所需速率。若移动或减少 lane，必须选择匹配的模组模式、接收配置与速率。应用 NV12 字节数属于 ISP 输出，不能用它估 CSI 输入带宽。

## 电气线路与包各由谁解释？

本板讨论的是转发时钟的 D-PHY。时钟对提供采样定时，数据对并行搬运数据。数据 lane 在低功耗状态使用线路状态表达控制，在高速状态以差分信号发送。接收器必须正确识别低功耗到高速的转换和接收窗口。CSI-2 在物理传输之上定义包与数据类型，下一节再拆其字节格式。[MIPI D-PHY](https://www.mipi.org/specifications/d-phy) · [MIPI CSI-2](https://www.mipi.org/specifications/csi-2)

~~~text
模式与寄存器 → sensor 发 CSI-2 包
  → D-PHY 的时钟对与数据差分对 → SoC D-PHY 接收
  → CSI-2 控制器解析包 → 对应的 VC/DT 再交给下游
~~~

| 模组到 SoC | 当前可从软件核对 | 现场还缺什么 |
| --- | --- | --- |
| CLK± | 当前模式、link frequency、前后端连续时钟约定 | 板修订连接、极性及工作波形 |
| 四个数据差分对 | 两端的逻辑到物理索引，本例 data-lanes 为 1、2、3、4 | 插座针脚、极性、串扰、端接与眼图 |
| XCLK | 模式的参考时钟及 CRU 与 pinctrl 配置 | 模组端频率及幅值 |
| I2C SCL/SDA | 寄存器配置和读回结果 | 总线波形及应答 |

固件索引由 binding 解释。数据 lane 数字不能直接代替连接器针脚号，也不能说明硬件允许任意交换线路。先核对两端映射，再看接收端实际使用的模式。

## 速率值从 sensor 怎样传到收端？

`drivers/media/i2c/imx415.c:1618`

~~~c
config->type = V4L2_MBUS_CSI2_DPHY;
config->bus.mipi_csi2.num_data_lanes = lanes;
~~~

lanes 取自 sensor 已解析的 bus_cfg。这两句向框架报告类型与数量，仍要对照两端 DT 及实际返回值。速率走另一条路径。Rockchip 收端读取 sensor 的 LINK_FREQ 控制菜单，取得项目值后换算。

`drivers/phy/rockchip/phy-rockchip-csi2-dphy.c:112`

~~~c
dphy->data_rate_mbps = qm.value * 2;
do_div(dphy->data_rate_mbps, 1000 * 1000);
~~~

输入是 Hz，输出为每 lane 的 Mbit/s。配置值和运行日志便于查是否拿错菜单项。实际速率、信号幅值和接收裕量需要现场证据。先固定模组、排线、lane 数和模式，再采同一时间窗的接收错误及帧完成状态。若只有一种速率出错，应在保持其余条件的对照中验证；若只错某个 VC，则先核对包路由。

## 哪些跨平台术语可以对照？

| 原项目用语 | 可确认的通用含义 | 需要补齐的上下文 |
| --- | --- | --- |
| C-PHY 与 T3 | C-PHY 用三线组和嵌入时钟。公开时序图有 t3-PREPARE、t3-SETTLE 等不同窗口 | 完整字段名、TX/RX 角色、PHY 版本、单位和驱动编码 |
| EPD | CSI-2 的 LRTE 特性表中，EPD 表示 Efficient Packet Delimiters，D-PHY 与 C-PHY 各有相关条目 | 原项目字段是否指这个功能，两端是否支持及实际协议模式 |
| Swing、阻抗（Zos） | 分别先问输出摆幅及所指的阻抗类别。差分走线阻抗、端接与驱动输出阻抗属于不同测量位置 | 字段定义、量纲、原理图、寄存器或测点。Zos 的具体含义仍需原文 |
| RAW bit | 像素样本位深，如 RAW10 的 10 位 | 实际 DT、packing、lane 速率和接收端内存格式 |
| GNSS | 目前没有该字段的 PHY 上下文 | 完整变量或配置路径、日志前后文及对应文档 |

通用名的依据可核对 [MIPI C-PHY](https://www.mipi.org/specifications/c-phy)、[MIPI 公开时序示意](https://www.mipi.org/hubfs/Webinars/MIPI-Webinar-CSI-Mobile-Beyond-Imaging-Interface-Development.pdf) 与 [CSI-2 特性表](https://www.mipi.org/hubfs/Specification-Feature-Tables/MIPI-CSI-2-Version-History-Table-March-2026.pdf)。原项目的字段仍需原配置确认，数值不能跨 PHY 和 SoC 直接沿用。

## 本节复盘

1. 446 MHz 和 892 Mbit/s 分别在哪一层出现？为什么填错单位会配置错？
2. 四 lane 的平均载荷占比低于 100%，为什么仍需核对高速发送窗口和错误计数？
3. I2C 读 ID 正常而接收端无帧，怎样区分 lane/物理传输、模式启动和 VC/DT 路由？
4. 承接另一项目的 T3、EPD、摆幅或阻抗配置，还需要拿到哪些资料？

本轮核对本地源码、历史配置日志与离线算术，未量测板端信号。下一节打开 CSI-2 数据包。[5.6 CSI-2 的包、数据类型与虚拟通道](csi2-packets.md)
