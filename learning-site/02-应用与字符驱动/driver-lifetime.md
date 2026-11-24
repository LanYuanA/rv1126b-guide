# 2.10 多实例、错误回退与卸载

B 探测到一半失败，A 仍有用户在读。应回收哪份资源？先找失败的是哪个实例，再找设备是否已经发布以及哪些路径还持有引用。

## 划分四类对象寿命

| 层级 | 常见状态 | 释放条件 |
| --- | --- | --- |
| 驱动或模块 | 操作表、公共编号、总线登记 | 实例已撤销，代码不再有活跃引用 |
| 每个设备 | client、时钟、接收队列 | 停止硬件访问，在途工作和引用已按约定完成 |
| 每次打开 | file->private_data、便笺文本与游标 | 最后一份相关 file 引用释放 |
| 每次异步操作 | 在队缓冲、worker 状态 | 完成或取消并同步后，再归还或销毁 |

两台设备可共用一张操作表，每次执行则从传入对象找该实例的数据。便笺进一步演示，即使只有一台设备，两次独立打开仍可各自持有 note。

## 探测失败：只释放已经取得的资源

IMX415 的普通 probe 利用标签共享回退路径。以下几行从媒体实体清理一路走到释放电源、controls 和 mutex。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:3331–3340`

~~~c
err_clean_entity:
#if defined(CONFIG_MEDIA_CONTROLLER)
	media_entity_cleanup(&sd->entity);
#endif
err_power_off:
	__imx415_power_off(imx415);
err_free_handler:
	v4l2_ctrl_handler_free(&imx415->ctrl_handler);
err_destroy_mutex:
	mutex_destroy(&imx415->mutex);
~~~

读 ID 失败可直接跳到关电源。媒体实体已经初始化且注册失败时，才从实体清理入口开始。读每个 goto 时，先列出成功取得的资源，再标出尚未取得、无需清理的部分。

在隔离实验中可以设计失败注入：让 B 取得编号和实例状态后，在发布前返回一次 EIO。应看到 B 的私有状态和独有编号归还，A 的现有接口保持正常。撤掉注入后再登记 B，应只出现一个 B 实例。发布后注入还要测试可能存在的打开文件。这是回归设计，本轮没有修改 SDK 加入注入。

## 已公开的设备：撤入口、停活动与释放内存

~~~text
标记不可用，拒绝新请求 → 撤销发布入口并通知等待者
 → 按设备依赖停止硬件并同步 IRQ、定时器与工作
 → 归还会话和设备引用 → 最后一份引用离开后释放对象
~~~

准备撤映射时看 cdev_del。它阻止该映射上的新打开，已经打开的 file 仍可能执行回调。引用计数能让对象内存继续存活，还需要明确的不可用状态阻止旧回调访问已拔除的硬件。等待异步任务结束前，也要确认没有握着该任务必须取得的锁。

源码摘录 `kernel-6.1/fs/char_dev.c:590–595`

~~~c
 * NOTE: This guarantees that cdev device will no longer be able to be
 * opened, however any cdevs already open will remain and their fops will
 * still be callable even after cdev_del returns.
 */
void cdev_del(struct cdev *p)
{
~~~

便笺的最后一次释放见 `examples/char/rvnote.c:59`。

~~~c
static int note_release(struct inode *inode, struct file *file)
{
	kfree(file->private_data);
	return 0;
}
~~~

file 来自一次成功的 open，kfree 只清掉该会话。驱动表里的 THIS_MODULE 维护模块代码的寿命，其他设备和异步对象仍要各管引用。devm 帮助回收已取得的资源，但不能自动推断 DMA 什么时候停止、等待者如何获知失败。对每一个主动启动动作写出匹配的停止和同步条件。

下面命令只检查两个实现的释放点。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'err_(clean_entity|power_off|free_handler|destroy_mutex):|^static void imx415_remove' "$k/drivers/media/i2c/imx415.c"
rg -n 'kzalloc|private_data|kfree|THIS_MODULE' learning-site/examples/char/rvnote.c
~~~

## 本节复盘

1. 发布前的 B 初始化失败与发布后失败相比，谁可能已经拿到 B 的 file 或设备引用？
2. 若卸载时等待 worker，而当前线程恰好持有 worker 必须取得的锁，哪一段退出会卡住？
3. A、B 共用号段时，B 失败为什么只回收自己取得的资源？用一次重新登记来验证是否存在误释放。

下一卷从线程如何共享资源讲起，再追已唤醒的任务什么时候真正获得 CPU。[3.1 进程、线程与资源共享](../03-Linux内核/process.md#tasks)
