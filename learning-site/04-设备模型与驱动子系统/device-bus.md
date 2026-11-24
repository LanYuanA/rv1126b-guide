# 4.1 device、driver、bus 与 sysfs

<script setup>
import exampleFile from '../examples/sysfs-device.sh?url'
</script>

sysfs 出现了一条 I2C 设备目录，能据此证明板上焊好的芯片刚刚应答了吗？先从宿主的设备链接学习读取关系，再把同一套判读用在 RV1126B。

## 先读一个绑定设备与一个虚拟接口

在 WSL 仓库根目录执行。脚本展开设备路径，逐个读 subsystem、driver 和 of_node。它只读 sysfs。<a :href="exampleFile" download="sysfs-device.sh">下载设备关系查询脚本</a>。

~~~bash
for entry in /sys/bus/platform/devices/*; do
  if test -L "$entry/driver"; then
    sh learning-site/examples/sysfs-device.sh "$entry"
    break
  fi
done
sh learning-site/examples/sysfs-device.sh /sys/class/net/lo
~~~

本轮第一个有驱动的 platform 设备为 ACPI0003:00，subsystem 指向 platform，driver 指向 ac，未看到 of_node。lo 的实际路径在 /sys/devices/virtual/net，subsystem 指向 /sys/class/net，当前没有 driver 链接。第一条输出随系统变化。如果找不到已绑定的 platform 设备，可对 /sys/bus 下另一条总线的设备做相同观察。

## 内核为什么需要四类对象？

| 对象 | 职责 | 常见观察视图 |
| --- | --- | --- |
| device | 一个实例，关联父对象、总线、固件节点与当前驱动等 | /sys/devices，反映注册形成的层级 |
| device_driver | 记录可以处理哪些实例及其操作 | /sys/bus/总线/drivers，驱动注册后可看到 |
| bus_type | 组织实例和驱动，提供 match 及可选的 probe 等总线动作 | /sys/bus/总线，可查看两个集合 |
| class | 按用途呈现对象，例如网络接口、视频设备 | /sys/class，按功能检索 |

设备可能来自固件、硬件枚举或另一个驱动创建，功能类也可以组织没有物理总线的对象。父子层级通常反映对象的组织关系，总线字段决定匹配机制。设备类型、父设备、设备类和驱动分别记录。一个摄像头关联的 video4linux 节点还经过媒体设备及捕获路径，不能用视频编号反推 I2C 从地址。

~~~text
设备先出现 → device_add → 接入总线视图 → 尝试已有驱动
驱动先出现或稍后加载 → driver_register → 加入所属总线 → 尝试已有设备
两边相遇 → bus 的 match → 核对依赖与 probe → 成功完成绑定
~~~

## device 注册和 driver 注册在哪里相遇？

device_add 先调用 bus_add_device 建立总线视图。后者会向设备创建 subsystem 链接，并把对象加入总线设备列表。

`drivers/base/bus.c:457`

~~~c
error = sysfs_create_link(&dev->kobj,
				&dev->bus->p->subsys.kobj, "subsystem");
if (error)
	goto out_subsys;
klist_add_tail(&dev->p->knode_bus, &bus->p->klist_devices);
~~~

device_add 随后调用 bus_probe_device。若启用自动探测，走 device_initial_probe，扫描已有候选驱动。另一方向上，driver_register 到达 bus_add_driver，后者加入列表后查已有实例。

`drivers/base/bus.c:618`

~~~c
klist_add_tail(&priv->knode_bus, &bus->p->klist_drivers);
if (drv->bus->p->drivers_autoprobe) {
	error = driver_attach(drv);
	if (error)
		goto out_del_list;
}
~~~

注册顺序可以不同。两边都存在也只是具备尝试条件。核心层调用总线 match 的规则，成功匹配后才可能开始初始化。

`drivers/base/base.h:147`

~~~c
return drv->bus->match ? drv->bus->match(dev, drv) : 1;
~~~

例如 I2C 适配当前的固件匹配表及设备 ID，那些规则由 I2C 核心提供。匹配结果只说明驱动是候选。探测时核心可走总线包装函数，再由总线调用器件驱动的入口。

`drivers/base/dd.c:557`

~~~c
if (dev->bus->probe)
	ret = dev->bus->probe(dev);
else if (drv->probe)
	ret = drv->probe(dev);
~~~

稳定状态中的 driver 链接可用于理解绑定。探测过程中内核会先建立相应的 sysfs 链接，失败时再撤销。因此遇到启动中的瞬时状态，还应结合驱动日志与后续状态。较细的依赖和失败回退将在 4.5 继续跟读。

<Sdk id="device-add-instance" />

## I2C3、adapter 和 IMX415 怎么排成树？

~~~text
platform_device 21120000.i2c
  └─ rk3x 初始化控制器并注册 i2c_adapter（i2c-3）
      └─ I2C 核心枚举固件子节点 → i2c_client（3-001a）
          └─ I2C 总线匹配 imx415 后执行 probe
              └─ 正常上电与读 ID → 准备、注册 V4L2 子设备
~~~

控制器用 CPU MMIO 操作外设，adapter 抽象一条可传输消息的 I2C 总线，client 表示该总线指定地址的器件。rk3x 设置 adapter 的父设备为 platform 控制器。创建 client 时，I2C 核心再分别设置父对象和总线。

`drivers/i2c/i2c-core-base.c:1009`

~~~c
client->dev.parent = &client->adapter->dev;
client->dev.bus = &i2c_bus_type;
client->dev.type = &i2c_client_type;
client->dev.of_node = of_node_get(info->of_node);
~~~

parent 用于设备层级，bus 指定匹配机制，type 表示对象类别，of_node 保留固件来源。注册这些关系时可还未完成任何 sensor 的总线事务。

<Sdk id="i2c-adapter-setup" />

## 给本板设备做一张身份卡

以下命令在 WSL 根目录读历史原厂启动日志。若没有本地原始文件，可先对照下表和仓库已有记录。

~~~bash
rg -n 'imx415 [34]-001a:.*(Detected imx415 id|Unexpected sensor id)' output/camera-check/dmesg-before.log
~~~

| 层级 | 第一颗的现有证据 | 支持的结论 |
| --- | --- | --- |
| 固件来源 | 历史 of_node 指向 i2c@21120000/imx415_0@1a，compatible 为 sony,imx415，reg 字节为 00 00 00 1a | 该次运行对象对应这个活动节点 |
| 总线及当前驱动 | 历史对象为 3-001a，driver 指向 /sys/bus/i2c/drivers/imx415 | 历史取样时驱动已绑定。总线号来自那次固件 |
| 物理应答 | 历史日志记录 3-001a 的 Detected imx415 id 0000e0 | 该次正常路径接受读回值，后续出图仍需帧证据 |
| 另一实例 | 4-001a 打印 Unexpected sensor id 与 ret(-5) | 软件已进入驱动尝试，不能由零初值推断线上收到 0 |

连接目标板后，用下列只读命令复核 sysfs 设备、总线和驱动的对应关系。

~~~bash
adb shell 'd=/sys/bus/i2c/devices/3-001a
test -d "$d" || exit 1
for relation in subsystem driver of_node; do
  if test -L "$d/$relation"; then
    printf "%s -> " "$relation"
    readlink -f "$d/$relation"
  fi
done'
~~~

若设备对象存在而缺 driver，先查预期驱动是否已经在该总线注册，再看 active compatible 与匹配表。驱动已注册且有匹配候选时，查同一启动是否记录 probe 错误或依赖延迟。若已绑定而取不到帧，继续查媒体拓扑、开流和队列完成。每一步用不同证据缩小范围。

## 本节复盘

1. 系统先注册驱动，设备稍后创建，哪个方向触发匹配？换一下先后顺序再说一次。
2. subsystem、driver、of_node 分别证明什么？为什么 lo 的 subsystem 可以指向 class？
3. 3-001a 已经出现却没有 driver，怎样区分驱动尚未载入、匹配条件不符、probe 失败以及依赖延迟？
4. ID 读对了以后，为什么还需要帧序号和视频数据？

下一节拆开控制器的 platform 资源和 sensor 的 I2C 地址。[4.2 platform 总线、资源与 MMIO](platform-mmio.md)
