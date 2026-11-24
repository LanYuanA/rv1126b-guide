# 5.9 V4L2 subdev 与异步绑定

<script setup>
import exampleFile from '../examples/async-subdev.awk?url'
</script>

sensor 完成 I2C probe 的时候，接收端可能还没有注册。接收端先出现时也可能找不到 sensor。异步匹配允许两端先分别登记，再按固件节点信息连起来。

## 交换两边的注册顺序

在 WSL 仓库根目录运行。模型假设只有一个已经声明的远端依赖。它检查成功绑定、互换顺序以及错误的远端。<a :href="exampleFile" download="async-subdev.awk">下载异步注册演算</a>。

~~~bash
awk -f learning-site/examples/async-subdev.awk
~~~

两次正确输入都先出现 bound，随后 complete。错误远端那组，接收端等待 endpoint-B，发布者却对应 endpoint-A，所以模型仍在等待。实际内核可管理多级 notifier 和多个依赖，绑定回调也可能失败。若固件根本没有形成等待项，需查解析是否报错、跳过或提前完成，不能套用第三种模型。

## 成为 subdev 后，各组回调做什么？

I2C probe 通过 v4l2_i2c_subdev_init 建立 client 和 subdev 的双向关联，再由 sensor 驱动向 V4L2 异步框架登记。core ops 与设备控制相关，video ops 可处理开停流与帧间隔，pad ops 描述总线格式及选区。分组细节可回读[5.3 驱动结构](sensor-driver.md)。

~~~text
sensor 先发布 → 暂存未匹配对象 → notifier 注册并扫描
接收端先注册 → 等待已声明的远端 → sensor 登记并扫描
相遇 → 匹配 fwnode → bound → 检查整个依赖树 → complete
之后 → 媒体链接、格式和管线验证 → 开流 → 缓冲完成
~~~

## notifier 的匹配键怎样形成？

CIF 初始化 notifier，用固件端点解析函数描述其依赖，再注册到所属 v4l2_device。真正等待的对象是该实例的图上远端。中间有 CSI 或 D-PHY 子设备时，不能把每条 CIF 绑定都解释为直接绑定了 IMX415。

`drivers/media/v4l2-core/v4l2-async.c:94`

~~~c
if (sd_fwnode == asd->match.fwnode)
	return true;
~~~

简单路径比较固件节点指针。框架还处理“设备节点与端点节点”不在同一层的情况，会核对端点所属设备。这里匹配的是固件标识。实体显示名称、I2C 地址或 video 编号不能代替匹配键。

源码摘录 `kernel-6.1/drivers/media/platform/rockchip/cif/dev.c:2258–2263`

~~~c
static int cif_subdev_notifier(struct rkcif_device *cif_dev)
{
	struct v4l2_async_notifier *ntf = &cif_dev->notifier;
	struct device *dev = cif_dev->dev;
	int ret;

~~~

## bound 与 complete 分别改变什么？

`drivers/media/v4l2-core/v4l2-async.c:327`

~~~c
ret = v4l2_async_nf_call_bound(notifier, sd, asd);
if (ret < 0) {
	v4l2_device_unregister_subdev(sd);
	return ret;
}
~~~

bound 为命中的一项执行接收端动作。本版 CIF 会记录 subdev、lanes 和 mbus，并检查数组容量。成功分支用 v4l2_err 打印 Async registered subdev 但随后返回 0，应以该路径和返回值确定含义。

`drivers/media/v4l2-core/v4l2-async.c:284`

~~~c
/* Is everything ready? */
if (!v4l2_async_nf_can_complete(notifier))
	return 0;

return v4l2_async_nf_call_complete(notifier);
~~~

complete 要等根 notifier 的依赖树就绪。CIF 的完成回调可经 pad ops 查询 get_mbus_config，再按实现建立链接和注册节点。没有某次日志不一定是没有执行，还需核对日志级别和同次启动条件。

源码摘录 `kernel-6.1/drivers/media/platform/rockchip/cif/dev.c:2117–2122`

~~~c
static int subdev_notifier_complete(struct v4l2_async_notifier *notifier)
{
	struct rkcif_device *dev;
	struct rkcif_sensor_info *sensor;
	struct v4l2_subdev *sd;
	struct v4l2_device *v4l2_dev = NULL;
~~~

## 接上图以后，怎样继续到开流？

在 WSL 仓库根目录执行，只读本地源码。先找完成回调和总线查询，再查 CSI 组件如何发起其上游的 s_stream。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'subdev_notifier_(bound|complete)|parse_fwnode_endpoints|Async registered subdev|get_mbus_config' \
  "$k/drivers/media/platform/rockchip/cif/dev.c"
rg -n 'video, s_stream|v4l2_set_subdevdata|i2c_set_clientdata' \
  "$k/drivers/media/platform/rockchip/cif/mipi-csi2.c" "$k/drivers/media/v4l2-core/v4l2-i2c.c"
~~~

总线配置和活动图像格式要分别核对。pad 的 get_fmt、set_fmt 给配置路径查询和调整，格式是否跨块相容要在相连边确认。绑定阶段不执行开流。随后启动管线时，组件会向相应上游请求 s_stream，失败应查看返回和已启动资源的回退。即使 STREAMON 成功，仍需实际接收状态和 DQBUF 证明首帧。

| 本轮想核对什么 | 下一条可复查的证据 |
| --- | --- |
| 远端解析是否符合设计 | 活动树双向 phandle、节点可用状态和执行解析的具体接收端 |
| 是否匹配并登记 | 同次启动的回调、返回值、相应媒体图及 link |
| 图是否能用 | 两端 pad/stream 的 ACTIVE 格式、选区、开流返回与帧完成 |

## 本节复盘

1. sensor 先注册与接收端先注册，两种顺序下谁去扫描谁？
2. bound 成功后，哪些未就绪依赖仍可阻止 complete？
3. 如果缺少 remote-endpoint，你会怎样区分解析没有建立依赖和已登记但一直未匹配？
4. probe、complete、STREAMON 和 DQBUF 分别能支持什么结论？

本轮复跑离线注册时序并核对源码，板端未改变拓扑。下一节沿 ISP 的视频节点查应用打开的是哪个对象。[5.10 RKISP 与视频设备节点](rkisp-video-node.md)
