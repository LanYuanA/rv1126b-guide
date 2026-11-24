# 2.7 显式 cdev、设备类与设备节点

假设同一驱动管理 A、B 两只采样设备。要让拔掉 B 后 A 仍工作，需要分别管理编号、回调入口和设备对象的寿命。本节用本版 IIO 跟读这一拆分。

## 先把两只设备分别画出来

| 对象 | A 和 B 是否共享 | 谁用它 |
| --- | --- | --- |
| 已分配的设备号范围 | 一段公共号段 | 驱动或子系统统一申请和归还 |
| dev_t 与 cdev | 各实例有自己的编号和映射 | open 路径通过设备号找到该实例的操作表 |
| struct device | 各实例独立注册 | 设备模型提供父子关系、sysfs 属性和设备事件 |
| class 或 bus | 同类实例可以共享 | 用户从这里查看同类设备。节点是否出现还要看 devtmpfs 或设备管理程序 |
| file_operations | 行为相同时可共用表 | 文件打开后按表调具体函数，数据仍应通过实例或 file 上下文找到 |

典型顺序是先用 alloc_chrdev_region 分配号段，再为每个实例准备私有状态，最后通过 cdev_add 发布映射。对需要设备模型的实例，另外调用 device_add 或用封装接口一起发布。class 只是某些驱动采用的归类和发布方式，IIO 例子复用该子系统自己的 device/bus 组织。

## IIO 在什么时候决定回调表？

`drivers/iio/industrialio-core.c:1993`

~~~c
if (iio_dev_opaque->attached_buffers_cnt)
	cdev_init(&iio_dev_opaque->chrdev, &iio_buffer_fileops);
else if (iio_dev_opaque->event_interface)
	cdev_init(&iio_dev_opaque->chrdev, &iio_event_fileops);
~~~

先按实例是否有缓冲或事件选择表。cdev_init 只初始化对象和操作表。此时还没有把设备号映射发布给 open。

`drivers/iio/industrialio-core.c:1998`

~~~c
if (iio_dev_opaque->attached_buffers_cnt || iio_dev_opaque->event_interface) {
	indio_dev->dev.devt = MKDEV(MAJOR(iio_devt), iio_dev_opaque->id);
	iio_dev_opaque->chrdev.owner = this_mod;
}
~~~

在提供字符接口的分支里，主号取自 IIO 的公共号段，次号取该实例自己的 id。对象和回调都准备好以后才调用 cdev_device_add。

## helper 怎样发布，失败时发生什么？

`fs/char_dev.c:541`

~~~c
if (dev->devt) {
	cdev_set_parent(cdev, &dev->kobj);

	rc = cdev_add(cdev, dev->devt, 1);
	if (rc)
		return rc;
}
~~~

当 devt 非零，先为 cdev 关联 device 的 kobject，再发布一个设备号的映射。已有正确设备号的节点此时就可能打开，所以锁、状态和回调需要在这一步前准备好。

`fs/char_dev.c:549`

~~~c
rc = device_add(dev);
if (rc && dev->devt)
	cdev_del(cdev);

return rc;
~~~

之后再在设备模型里发布 device。若后一步失败，helper 撤掉刚才发布的 cdev。即使整个 helper 返回错误，已经开始的 open 或在途回调也需要按引用规则收尾。撤销入口和销毁对象要分开处理。

### 宿主跟读验证

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'alloc_chrdev_region|cdev_init\(|cdev_device_(add|del)|unregister_chrdev_region' "$k/drivers/iio/industrialio-core.c"
rg -n -A17 '^int cdev_device_add\(' "$k/fs/char_dev.c"
~~~

## 本节复盘

假设 A 全部发布成功，B 已登记 cdev 但 device_add 失败。先指出 B 的映射由谁撤销，再说明 B 的一个旧 file 还可能持有哪种引用。若产品允许 A 独立工作，共用的号段为何还不能立即归还？如果初始化必须全部成功，则要为 A 也走正常的撤销路径。最后解释手工创建设备节点为何不会初始化驱动。

下一节用一个只有单独接口的便笺驱动，观察 misc 核心替驱动承担了哪些发布工作。[2.8 miscdevice 与每次打开的私有状态](miscdevice.md)
