# 跟着一块 NV12 缓冲，从 ISP 到预览与编码

板上原厂采集记录里，一块 3840×2160 的紧排 NV12 图像占 12,441,600 字节。想让预览和编码共用它，需要先回答三个问题：ISP 用什么地址写？应用在哪个时刻可以读？哪一方确认所有消费者都用完了？下面从本版 SDK 的缓冲操作表出发，用离线实验检查地址边界和池容量。

<a id="ownership"></a>

CPU 与设备的地址及交接见[3.13 DMA 与缓冲所有权](dma-ownership.md)。

<a id="iova"></a>

设备域与映射见[3.14 IOMMU、IOVA 与 scatter-gather](iommu.md)。

<a id="dmabuf"></a>

共享对象、导入者和访问同步见[3.15 DMA-BUF 导出、导入与同步](dmabuf.md)。
