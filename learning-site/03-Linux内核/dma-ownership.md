# 3.13 DMA 与缓冲所有权

<script setup>
import exampleFile from '../examples/dma-ownership.awk?url'
</script>

应用已经 mmap 了一张 NV12 图像，什么时候能交给编码器读？如果应用刚提交编码就 QBUF，地址仍然有效，但 ISP 可能在编码器结束前覆盖这块存储。先把地址、数据可见性和访问许可分开。

## 用同一槽位复现覆盖窗口

从仓库根目录运行。这个单槽模型把读任务在 5 ms 提交、48 ms 完成，将 33 ms 设为复写可能发生的最早起点之一。若槽位仍未归还，复写下界随归还时间向后移。真实下一帧还受采集调度影响。<a :href="exampleFile" download="dma-ownership.awk">下载交接演算</a>。

~~~bash
awk -f learning-site/examples/dma-ownership.awk
~~~

提前归还时，下一轮最早从 33 ms 开始写，读写可重叠 15 ms。等完成才归还时，重叠为 0。两个场景用同一地址和时钟，只改变归还事件。输出是离线演算，未在设备上故意制造覆盖。

## 为什么 CPU 和设备各有一个地址？

| 地址 | 谁使用 | 从哪里来 |
| --- | --- | --- |
| 应用或内核虚拟地址 | CPU 的取数指令 | mmap 或内核分配。CPU 页表翻译到存储 |
| 物理地址 | 内存管理及硬件映射层 | 页框和偏移。应用无需从指针推算它 |
| DMA 地址（dma_addr_t） | ISP 或其他设备 | DMA API 针对这个设备及其约束建立映射，可经过 IOMMU、地址偏移或适用的中转机制 |

DMA mask 限制设备能表达和访问的地址位。驱动在初始化时设置并检查合适的 mask。申请或映射还要处理错误，并确保实际 DMA 段符合设备寄存器宽度和传输约束。从另一个设备得到的 DMA 地址需由相应接口重新建立映射和验证。CPU 指针强转为 dma_addr_t 无法建立这些条件。

~~~text
应用虚拟地址 ── CPU 页表 ───┐
                             ├→ 同一缓冲存储
设备 DMA 地址 ── 设备映射 ───┘
分配/映射 → 交设备使用 → 设备完成 → 交 CPU 或下游 → 完成后归还
全部访问结束 → 撤销映射 → 释放页与对象
~~~

## 顺着 VB2 的内存操作表找到映射

以下命令在仓库根目录读取本地 SDK，定位 ISP 选择的操作表，以及分配、缓存同步和撤销入口。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
f="$k/drivers/media/common/videobuf2/videobuf2-cma-sg.c"
rg -n 'hw_dev->mem_ops' "$k/drivers/media/platform/rockchip/isp/hw.c"
rg -n 'DMA_ATTR_FORCE_CONTIGUOUS|dma_map_sgtable|dma_sync_sgtable_for_(device|cpu)|dma_unmap_sgtable' "$f"
~~~

在这个操作表里，先按属性准备页并构建 SG 表。然后给当前缓冲归属设备创建 DMA 映射。

`drivers/media/common/videobuf2/videobuf2-cma-sg.c:222`

~~~c
if (dma_map_sgtable(buf->dev, sgt, buf->dma_dir,
				    DMA_ATTR_SKIP_CPU_SYNC))
	goto fail_map;
~~~

这里零表示建立成功。失败跳回收路径，不能把页集合当作已可用的设备地址。SKIP_CPU_SYNC 表示这一调用跳过通常的 CPU 缓存同步。本实现把交接安排给内存操作回调。方向以设备为参照，捕获向 RAM 写入，多数对应 DMA_FROM_DEVICE。输出队列交设备读，多数对应 DMA_TO_DEVICE。双向访问需要明确的双向配置。

`drivers/media/common/videobuf2/videobuf2-core.c:2457`

~~~c
if (q->bidirectional)
	q->dma_dir = DMA_BIDIRECTIONAL;
else
	q->dma_dir = q->is_output ? DMA_TO_DEVICE : DMA_FROM_DEVICE;
~~~

<Sdk id="camera-dma-alloc" />

## 地址已建立，为什么还要 prepare 和 finish？

流式 DMA 映射可跨多次提交存在。每次把内容交给设备或拿回给 CPU，调用侧仍需遵循同步规则。方向和原来映射一致。这个操作表的两处调用各有跳过条件。

`drivers/media/common/videobuf2/videobuf2-cma-sg.c:277`

~~~c
if (buf->vb->skip_cache_sync_on_prepare)
	return;

dma_sync_sgtable_for_device(buf->dev, sgt, buf->dma_dir);
~~~

prepare 发生在交设备访问以前。若平台需要缓存维护，DMA API 根据方向和设备做对应动作。finish 则在交回时执行 for_cpu。判断真实设备是否需要缓存操作，要看一致性、分配方式和跳过标志。

`drivers/media/common/videobuf2/videobuf2-cma-sg.c:288`

~~~c
if (buf->vb->skip_cache_sync_on_finish)
	return;

dma_sync_sgtable_for_cpu(buf->dev, sgt, buf->dma_dir);
~~~

普通完成路径在发布完成队列前调用 VB2 内存 finish。设备报告完成、做完所需缓存同步、进入完成队列是三个可观察阶段。设备还在写时，提前执行同步也无法交付完整帧。

`drivers/media/common/videobuf2/videobuf2-core.c:1085`

~~~c
if (state != VB2_BUF_STATE_QUEUED)
	__vb2_buf_mem_finish(vb);
~~~

对于 coherent 分配，DMA API 提供一致性规则，驱动仍需遵循描述符发布的顺序和必要的内存屏障。例如 CPU 先填描述符内容，再允许硬件开始读取。缓存可见性、访问顺序和任务完成分别有自己的条件。

## 应用把哪个事件接到 QBUF 上？

| 阶段 | 缓冲归属 | 应用检查 |
| --- | --- | --- |
| 初次 mmap | 应用获得地址 | 记录每个 plane 的索引、长度和 offset，尚未收到采集结果 |
| QBUF 成功 | 采集队列持有，可安排设备写 | 避免 CPU 或下游读写该槽 |
| 完成到 DQBUF | 驱动入完成队列，应用取回 | 检查实际 index、sequence、flags、bytesused |
| 应用提交下游 | 下游可能仍异步访问 | 确认读完事件或 fence，最后使用者完成后归还 |

要定位画面被覆盖，记录同一槽的代次、设备开始与完成、DQBUF、下游开始与完成、QBUF。若观察到下游读的窗口与新一轮设备写交叠，先修归还条件。若没有交叠，再根据所走接口查缓存同步和内容布局。本节已验证本地调用关系及离线模型，板端多方交接路径还需实测。

## 本节复盘

1. mmap 能读到 Y 值，为什么不能把指针交给 ISP？指出两套地址翻译和 DMA mask 检查。
2. 捕获方向为什么是 DMA_FROM_DEVICE？设备在本次操作中是读者还是写者？
3. 地址已映射且缓存一致，为什么还会画面撕裂？用 33～48 ms 的模型解释。
4. 怎么验证缩放或编码有没有再分配一份像素存储？分别记录输入对象身份、组件输出表面和完成标识。

下一节进入设备地址翻译和散列表。[3.14 IOMMU、IOVA 与 scatter-gather](iommu.md)
