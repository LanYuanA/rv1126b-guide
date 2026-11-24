# 5.3 拆开一个完整 sensor 驱动

<script setup>
import exampleFile from '../examples/sensor-instance-demo.c?url'
</script>

两颗 IMX415 可以共用同一份回调表。框架调用其中一个 subdev 时，为什么只改变对应器件的状态？从这个问题入手，比按文件顺序阅读所有寄存器表更容易找到驱动的骨架。

## 先验证“同一份函数，不同实例”

从 WSL 仓库根目录运行。模型使用两个实例、一个共享操作表，调用以对应的 subdev 为参数。<a :href="exampleFile" download="sensor-instance-demo.c">下载完整实例实验</a>。

~~~bash
mkdir -p output
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/sensor-instance-demo.c \
  -o output/sensor-instance-demo
./output/sensor-instance-demo
~~~

本轮第一颗的 streaming 变为 1，第二颗仍是 0。模型用断言核对从 subdev 返回的外层对象地址，并验证两颗对象状态互不覆盖。它只模拟对象和回调关系，未触发真实流。

## 按调用者读文件

~~~text
静态区域：常量、regval、模式表、I2C driver、subdev callbacks
              ↓ probe(client)
单颗实例：struct imx415
           ├─ client 与时钟、GPIO、regulator 句柄
           ├─ 嵌入的 subdev、源 pad 与 ctrl_handler
           └─ cur_mode、streaming、power_on 与 mutex
框架调用 subdev 的回调 → 还原所在的 imx415 实例 → 修改该实例
~~~

| 区域 | 常见调用者 | 按什么定位 |
| --- | --- | --- |
| 寄存器常量、regval 和模式表 | 选择模式、写表、处理曝光的 sensor 代码 | 确认生效条件、长度、频率、引用的表 |
| 实例与匹配表 | I2C 核心对特定 client 作绑定时 | probe/remove 与 of_match_table |
| subdev 操作表 | 媒体框架协商格式、开停流或查控制时 | core、video、pad 各类入口 |
| control handler | 枚举、读取或设置标准控制 | 支持的 ID、默认值和与当前 mode 的关联 |
| media entity 和 pad | 接收端或媒体控制框架寻找节点及其连接时 | 源 pad、异步注册、接收端匹配 |

以下命令只读 SDK，适合先遮住函数实现，圈出每一区的第一个入口。

~~~bash
f=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/drivers/media/i2c/imx415.c
rg -n '^struct imx415(_mode)? \{|^#define to_imx415|^static const struct v4l2_subdev_.*ops|^static struct i2c_driver|imx415_(probe|remove)\(' "$f"
rg -n 'v4l2_i2c_subdev_init|MEDIA_PAD_FL_SOURCE|v4l2_async_register_subdev_sensor|V4L2_CID_EXPOSURE' "$f"
~~~

## 两个框架怎样都能找到同一颗器件？

probe 先为当前 client 分配一个清零实例。模式表可以共用，当前模式指针和设备资源放在各自实例中。probe 初始化 mutex 和 subdev 后，V4L2 的 I2C helper 建立双向关联。

`drivers/media/v4l2-core/v4l2-i2c.c:54`

~~~c
v4l2_set_subdevdata(sd, client);
i2c_set_clientdata(client, sd);
~~~

从 client 进入时，remove 可用 i2c_get_clientdata 取回 subdev。从 subdev 进回调时，通过容器地址取得原实例。

`drivers/media/i2c/imx415.c:268`

~~~c
#define to_imx415(sd) container_of(sd, struct imx415, subdev)
~~~

container_of 按 subdev 在外层结构的成员偏移求起点。它要求传入的确实是该实例的内嵌成员。学习模型用 offsetof 表达同一关系。不要把一个单独分配、类型相似的对象当成有效成员传入。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:209–214`

~~~c
struct imx415 {
	struct i2c_client	*client;
	struct clk		*xvclk;
	struct gpio_desc	*reset_gpio;
	struct gpio_desc	*power_gpio;
	struct regulator_bulk_data supplies[IMX415_NUM_SUPPLIES];
~~~

## 操作表从哪里接到实际功能？

`drivers/media/i2c/imx415.c:2877`

~~~c
static const struct v4l2_subdev_ops imx415_subdev_ops = {
	.core	= &imx415_core_ops,
	.video	= &imx415_video_ops,
	.pad	= &imx415_pad_ops,
};
~~~

core 包含 s_power 和私有 ioctl，video 包含 s_stream 与帧间隔查询，pad 包含格式枚举及 get/set_fmt。它们都操作 sensor 控制状态。捕获图像的 DMA 缓冲由接收端和 ISP 的队列组织。普通图像设备节点的 open 也不会重复运行 sensor 的整个 probe。

control handler 另外注册曝光和增益等控制值。支持媒体控制器时，probe 设置一个源 pad、标明实体是相机 sensor，再把 subdev 交给异步注册，等待上游与接收端配对。

`drivers/media/i2c/imx415.c:3295`

~~~c
imx415->pad.flags = MEDIA_PAD_FL_SOURCE;
sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;
ret = media_entity_pads_init(&sd->entity, 1, &imx415->pad);
if (ret < 0)
	goto err_power_off;
~~~

| 假设省略一步 | 最先受影响的行为 |
| --- | --- |
| 漏注册曝光 control | 上层无法按这个调节入口枚举和设置曝光，模式表中的默认曝光仍可能存在 |
| 漏掉异步注册 | 接收端的 notifier 无法通过这步发现并绑定该 subdev，即使 client 已创建也会缺媒体连接 |
| 改成私有字符设备承接控制 | 需要另行提供格式、控制协议和媒体发现的桥接，现有应用无法直接沿标准接口匹配 |

## probe 失败和 remove 从哪里开始清理？

在本版源码画一条成功前缀：初始化锁、控制、上电、读 ID、初始化实体、异步注册、启用运行 PM。失败回退依据已经完成到哪一项。ID 失败进入 err_power_off，异步注册失败进入 err_clean_entity，再继续已有资源的逆序收尾。devm 的自动回收与显式注销分别核对，设备所持的引用仍需正确关断。

`drivers/media/i2c/imx415.c:3347`

~~~c
struct v4l2_subdev *sd = i2c_get_clientdata(client);
struct imx415 *imx415 = to_imx415(sd);

v4l2_async_unregister_subdev(sd);
~~~

remove 从正常绑定实例取回对象，先撤销已经发布的 subdev。其后清理媒体实体、控制与 PM 状态，必要时关电源。实际失败标签和 remove 均已静态核对，本轮不在板上解绑。

## 本节复盘

1. 从 client 和 subdev 各走一遍，怎样取得同一实例？回调表能否反推出当前实例是谁？
2. controls、pad 和 video 回调分别使哪类操作可用？省掉一个会先缺哪条用户态或管线能力？
3. ID 检查失败与异步注册失败各从哪个标签清理？为什么 remove 的起点又不同？
4. 从空白驱动起步，怎样用标准框架组织实例、接口与清理？私有字符设备要额外承担什么？

下一节深入 mode 与 control，验证哪些配置会实际写进芯片。[5.4 寄存器表、模式、曝光与增益](sensor-mode.md)
