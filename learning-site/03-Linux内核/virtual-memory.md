# 3.7 虚拟内存、页表与缺页

<script setup>
import exampleFile from '../examples/vm_fault_demo.c?url'
</script>

申请 8 MiB 以后，进程哪一步才会因为写入而得到实际的数据页？下面固定映射长度和访问步长，观察建立映射、第一次写、重复写三段。

## 先测同一个进程的三个阶段

在仓库根目录的 WSL 终端运行。程序用 `sysconf(_SC_PAGESIZE)` 取宿主页大小，用 `getrusage(RUSAGE_SELF)` 取本进程的累计缺页数。<a :href="exampleFile" download="vm_fault_demo.c">下载完整 C 实验</a>。

~~~bash
mkdir -p output/textbook-check
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/vm_fault_demo.c \
  -o output/textbook-check/vm-fault
output/textbook-check/vm-fault
~~~

| 阶段 | 访问方式 | 本轮 WSL minor / major 增量 |
| --- | --- | --- |
| 映射 | 仅建立 8,388,608 字节匿名私有映射 | 0 / 0 |
| 第一次写 | 每隔 4096 字节写一次 | 2048 / 0 |
| 第二次写 | 改写同一组地址 | 0 / 0 |

实验用 volatile 指针保留两轮实际写入，计数采样之间没有打印。4096 字节基础页下，8 MiB 有 2048 页，首写的结果与逐页建映射相符。复现时比较三段差异即可。预触页、透明大页、回收以及进程自身其他触页都能改变实际数值。这里的计数包含本进程的额外活动，实验没有读取 PFN 或测量精确的 RSS。

## 地址范围、页表和 TLB 分工

| 对象 | 持有什么 | 在一次访问中何时用到 |
| --- | --- | --- |
| mm_struct 和 VMA | 进程地址空间和各范围的权限、映射类型、文件偏移。该版本使用 mm_mt 管理 VMA | mmap 更新地址范围，缺页处理按地址查找 VMA |
| 页表 | 由地址位逐级索引，末级项关联物理页框及权限；大页可在上层终止遍历 | TLB 未命中后，CPU 可走现有页表重新获得翻译 |
| TLB | CPU 缓存的地址翻译及权限 | 正常访问可直接命中；内核撤销或收紧旧映射时需维护一致性 |

~~~text
mmap → 建立合法地址范围
CPU 写入 → TLB 或硬件页表遍历 → 翻译或权限产生同步异常
  → ARM64 按异常类型和地址核对 VMA → handle_mm_fault
  → 按页表项状态、VMA 类型和访问方式选择分支
  → 成功建立或更新翻译：返回后重试指令
  → 地址或权限非法：用户态通常收到 SIGSEGV
~~~

匿名 mmap 成功意味着地址范围已建立。RSS 描述当前驻留的页，它随触页和回收而变化。一次 TLB miss 通常由硬件页表遍历解决。只有翻译失败、权限等条件触发异常，才由内核接手。

<Sdk id="mm-mmap-range" />

## ARM64 怎么把访问信息交给通用内存管理？

`arch/arm64/mm/fault.c:550`

~~~c
} else if (is_write_abort(esr)) {
	/* It was write fault */
	vm_flags = VM_WRITE;
	mm_flags |= FAULT_FLAG_WRITE;
~~~

esr 带着 CPU 给出的异常原因。VM_WRITE 用于核对地址范围是否准许写。FAULT_FLAG_WRITE 则随请求传给内存管理层，决定是否需要准备可写映射。异常地址用于在当前进程的 mm 里查找范围。找不到范围时走 VM_FAULT_BADMAP。找到后继续检查许可。

`arch/arm64/mm/fault.c:497`

~~~c
if (!(vma->vm_flags & vm_flags))
	return VM_FAULT_BADACCESS;
return handle_mm_fault(vma, addr, mm_flags, regs);
~~~

这也解释了两种看似相同的写保护异常。对只读 VMA 写入会在这里失败。若 VMA 允许写，但 fork 后当前 PTE 暂时只读，则继续到通用缺页处理，再决定如何实现私有写入。

<Sdk id="arm64-page-fault" />

## 匿名首写、文件首触和写时复制怎么分流？

通用层遍历或准备多级页表。对于走到普通末级页的情况，`handle_pte_fault` 检查当前位置的状态。

`mm/memory.c:5027`

~~~c
if (!vmf->pte) {
	if (vma_is_anonymous(vmf->vma))
		return do_anonymous_page(vmf);
	else
		return do_fault(vmf);
}
~~~

这里的空指针表示此分支没有待处理的已建立 PTE。另有非 present 的已有项，例如换出编码。匿名首读可在符合条件时共享零页。匿名首写需要可写页。下面是普通匿名页分支中的实际申请。

`mm/memory.c:4191`

~~~c
page = alloc_zeroed_user_highpage_movable(vma, vmf->address);
if (!page)
	goto oom;
~~~

新页清零，进程因此读不到该页先前的数据。随后还需做内存组计费、准备条目以及检查竞争。在页表锁保护下完成安装，返回后 CPU 重试造成异常的那条指令。

`mm/memory.c:4233`

~~~c
set_pte_at(vma->vm_mm, vmf->address, vmf->pte, entry);
~~~

对于普通文件映射，VMA 的 vm_ops 可把首触交给 filemap_fault。它按文件索引找页缓存。下面是缓存不存在的分支，标为 major 并尝试同步预读。

`mm/filemap.c:3225`

~~~c
count_vm_event(PGMAJFAULT);
count_memcg_event_mm(vmf->vma->vm_mm, PGMAJFAULT);
ret = VM_FAULT_MAJOR;
fpin = do_sync_mmap_readahead(vmf);
~~~

有缓存时也要确认内容已经可用。major 是内核的缺页分类，用它可以缩小排查范围。物理磁盘的 I/O 次数、等待时长和归属需要另外取证。若文件被截短，仍在 VMA 内的偏移也可能因为超过文件末尾而收到 SIGBUS。

## fork 之后，同一个虚拟地址为什么可以读出不同值？

实验的后半段由父进程在私有、共享映射中各写入 A。子进程把两块各改成 B。父进程等子进程退出再读，本轮得到 `private=A shared=B`。

私有可写映射在 fork 后可暂时共享物理页，并将相关 PTE 写保护。写方再次访问时会走已有条目上的写保护分支。

`mm/memory.c:5047`

~~~c
if (vmf->flags & (FAULT_FLAG_WRITE|FAULT_FLAG_UNSHARE)) {
	if (!pte_write(entry))
		return do_wp_page(vmf);
~~~

如果页仍被共享且需要复制，`wp_page_copy` 准备新页、复制内容，再更新写方的映射。若页已经独占且满足条件，则可走复用。共享映射的写入按共享协议可见。实验用 waitpid 固定先后顺序。实时读写共享数据还需另设同步点。

<Sdk id="wp-copy" />

## V4L2 的 mmap 能直接照搬首触结论吗？

看本地 SDK 的 VB2 CMA-SG 回调。这里的 `buf->pages` 来自已经准备好的缓冲，回调在 mmap 阶段将这些页映射到 VMA。

`drivers/media/common/videobuf2/videobuf2-cma-sg.c:416`

~~~c
err = vm_map_pages(vma, buf->pages, buf->num_pages);
if (err) {
	pr_err("Remapping memory, error: %d\n", err);
	return err;
}
~~~

映射之后回调还设置 VMA 的缓冲引用钩子。捕获端何时能读帧，由 DQBUF、QBUF 管理的队列状态决定。分析其他驱动时先确认实际的 mem_ops 和 mmap 实现。本轮的 WSL 数字只验证匿名映射实验。板上捕获路径需结合启动配置和运行证据。

## 本节复盘

1. 有合法 VMA 即拥有物理页吗？先画范围，再说明首次写入怎样从异常地址找到 VMA，并安装页表项。
2. 一次缺页是否都要读盘？对照匿名写的 minor 增量、文件页缓存路径和可能的 I/O 取证。
3. fork 后 VMA 允许写，PTE 为什么仍可能只读？说明私有 COW、共享可见性以及实验为何等待子进程。
4. 有了相机 mmap 地址就能随时读吗？区分映射寿命、缓冲归属和该时刻能否访问。

下一节追踪匿名首写和驱动帧缓冲的物理页来源。[3.8 物理页、伙伴系统与 CMA](page-allocation.md)
