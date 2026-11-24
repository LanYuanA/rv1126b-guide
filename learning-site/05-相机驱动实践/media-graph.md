# 5.8 Media Controller 的 entity、pad 与 link

<script setup>
import exampleFile from '../examples/isp-topology.awk?url'
</script>

应用能打开历史记录里的 /dev/video23，怎样知道进入它的图像来自哪个实体？从实体名向上游追，分别记下链接是否启用、两端的活动格式以及哪个组件做了转换。

## 先从原厂快照提取四条边

在 WSL 仓库根目录运行。脚本只读历史 media-ctl 输出，抽取指定媒体图里的四条边和 stream 0 的格式。<a :href="exampleFile" download="isp-topology.awk">下载历史拓扑查询</a>。

~~~bash
awk -f learning-site/examples/isp-topology.awk output/camera-check/isp-before.log
rg -n 'Width/Height|Pixel Format|Bytes per Line|Size Image' output/camera-check/isp-before.log
rg -m1 'imx415 3-001a: s_stream: 1' output/camera-check/dmesg-after.log
~~~

本轮看到下面四条边均启用。mainpath 的名字映射到历史的 /dev/video23。缺 pad 格式时，脚本标为未记录，留给对应节点的 ioctl 查询。只克隆站点、尚未取得原始记录时，可先按表比较各阶段。

| 历史图位置 | 格式或职责 |
| --- | --- |
| rkcif-mipi-lvds pad0 → ISP pad0 | 两端都是 SGBRG10_1X10、3840×2160 |
| ISP pad2 → mainpath pad0 | ISP source 报 YUYV8_2X8、3840×2160。应用采集格式为 NV12 |
| params pad0 → ISP pad1 | 参数输入 |
| ISP pad3 → statistics pad0 | 统计输出 |

## 图上的节点和边各是什么？

| 对象 | 要记录的信息 |
| --- | --- |
| media_device | 同一拓扑的范围。/dev/mediaN 可以重编号 |
| entity | 一个可辨认的部件，例如接口、sensor、ISP 或 DMA 输出 |
| pad | entity 的输入或输出端，记录编号、方向及格式 |
| link | 连接两个 entity 的 pad；启用标志决定是否选择这条边参与当下管线 |
| route | 驱动支持路由时，描述 entity 内部的流从哪个输入转到哪个输出 |

~~~text
CIF source 0 → ISP sink 0                   （Bayer）
  params 0  → ISP sink 1                   （参数）
               ISP source 2 → mainpath 0   （图像）
               ISP source 3 → statistics 0 （统计）
~~~

历史快照还列了 selfpath、rawrd 和 PDAF 等节点。有些是输入，有些输出元数据。判断并发路数要看用途、启用路由、格式和硬件容量，不能按节点数量推算。不同 media_device 可能只公开管线的一部分。若在 ISP 图的最上游看到 CIF 实体，继续到对应 CIF 图查 sensor 到接收端的 pad，按实体名、父设备和活动端点关联。

## 尺寸变化在哪一层，怎么判断是不是配置错误？

原厂 sensor 日志请求 3864×2192，ISP 快照中的 CIF 输出和 ISP 输入已经是 3840×2160。两份观测来自不同位置，现有记录不能定位是哪一级裁切。要找具体变化，补查上游各个 entity 的输入与输出。组件内部可以有 crop、缩放与格式变换。crop 选取矩形区域，compose 用于定义缩放或合成的目标矩形。实际支持的 target 按对应节点与驱动查询。[Linux 6.1 选区目标](https://docs.kernel.org/6.1/userspace-api/media/v4l/v4l2-selection-targets.html)

连接两端的格式则要按同一条边、相同 stream 和 ACTIVE 状态来比。本地 V4L2 的默认验证器核对宽、高、总线码与适用的 field 条件。下面摘出宽度检查。

`drivers/media/v4l2-core/v4l2-subdev.c:863`

~~~c
if (source_fmt->format.width != sink_fmt->format.width) {
	dev_dbg(sd->entity.graph_obj.mdev->dev,
			"%s: width does not match (source %u, sink %u)\n",
			__func__,
			source_fmt->format.width, sink_fmt->format.width);
	pass = false;
}
~~~

保持相邻 pad 之间的接口相容，与允许同一个组件的输入输出有合法变换可以同时成立。具体驱动还可能实现自己的验证规则。图中 ISP source 的总线码与 capture G_FMT 回读的内存 FourCC 分别解释两层的数据。

## 换了固件如何重新定位？

选定一个在线目标以后，在 WSL 执行下面的只读查询。本轮仅复核历史快照，板端命令留给实际可用的目标。

~~~bash
adb shell 'v4l2-ctl --list-devices
for node in /dev/media*; do
    echo "$node"
    media-ctl -d "$node" -p
done'
~~~

先找实体名字和启用链接，再用对应节点的能力与 G_FMT 确认用途。没有看到目标实体时，先核对是不是选错 media_device，之后才追创建或异步匹配。实体已在但没图时，记录其源和 sink 端 pad、stream、格式及选区，再查实际开流与帧完成。

## 本节复盘

1. 3864×2192 与 3840×2160 分别在哪看到？还缺什么才能确定具体裁切位置？
2. ISP source 为 YUYV 而应用得到 NV12，分别用什么接口观察？
3. 为什么 params、statistics 和 mainpath 可以同在媒体图里，职责却各不相同？

下一节看这些实体如何在不同探测顺序下接进图。[5.9 V4L2 subdev 与异步绑定](subdev-async.md)
