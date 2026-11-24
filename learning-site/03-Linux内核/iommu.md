# 3.14 IOMMU、IOVA 与 scatter-gather

<script setup>
import exampleFile from '../examples/iova_demo.c?url'
</script>

两张物理页不连续，设备仍可能收到连续地址。先算一个跨页事务，再看 Linux 怎样为指定设备和域建立映射。

## 预测跨页写入的第一处故障

从仓库根目录运行。程序仅查一张进程内表，模拟地址和访问检查。<a :href="exampleFile" download="iova_demo.c">下载地址演算程序</a>。

~~~bash
mkdir -p output
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/iova_demo.c -o output/iova-demo
./output/iova-demo
~~~

设页长 4096，设备地址页 0x10000 映射到物理 0xa000，0x11000 映射到物理 0x37000。每次在 0x10ff0 开始写。第一段再写 16 字节就换页，物理地址从 0xaff0 走到 0xafff。第二段从 0x37000 开始。

| 改变哪个条件 | 预测与本轮结果 |
| --- | --- |
| 长度为 0x1010 | 最后地址 0x11fff，整段可写 |
| 多请求 1 字节 | 首个无映射字节在 0x12000 |
| 长度恢复，第二页只读 | 0x11000 首次不满足写权限 |

请求起点可以落在页内。创建映射时，页起点和范围仍要符合 IOMMU 的页粒度。物理页是否连续与 IOVA 是否连续由映射关系决定。

## 域、设备和页表各管什么？

~~~text
CPU 虚拟地址 → 进程的 CPU 页表 ──┐
                                  ├→ 物理页
设备事务的 IOVA → 关联域的翻译 ───┘
映射由 Linux 建立 → 设备开始访问 → 设备报告完成 → 撤销映射
~~~

设备接入 IOMMU 后，所关联的 domain 决定使用的翻译和权限。两个域可以把同一个 IOVA 数值映射到不同位置。设备地址还能受到 DMA mask、保留范围、对齐、最大段长度等约束。IOMMU 可缓存翻译，撤销需要后端按接口处理失效与何时能复用地址。驱动负责让访问结束后再解除映射。

`drivers/iommu/iommu.c:2313`

~~~c
if (!IS_ALIGNED(iova | paddr | size, min_pagesz)) {
	pr_err("unaligned: iova 0x%lx pa %pa size 0x%zx min_pagesz 0x%x\n",
		       iova, &paddr, size, min_pagesz);
	return -EINVAL;
}
~~~

代码先从域支持的页大小取最小值，检查三个参数在低位是否都对齐，再按可用粒度继续映射。中途失败时，要回滚已成功的部分，避免保留半份映射。

源码摘录 `kernel-6.1/drivers/iommu/iommu.c:2361–2366`

~~~c
int iommu_map(struct iommu_domain *domain, unsigned long iova,
	      phys_addr_t paddr, size_t size, int prot)
{
	might_sleep();
	return _iommu_map(domain, iova, paddr, size, prot, GFP_KERNEL);
}
~~~

## SG 表如何从物理视图变成设备视图？

散列表由若干连续片段描述内存，片段可以来自不相邻的页。SG 原始段数已经可能因构表时合并而少于页数。DMA API 再根据设备限制生成映射后的段数。如果只有单地址寄存器，设备还要求所需范围能作为相应连续区间访问。不要先按原始页数写寄存器。

`kernel/dma/mapping.c:271`

~~~c
nents = __dma_map_sg_attrs(dev, sgt->sgl, sgt->orig_nents, dir, attrs);
if (nents < 0)
	return nents;
sgt->nents = nents;
return 0;
~~~

驱动编程硬件用映射后的段与 `sg_dma_address`、`sg_dma_len`。清理时用相匹配的 DMA API 和原表参数，sg_table 的封装会按它的约定传递原始段数。以 IOMMU DMA 后端为例，普通分支先在域内按设备约束取得 IOVA 范围，再去映射 SG；未取得范围会走失败回收。

`drivers/iommu/dma-iommu.c:1290`

~~~c
ret = iommu_map_sg_atomic(domain, iova, sg, nents, prot);
if (ret < 0 || ret < iova_len)
	goto out_free_iova;

return __finalise_sg(dev, sg, nents, iova);
~~~

最终函数按硬件允许的段边界组织对设备公布的结果。即使底层 IOVA 能连起来，也要核对映射后是否真的满足消费方段数、地址边界和最大长度。

## RV1126B 从设备树接到哪里？

以下命令仅读取本地 SDK，确认 ISP 与 CIF 分别引用的 MMU 及板级启用状态。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
tree="$k/arch/arm64/boot/dts/rockchip"
rg -n 'iommus = <&(rkisp|rkcif)_mmu>|(rkisp|rkcif)_mmu: iommu' "$tree/rv1126b.dtsi"
rg -n -A2 '^&(rkisp|rkcif)_mmu ' "$tree/rv1126b-alientek.dtsi"
~~~

本地 SoC 文件各有一个引用，板级文件把两个提供者都标为 okay。源码只能说明这两条候选连接。验证实际一帧要再核对启动所用 DTB、设备绑定、当前域、分配及 DMA API 返回值。尤其是导入到另一个硬件时，原设备的地址不能作为导入设备的映射证据。

源码摘录 `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b.dtsi:3253–3258`

~~~text
	iommus = <&rkisp_mmu>;
	status = "disabled";
};

rkisp_mmu: iommu@21d07f00 {
	compatible = "rockchip,iommu-v2";
~~~

## fault 时如何缩小假设？

| 假设 | 需要的证据 |
| --- | --- |
| stride、行数或长度算大 | 按同一 plane 计算最后可访问地址，将故障 IOVA 与映射起点、长度和末端比较 |
| 过早 unmap 或复用了旧地址 | 按设备、槽位和代次关联 map、提交、完成、unmap，核对故障落在哪个生命周期 |
| 域、权限或设备地址不符 | 对照故障源和读写方向，以实际传给该设备的映射结果作证 |
| 分配阶段已失败 | 回到 DMA API 返回值、SG 约束与目标 mask，确认硬件是否接收过地址 |

Rockchip 驱动的错误日志可给出 IOVA 和读写方向。映射覆盖且权限正确时，再排查设备配置和时序。演算里的 0x12000 和 0x11000 只是两类失败示意，当前未在板端诱发 IOMMU fault。

## 本节复盘

1. 连续 IOVA 如何覆盖两张离散物理页？用地址页基址和页内偏移复算。
2. 两个域中同一数值的 IOVA 能否比较出它们共享内存？还缺哪些对象和设备证据？
3. orig_nents 与 nents 各用于什么？设备寄存器应该依据哪个结果和哪些限制？
4. 设备树有 okay，怎样进一步确认当前缓冲走了这个 IOMMU？从启动 DTB 说到映射返回值。

下一节将一个缓冲导出给多个消费者。[3.15 DMA-BUF 导出、导入与同步](dmabuf.md)
