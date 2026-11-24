# 5.7 Rockchip DPHY、CSI 接收器与 CIF

<script setup>
import exampleFile from '../examples/camera-route.awk?url'
</script>

IMX415 有媒体实体，却看不到 CIF 产生完整帧。先查候选路由是否连续，再逐跳找最早缺失的运行证据。硬件块、固件节点、媒体实体和应用节点分别记录。

## 先验收候选 DTB 的四对引用

在 WSL 仓库根目录执行。脚本使用本地 dtc 反编译文本的缩进、`/__symbols__` 和 phandle。它从名称找节点路径，逐对检查两边的 remote-endpoint 都指回对方。<a :href="exampleFile" download="camera-route.awk">下载候选路由检查</a>。

~~~bash
base=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
dtb="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
"$base/scripts/dtc/dtc" -q -I dtb -O dts "$dtb" | awk -f learning-site/examples/camera-route.awk
~~~

本轮四对引用均一致。若缺一对，命令返回 1，先查该构建是否保留符号，以及两端是否被板级文件覆盖。这里只校验候选引用，实际是否启用、媒体图是否成形、输入是否有帧分别取证。

| 固件端点 | 经过的部件 | 最早缺失证据怎么查 |
| --- | --- | --- |
| imx415_out0 ↔ csi_dphy_input0 | sensor 经差分线到 D-PHY 收端 | 查 sensor 退出待机、lane 配置、PHY 状态及 SoT |
| csidphy0_out ↔ mipi0_csi2_input | 接收物理数据后交给 CSI-2 控制器 | 查包的 VC、DT、帧边界和 ECC/CRC |
| mipi0_csi2_output ↔ cif_mipi_in0 | CSI-2 输出交给 CIF 捕获或路由 | 查 CIF 对应 stream 的帧事件、错误和路由 |
| mipi_lvds_sditf ↔ isp_vir0 | CIF 侧接口把数据送到 ISP 的一个输入实例 | 查 ISP 输入格式、select 与下游完整帧事件 |

最后一对使用的 sditf 节点还要通过 rockchip,cif 绑定 CIF 的逻辑输入实例。四对图连接之间，还有各节点内部的输入到输出及硬件资源关系。

## 逻辑实体怎样找到物理硬件和远端？

`arch/arm64/boot/dts/rockchip/rv1126b.dtsi:774`

~~~text
rkcif_mipi_lvds: rkcif-mipi-lvds {
	compatible = "rockchip,rkcif-mipi-lvds";
	rockchip,hw = <&rkcif>;
	status = "disabled";
};
~~~

SoC 公共文件把逻辑实例指向真实 CIF 硬件，同时通过板级文件选择需要启用的接收路径。物理 CIF 经 CRU 获取访问和数据时钟、复位，上游有单独的 D-PHY/CSI 组件。涉及内存访问时，还要核对 rkcif_mmu、设备绑定和实际 DMA 映射。一个物理 CIF 可以服务多个软件对象，名字带 MIPI 也不能说明它负责物理层或提供了几个独立应用流。

`drivers/media/platform/rockchip/cif/dev.c:2264`

~~~c
v4l2_async_nf_init(ntf);

ret = v4l2_async_nf_parse_fwnode_endpoints(
		dev, ntf, sizeof(struct rkcif_async_subdev), rkcif_fwnode_parse);
~~~

notifier 收集固件中的端点依赖。注册与绑定完成后，媒体框架才能观察到相应链接。有实体也要进一步核对连接和格式。本轮按同一份本地历史确认 ISP 图里 rkcif-mipi-lvds 到 rkisp-isp-subdev 的链接启用。更上游的运行图仍需独立采样。

## Online 与内存中转有什么影响？

~~~text
Online：CIF 输出 → ISP 接收
内存中转：CIF 写缓冲 → 完成通知 → ISP 读取缓冲 → 归还
~~~

在线连接需要生产与消费的时序配合，内存中转则增加缓冲交付、读写带宽和等待。输出端到应用都还要遵循实际捕获队列。判断一次开流的模式，要查看 sditf/rkisp 的配置与运行证据。拓扑上的连接本身无法证明确实走了哪种路径。

CIF 用以下逻辑检查垂直消隐。行时间与消隐行数相乘，换算到微秒后与门槛比较。

`drivers/media/platform/rockchip/cif/capture.c:13683`

~~~c
tline = rkcif_get_linetime(&dev->stream[0]);
vblank = rkcif_get_sensor_vblank(dev);
vblank_us = tline * vblank;
vblank_us = div_u64(vblank_us, 1000);
if (vblank_us < 1000)
~~~

历史记录中的 859 µs 比该门槛少 141 µs。它是驱动根据供给参数得到的估计和告警，有同一批保存的成功出队记录。评估影响需对齐采集窗口、模式、路由、丢帧和错误增量。本轮用下列命令复核本地历史。

~~~bash
rg -n 'vblank need' output/camera-check/dmesg-after.log
rg -n 'rkcif-mipi-lvds|rkisp-isp-subdev' output/camera-check/isp-before.log
bash learning-site/examples/frame-intervals.sh output/camera-check/capture.log
~~~

复算得到 31 帧、0 序号缺口及 30.000 fps。短窗口和计数只覆盖已有采集。若有 sensor 实体但无 CIF 帧，先对齐接收器的包与帧边界；若 CSI 有正确通道的帧边界而 CIF 未见事件，优先核对 CIF stream 路由。实板仍需取同一启动和同一窗口的状态证据。

## 本节复盘

1. 四对端点全部互指，为何还不能直接断言能出图？列出运行时要补的证据。
2. D-PHY 收到高速数据和 CSI-2 解析出期待 VC 的帧分别验证哪一层？
3. 使用内存中转时，哪些新的带宽、缓冲和完成时刻要纳入分析？
4. 859 µs 告警和短采集成功能否同时出现？怎样验证该告警是否影响长时间运行？

下一节在运行媒体图里标出 entity、pad、link 和活动格式。[5.8 Media Controller 的 entity、pad 与 link](media-graph.md)
