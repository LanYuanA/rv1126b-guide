# 3.5 锁、原子操作与对象寿命

<script setup>
import exampleFile from '../examples/counter_rmw_demo.c?url'
</script>

采集线程、停止流的线程和中断处理都可能接触一块缓冲。先区分三类问题：更新被覆盖，多个字段不一致，指针引用的对象已释放。解决其中一个并不会自动解决另两个。

## 两个原子操作为何仍能丢一次更新？

假设初始计数为 0。线程 A、B 都原子读取 0，再分别写回 1。读写各自完整，最终还是只有 1。下面用线程 barrier 控制顺序，保证两个线程都读完再写。同时让两个线程分别执行一次原子读改写作对照。整个实验只访问自己进程内存。<a :href="exampleFile" download="counter_rmw_demo.c">下载完整 C 实验</a>。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pthread learning-site/examples/counter_rmw_demo.c -o "$lab/rmw"
"$lab/rmw"
)
~~~

预期依次为 1 和 2。要同时更新队列链接、长度和缓冲状态，需要能覆盖整组操作的协议。即使原子计数本次正确，也不能据此推断链表结构一致或内容已经发布给另一个 CPU。若设计无锁生产与消费，需另证明发布端的顺序与读取端观察条件相匹配。这里的实验只演示单一计数。

## 先看调用上下文，再选锁

下表以当前候选构建配置的非 PREEMPT_RT 内核为背景。阅读其他配置下的代码时，先确认锁的实现与调用约束。

| 条件 | 看哪个机制 | 要核对的边界 |
| --- | --- | --- |
| 多条可睡眠路径争用同一状态 | mutex | 慢路径可能睡眠。持有者和释放者按 mutex 协议配对 |
| 多个 CPU 更新同一个短链表 | spinlock | 临界区短，持有期间不能调用可能睡眠的 API |
| 同一把锁也会被本 CPU 的硬 IRQ 取得 | 按访问上下文配套使用 spin_lock_irqsave 等 | 保存并屏蔽本地 IRQ，避免当前持锁者被同一 CPU 的抢占者阻住。锁本身处理跨 CPU 竞争 |

源码中 mutex_lock 会检查可睡眠上下文；快路径未取得锁时才走慢路径。以下代码对应本版非 DEBUG_MUTEXES 的一个实现分支。

`kernel/locking/mutex.c:281`

~~~c
void __sched mutex_lock(struct mutex *lock)
{
	might_sleep();

	if (!__mutex_trylock_fast(lock))
		__mutex_lock_slowpath(lock);
}
~~~

## 用 ISP 队列看锁内、锁外的状态

在 rkisp_buf_done_task 里逐行读以下三句。文件为 `drivers/media/platform/rockchip/isp/capture.c:1792`。第一个实参来自 stream 对象；第二个保存当前 CPU 的 IRQ 状态，解锁时恢复原状态。

~~~c
spin_lock_irqsave(&stream->vbq_lock, lock_flags);
list_replace_init(&stream->buf_done_list, &local_list);
spin_unlock_irqrestore(&stream->vbq_lock, lock_flags);
~~~

加锁前任何完成者都可能往共享链表添节点。持锁时把整条待办链移交给 local_list，原表复为空，解锁后新到的缓冲能进入下一批。消费者在锁外遍历本地链并调用 VB2；缩短临界区使下一次入队无需等整批处理。irqsave 防止本 CPU 在持锁期间又进入需要同一锁的硬中断，自旋锁本身负责与其他 CPU 互斥。进程上下文里可能长期等待的操作适合 mutex；持自旋锁期间不能再做可睡眠的等待。

**把停流安排在最坏的时刻。** 以下是检查驱动设计的交错，具体停流路径还要逐分支核对。帧完成者刚取到 buf 指针；另一个 CPU 发起停流，准备交还或释放这块缓冲。只给“已完成数量”做 atomic_inc，无法同时保证链表链接正确和指向的内存依然有效。

| 时点 | 完成路径 | 停流路径应保证什么 |
| --- | --- | --- |
| T0 | 持有一个仍归驱动管理的缓冲 | 阻止启动新的 DMA 或再次入队，记录停流状态 |
| T1 | IRQ 可能仍在执行，tasklet 可能已取出一批指针 | 确认硬件停止访问，等待或同步仍可能运行的回调。等待期间不能占着回调必须取得的锁 |
| T2 | 已处理或按错误交还缓冲 | 对仍由驱动持有的缓冲逐个归还一次。消费者引用结束后才能真正释放对象 |

锁保证的是遵守同一锁协议的临界区。离开临界区仍要使用指针，则需明确所有权移交、受保护的长期引用，或 RCU 的读取与宽限期协议。引用计数能延长对象寿命，但不会自动串行化两个写者。若 A 持队列锁等设备锁，B 持设备锁等队列锁，就形成 ABBA；排查挂死时把每个路径的加锁顺序写出来，比先换锁类型更有信息。

## 从“还能查到”走到“还能用”

在锁内查到 buf 指针后，如果临界区外还要访问它，应在受保护的查找过程中取得有效引用，或按队列协议完成独占移交。解锁只结束临界区，不会自动延长对象寿命。内核的 kref_put 将最后一次引用归还变成释放回调。

`include/linux/kref.h:64`

~~~c
if (refcount_dec_and_test(&kref->refcount)) {
	release(kref);
	return 1;
}
~~~

只有减引用后值为零的一方执行 release。对于从共享表查找的对象，增加引用本身也必须在对象仍可安全访问的条件下完成。不能先拿到一个不受保护的裸指针，再指望 kref_get 使已释放的对象复活。RCU 提供另一种读取协议。写者先将对象从可见集合移除，再等现有读侧临界区过完才释放。读侧若要把指针用到临界区之外，还需额外寿命保证。

## 本节复盘

1. 给“停流与帧完成同时发生”的两条路径标出队列锁、持有的引用和销毁点。说明哪一个点可停止新入队，哪一个点才可以释放。
2. A 持队列锁等设备锁，B 持设备锁等队列锁，画出 ABBA 环。若停流要等待 worker，先确定 worker 所需的锁不会被停流者占住。
3. 两个线程均使用 atomic_load 和 atomic_store，为何结果仍为 1？回到实验精确指出原子边界，再说明一个计数如何无法覆盖链表的结构不变量。

下一节用统一时钟记录上述事件，再计算它们之间的时间。[3.6 时间、超时与跨层时间戳](kernel-time.md)
