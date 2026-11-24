# 3.15 DMA-BUF 导出、导入与同步

<script setup>
import exampleFile from '../examples/shared-frame-pool.awk?url'
</script>

预览读完一帧，编码分支还在用同一块内存。谁能宣布这个捕获槽可以重新 QBUF？先用槽位演算预测结果，再从导出端追到导入设备和异步完成。

## 先算三槽和四槽

在 WSL 仓库根目录执行。输入是合成的，固定帧间隔 33 ms、预览持有 5 ms、编码持有 110 ms。共 8 帧，槽满时丢新帧。<a :href="exampleFile" download="shared-frame-pool.awk">下载共享槽位模型</a>。

~~~bash
awk -f learning-site/examples/shared-frame-pool.awk
~~~

| 槽数 | 本轮现象 | 原因 |
| --- | --- | --- |
| 3 | 99 ms 首次丢弃，共丢 2 帧 | 0、33、66 ms 到达的三帧都仍被编码持有。第一槽最早在 110 ms 可归还 |
| 4 | 8 帧均接纳 | 99 ms 到达的帧用第四槽，132 ms 到达的帧可复用第一槽 |

单槽可用时刻是所有访问者的最晚完成时刻。真实系统还需留出任务调度、到达抖动和编码内部队列的空间。预览若借助缩放另建输出池，应分别检查它持有原始槽多久、输出槽多久，两个池分别预算。这个模型未验证目标设备的实际并发与池容量。

## 导出端把什么交给应用？

一个 DMA-BUF 对象维护共享存储和 exporter 提供的操作表。fd 是用户空间访问该对象的凭据。一次导出不把整帧字节搬进 fd。应用可以用 V4L2 的 VIDIOC_EXPBUF 导出 MMAP 队列的 plane，内核检查队列类型、flags、槽位和 plane 后，经对应内存操作表创建或取得对象。

`drivers/media/common/videobuf2/videobuf2-core.c:2285`

~~~c
dbuf = call_ptr_memop(get_dmabuf,
			      vb,
			      vb_plane->mem_priv,
			      flags & O_ACCMODE);
~~~

这里的 mem_priv 是具体 allocator 的 plane 私有状态。返回对象失败时，当前分支报告 EINVAL。对象取得以后才申请新 fd。若该阶段失败，会归还刚取得的对象引用。

`drivers/media/common/videobuf2/videobuf2-core.c:2295`

~~~c
ret = dma_buf_fd(dbuf, flags & ~O_ACCMODE);
if (ret < 0) {
	dprintk(q, 3, "buffer %d, plane %d failed to export (%d)\n",
		  index, plane, ret);
	dma_buf_put(dbuf);
	return ret;
}
~~~

fd 安装将该对象关联的 file 放入进程 fd 表。通过进程间传递取得的 fd 数字可不同。同一个整数也会被关闭后重新使用，排错应记录对象标识和代次。

<Sdk id="vb2-export-plane" />

## 导入端为什么要重新建立设备映射？

~~~text
导出端的 plane → dma_buf → 应用 fd → 导入端取得对象引用
  → attach（登记消费设备）→ map_attachment（针对设备返回 DMA 段）
  → 设备访问 → 完成并满足同步协议 → unmap 或按接口回收映射
  → detach → put；最后对象引用结束才释放共享对象
~~~

导入设备先从 fd 取得引用。attachment 表示同一 dma_buf 与这个设备的关系。实际 map_attachment 才取得导入设备可用的 SG 表。以下是本地 VB2 CMA-SG 的方向切换后建映射分支。

`drivers/media/common/videobuf2/videobuf2-cma-sg.c:523`

~~~c
if (dma_map_sgtable(db_attach->dev, sgt, dma_dir, 0)) {
	pr_err("failed to map scatterlist\n");
	mutex_unlock(lock);
	return ERR_PTR(-EIO);
}
~~~

第一个参数是导入设备，不同硬件的 mask、域和段约束可以不同。该实现可缓存符合条件的已有映射。消费方应遵循自己的 map、unmap、detach 与 put 协议，设备还在访问时不能撤销。用户关掉原 fd，导入者的独立引用可能仍存在。

<Sdk id="dmabuf-device-attach" />

建立 attachment 后，映射返回可用于该设备的段。失败要结合导入设备查 DMA 约束。

<Sdk id="dmabuf-device-map" />

## 三种状态分别用什么证明？

| 问题 | 依据 | 该证据覆盖的范围 |
| --- | --- | --- |
| 对象能否继续引用 | 活跃引用、fd、attachment 及映射寿命 | 支持对象存在和地址仍受管理 |
| 消费设备是否读完 | fence、设备完成事件、框架完成回调 | 表达任务的顺序及是否已结束 |
| CPU 能否看到设备写入 | 先满足访问顺序，再按 mmap 接口和方向进行所需缓存交接 | CPU 映射中的数据一致性 |

dma_fence 表示一个异步工作何时完成。支持隐式同步的组件可通过 dma_resv 交换相关 fence，显式接口可传递同步对象。若组件使用完成回调，分派者就等待所有用到原帧的回调。设计时核对当前 API 是否提供这些语义以及谁负责等待。CPU 经 DMA-BUF mmap 访问时，用 DMA_BUF_IOCTL_SYNC 的 START 和 END 包住访问并标注方向。有其他任务同时访问时仍需执行顺序保证。

<Sdk id="dmabuf-sync-uapi" />

## 怎样证明预览和编码共享了输入？

记录同一帧 sequence、plane、捕获索引、导出对象标识、导入设备、各分支完成及最后 QBUF。若调试接口只能看到同一个 fd 数字，仍需其他证据确认对象。若已经证实 ISP 输出与编码输入共享，再分别调查缩放输出和编码内部表面，防止将局部复用当成整链路零复制。多进程的 RSS 可能各自计入同一物理页，实际预算还包括未 mmap 的设备私有池。紧排 4K NV12 每帧约 11.87 MiB，三个槽约 35.6 MiB，目标预算按协商的 plane 分配长度和每个独立池计算。

## 本节复盘

1. 关闭应用 fd、编码完成和 QBUF 谁能证明哪些状态？按引用与访问两条线解释。
2. 为什么 importer 要调用自己的 map_attachment？沿 DMA 地址及域来回答。
3. 同样的 110 ms 持有时间，三槽与四槽的差异从哪一帧开始？说明为何模型无法直接给真实池定容。
4. 应用 RSS 相加为何可能高估共享池？要给零复制结论还要核对什么？

卷三串起来看，慢出队要用同一帧序号和同域时钟分开记录中断完成、VB2 发布、线程切入、分支持有和写盘积压。下一卷从设备和驱动如何相遇开始。[4.1 device、driver、bus 与 sysfs](../04-设备模型与驱动子系统/device-bus.md)
