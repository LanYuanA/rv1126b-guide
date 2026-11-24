# 3.8 物理页、伙伴系统与 CMA

<script setup>
import exampleFile from '../examples/buddy-layout.sh?url'
</script>

上一节的匿名首写通常只需一页。摄像头申请帧缓冲时，有些路径还要满足物理连续、对齐或设备地址范围约束。先问一个可以纸上算清的问题。16 页中有 8 页空闲，申请 8 页会成功吗？

## 固定空闲总量，只改变布局

从仓库根目录在 WSL 执行，或对三行分别手算。<a :href="exampleFile" download="buddy-layout.sh">下载对齐块演算脚本</a>。

~~~bash
bash learning-site/examples/buddy-layout.sh
~~~

点号为空闲，井号为占用，区域起始 PFN 按 16 页对齐。order 为 k 的块有 2ᵏ 页，其起点必须按 2ᵏ 页对齐。脚本从大到小检查是否存在全空闲的对齐区间。

| 布局 | 空闲页 | 最大块 | 如何算出来 |
| --- | --- | --- | --- |
| `........########` | 8 | order 3 | 页 0 到 7，起点 0 按 8 页对齐 |
| `.#.#.#.#.#.#.#.#` | 8 | order 0 | 每对中的另一页都被占用 |
| `####........####` | 8 | order 2 | 空闲段 4 到 11 跨过 8 页边界，但包含 4 到 7、8 到 11 两个对齐块 |

本轮三个输出依次为 3、0、2。这个模型用于推理空闲布局。真实分配还要核对 zone、水位、迁移类型、当前上下文及并发变化。第三行虽然无法直接交付 order 3 块，按页范围取连续页的算法在满足自身约束时仍可能使用 4 到 11。

## 页号、分区和空闲块的关系

PFN 是物理页框号，按基础页大小将物理地址分段。`struct page` 保存页的状态。NUMA node 组织本地内存。zone 是 node 中有特定用途或地址范围的内存区域，不能用另一个 zone 的空闲页直接推断本次请求能成功。每个 zone 的 free_area 按 order 存放块，块再按迁移类型分链。部分小阶请求还能先用每 CPU 页缓存，避免总是争用 zone 锁。

~~~text
申请参数（order、GFP、分配约束）
  → 选择可用 zone，检查水位等条件
  → 小阶可从每 CPU 页缓存获得，必要时补充
  → 从允许的空闲链寻找足够大的块 → 分裂后返回
  → 可尝试的慢路径取决于 GFP 与配置 → 重试或失败
~~~

`mm/page_alloc.c:2612` 的 `__rmqueue_smallest` 展示在给定的 zone 和迁移类型中怎样从请求阶数向上找。

~~~c
for (current_order = order; current_order < MAX_ORDER; ++current_order) {
	area = &(zone->free_area[current_order]);
	page = get_page_from_free_area(area, migratetype);
	if (!page)
		continue;
	del_page_from_free_list(page, zone, current_order);
	expand(zone, page, order, current_order, migratetype);
~~~

最低可用阶的块先从原链摘下来。若拿到 order 3 而只要 order 1，`expand` 先拆为两个 order 2，再把保留的半块拆到 order 1。起点为 PFN 0 时，剩余块为 4～7（order 2）与 2～3（order 1），交付 0～1。释放时若对应伙伴仍是可合并的空闲块，就合成下一阶再继续查。

`mm/internal.h:342`

~~~c
return page_pfn ^ (1 << order);
~~~

这一位取反得到同阶伙伴。对 2～3 的 order 1 块，2 异或 2 得到 0，伙伴为 0～1。两个地址相邻的块可能跨对齐边界，例如 2～3 和 4～5。源码还会检查伙伴状态、阶数、zone，并在适用时检查迁移类型，满足条件后才从空闲链表摘除并加阶。

<Sdk id="buddy-smallest" />

## 读宿主快照，再判断能排除什么

~~~bash
getconf PAGE_SIZE
cat /proc/buddyinfo
rg '^MemAvailable:' /proc/meminfo
rg '^(CmaTotal|CmaFree):' /proc/meminfo || test "$?" -eq 1
rg '^(CONFIG_(ARM64_4K_PAGES|ARCH_FORCE_MAX_ORDER|CMA)=|# CONFIG_COMPACTION is not set)' \
  atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal/.config
~~~

前四条读宿主。buddyinfo 每行是一个 node 的一个 zone，张数从 order 0 开始。第 k 列（从零计）的 n 是块数，该列代表 n × 2ᵏ × 页大小字节。例如 4096 字节页下，order 3 若有 3 块，就是 96 KiB，最大单块只有 32 KiB。CmaFree 等 meminfo 数值的 kB 按 1024 字节计。本轮宿主有 DMA32 和 Normal，未显示 CmaFree。末条读取本地板端候选配置，显示 4 KiB 页、MAX_ORDER 为 11、CMA 已启用、CONFIG_COMPACTION 关闭。11 是该源码循环上界，最大伙伴阶数为 10。目标实际配置仍需与启动镜像核对。

内存不足时，回收尽量让某些页变为空闲，例如回收符合条件的页缓存。迁移把仍需保留的数据移到其他页。规整用迁移集中空闲区，从而尝试满足高阶请求，能否使用其慢路径取决于配置与请求。长期固定页还可能堵住某段连续区。单次快照只能描述采样时刻的块分布。定位时把请求发出、分配失败和同窗口内存计数对齐，再看是否局限于某个 zone 或较高阶。

## CMA 怎样得到一段连续物理页？

CMA 在指定区域按页数 count 和页阶对齐 align 选择候选区间。区域中的一部分可能暂供可迁移用途。位图先登记 CMA 调用自身对区间的占用。普通分支再尝试准备指定 PFN 区间，包含隔离和必要的迁移。独立的规整配置开关也不能直接用于判定是否具有 CMA 的区间分配能力。

源码先将位图下标换算成起始 PFN，随后在普通分支交给 `alloc_contig_range`。

`mm/cma.c:493`

~~~c
mutex_lock(&cma_mutex);
ret = alloc_contig_range(pfn, pfn + count, MIGRATE_CMA,
			     GFP_KERNEL | (no_warn ? __GFP_NOWARN : 0));
mutex_unlock(&cma_mutex);
~~~

成功后从起点取得页对象。失败会清除本次位图占用，普通流程遇到 EBUSY 时可换候选位置。若区域内有无法搬走的页，单看空闲汇总不足以找到匹配区间。这里的 count 可以是非二的幂。CMA 可完成的请求和普通伙伴分配能交付的最大 order 是两类约束。

<Sdk id="cma-allocate" />

## 一张 4K 帧怎样从推算走到实际诊断？

3840×2160 的紧排 NV12 像素数据为 12,441,600 字节。按 4 KiB 页向上取整需要 3038 页。假如要求它来自一个伙伴块，需向上凑到 order 12。这个阶数超过本地候选配置上界。真实请求应先读协商得到的每个 plane 的 stride、sizeimage、对齐和 VB2 返回的缓冲数量，判断是单一连续区，还是离散页集合与设备映射。

本地 SDK 的 ISP 设置了 VB2 CMA-SG 操作表。操作表只是入口，还要看分配时的属性。

`drivers/media/common/videobuf2/videobuf2-cma-sg.c:205`

~~~c
if (dma_attrs & DMA_ATTR_FORCE_CONTIGUOUS)
	ret = vb2_cma_sg_alloc_contiguous(buf);
else
	ret = vb2_cma_sg_alloc_compacted(buf, vb->vb2_queue->gfp_flags);
if (ret)
	goto fail_pages_alloc;
~~~

前者请求连续物理页，另一分支根据约束准备页集合。两支成功后还要建 SG 表，并调用 dma_map_sgtable 建立设备可访问的映射。即使获得了页，DMA mask、段长或连续设备地址要求也可能让映射失败。先记录 REQBUFS 的原始返回值，再结合实参和同一窗口日志区分页申请、SG 表与 DMA 映射。若观察到 DMA 映射阶段失败，就能把调查从“根本没申请到页”缩到设备映射契约。本轮核对源码与宿主快照，板端路径还需实测。

<Sdk id="isp-buffer-allocator" />

## 本节复盘

1. 区分“连续 8 页”和“能直接交付一个 order 3 块”。用第三行的起点与对齐验算。
2. 释放 order 1、PFN 6 的块时，直接伙伴是谁？算出 6 异或 2 为 4，并列出合并的状态条件。
3. 有 IOMMU，驱动就可以使用任意离散页吗？沿实际的 VB2 分配属性、DMA mask、映射后段需求核对。
4. MemAvailable 很高但 REQBUFS 失败。列出大小、失败阶段和同窗口计数，说明每项能排除哪一种假设。

下一节看内核如何从页上切出对象槽，并区分 kfree 后的对象和页。[3.9 SLUB、kmalloc 与内存分配上下文](slub.md)
