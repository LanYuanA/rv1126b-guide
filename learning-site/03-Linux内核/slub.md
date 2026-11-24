# 3.9 SLUB、kmalloc 与内存分配上下文

<script setup>
import analysisFile from '../examples/slub-rounds.awk?url'
import sampleFile from '../examples/slub-rounds.tsv?url'
</script>

一个驱动每次打开设备申请一个对象，每次关闭都调用 kfree。第一次测试后 Slab 升高，是否有泄漏？先把**驱动仍拥有的对象**和**分配器保留的对象槽**分开数。

## 先运行两组对照

在 WSL 仓库根目录执行。输入为构造样本，可直接用任意一行复算。<a :href="analysisFile" download="slub-rounds.awk">下载统计脚本</a>和<a :href="sampleFile" download="slub-rounds.tsv">下载输入样本</a>。

~~~bash
awk -f learning-site/examples/slub-rounds.awk learning-site/examples/slub-rounds.tsv
rg '^(Slab|SReclaimable|SUnreclaim):' /proc/meminfo
rg '^CONFIG_SLUB=' atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal/.config
~~~

本轮运行得到 warmup 组各轮净分配为 0，活动数始终 64，首轮总槽数从 96 涨至 224。growth 组每轮净多 8，累计为 8、16、24，总槽数也在 224。统计脚本对一组内的 alloc−free 求累计，并将每轮活动数与第 0 轮比较。相同槽数可以掩盖不断增加的活对象。该输入用于演算。后两条命令分别读取宿主全局 Slab 汇总和板端候选构建配置，宿主当前账号无法读取 /proc/slabinfo。组件级计数需要匹配的观测窗口和权限。

## 从一组页到许多可复用槽

上一节的伙伴分配器管理以页为单位的块。SLUB 向底层获取页，再按 cache 对象的布局切槽。kmalloc 规模较小时通常走通用大小档。专用 kmem_cache 则可为有固定形状的对象提供相应的大小、对齐和构造配置。一份 slab 中可有多个槽，因此释放一个槽只表示它能给下一位用。

| 对象 | 负责什么 | 看哪些字段或结构 |
| --- | --- | --- |
| kmem_cache | 同一种对象槽的布局及缓存策略 | 对象大小、实际槽大小、各 CPU 与各 node 的分配状态 |
| kmem_cache_cpu | 当前 CPU 的分配状态 | 当前 slab、freelist 和用于检测状态变化的 tid |
| slab | 来自页分配器的一组页 | 槽总数、对象空闲链、使用状态 |
| 驱动对象 | 某一次调用取得的状态 | 引用与所有权由调用侧约定 |

若一次 100 字节申请落到 128 字节档，槽内有 28 字节未被这次请求使用。这是内部碎片，实际每槽占用还可能受对齐或调试元数据影响。另一个常见现象是每个 slab 只留下少数活对象，整组页依然不能回收。它与上一节中找不到对齐物理页块的外部碎片表现不同。

## kmalloc 怎么选档，快路径怎么取一槽？

`include/linux/slab.h:563` 展示了常量 size、普通大小档的入口。前面的 kmalloc_index 用大小选择下标。大请求有单独的分支。

~~~c
return kmalloc_trace(
		kmalloc_caches[kmalloc_type(flags)][index],
		flags, size);
~~~

flags 会影响通用 cache 类型及分配约束，size 保留原始请求大小。`kzalloc` 复用 kmalloc 并加 `__GFP_ZERO`，调用侧可依赖请求内存清零。分配失败仍需检查返回值。

`mm/slub.c:3359`

~~~c
object = c->freelist;
slab = c->slab;

if (!USE_LOCKLESS_FAST_PATH() ||
    unlikely(!object || !slab || !node_match(slab, node))) {
	object = __slab_alloc(s, gfpflags, node, addr, c, orig_size);
~~~

这个分支判断能否从当前 CPU 的空闲链取槽。若能走无锁快路径，后面的比较交换会同时核对 freelist 和 tid 再推进链头。发现期间状态变了就重试。慢路径可尝试获取现有的可用 slab，必要时才向页分配器请求新 slab。这样绝大多数小对象申请只需处理缓存中的槽。

## kfree 之后，哪些状态才可能下降？

~~~text
打开路径取得对象 → 驱动持有并使用 → 最后引用退出 → kfree
  → 对象槽可复用
  → slab 为空且符合释放策略 → 摘下 slab → 归还底层页
~~~

在本地 SLUB 的慢释放路径里，新状态没有活对象并且 node 的 partial 数量满足阈值时，会选择 slab_empty 分支。

`mm/slub.c:3545`

~~~c
if (unlikely(!new.inuse && n->nr_partial >= s->min_partial))
	goto slab_empty;
~~~

接下来根据 slab 所在链表将它摘下，最终 discard_slab。若仍有活对象，或缓存按策略保留空 slab，释放只表现为能复用更多槽。这个片段对应慢路径，CPU 私有状态与调试配置还可能走其他路径。

源码摘录 `kernel-6.1/mm/slub.c:3592–3597`

~~~c
static __always_inline void do_slab_free(struct kmem_cache *s,
				struct slab *slab, void *head, void *tail,
				int cnt, unsigned long addr)
{
	void *tail_obj = tail ? : head;
	struct kmem_cache_cpu *c;
~~~

## GFP 约束来自哪里？

| 调用场景 | 约束和选择 | 失败处理 |
| --- | --- | --- |
| 进程上下文的 open，当前允许睡眠 | GFP_KERNEL 可触发直接回收及其 I/O 或文件系统工作 | 处理 NULL，避免发布半初始化指针 |
| 硬中断或持不可睡眠锁 | GFP_ATOMIC 不允许直接回收睡眠，可尝试动用部分保留资源 | 仍可能失败。高频采集可在启流时备好对象池，明确耗尽策略 |
| 文件系统回收重入风险 | 先核对锁、调用栈与相关回收边界，再选择允许的上下文约束 | 记录失败条件，避免让内存回收重新等待调用方持有的资源 |

便笺驱动的 `note_open` 是第一个场景。下面的地址只在分配成功、mutex 初始化完毕以后发布到 file。

`learning-site/examples/char/rvnote.c:17`

~~~c
struct note_file *note = kzalloc(sizeof(*note), GFP_KERNEL);

if (!note)
	return -ENOMEM;
mutex_init(&note->lock);
file->private_data = note;
~~~

独立打开会各自分配。dup 共享原有 file，因此同一个整数槽关闭时未必执行 `note_release`。最终 release 释放 private_data 后，驱动已经不能再用该指针，SLUB 则可安排槽复用。将设备驱动的释放数字和全系统 Slab 比较之前，先匹配观察粒度。

## 怎样取证，才能从上升读数走到泄漏判断？

1. 预热前取一轮基线，另设同长度的空白对照。每轮都记录成功 open 数、dup 数、已关闭的描述符及最后释放数，空闲等待时间保持一致。
2. 对比同一 cache 的活动对象和总槽数。通用 kmalloc 档可混有其他设备和内核功能。单看 Slab 只能描述全系统分配页变化，不能归因到某个驱动。
3. 若活动数和净分配都持续增加，检查是否存在正常的未关闭句柄、异步队列积压或延后清理。待正常引用清空后仍持续增长时，再按调用点和对象地址配对。地址重用时，按时间记录一轮分配到释放的顺序。
4. 如果驱动已释放且活动数回到基线，总槽数首轮升高随后稳定，可优先验证缓存复用。后续监测工具可并排显示缓存水位、对象净增量和采样窗口。

当前只复跑宿主汇总读数和离线对照，实际 rvnote 对象事件需在匹配内核上另行验证。

## 本节复盘

1. 已经调用 kfree，Slab 为什么可能不降？依次解释槽、slab、页和保留条件。
2. open 可以用 GFP_KERNEL，搬进硬中断完成路径为什么需要重新选？说清哪些路径会等待，以及分配失败后事件怎么处理。
3. 两组样本槽数都 224，哪组需要追查对象？用第 3 轮的净分配、活动变化与总槽数分别作证。
4. 应用连续调用 close，却缺少最后释放事件。如何用 dup、继承、并发访问和驱动实际 release 去缩小排查范围？

下一节继续用引用的视角解释名字消失后为什么 fd 还能访问。[3.10 文件系统、挂载与打开文件的寿命](文件管理.md)
