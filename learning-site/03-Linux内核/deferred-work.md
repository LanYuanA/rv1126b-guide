# 3.4 延后处理、等待队列与 completion

镜头转向 ISP。正常缓冲完成的一条源码路径如下。对照 capture.c，找到生产者怎样在锁内入链，然后找到消费者怎样在锁内取走整批链表。

~~~text
rkisp_stream_buf_done → buf_done_list → tasklet_schedule
 → rkisp_buf_done_task → 局部链表 → vb2_buffer_done
 → VB2 更新状态并入 done_list → wake_up(done_wq)
 → 出队者再查条件 → 拿走已完成的缓冲
~~~

### 驱动先接手，再向 VB2 交付

`drivers/media/platform/rockchip/isp/capture.c:1822`

~~~c
spin_lock_irqsave(&stream->vbq_lock, lock_flags);
list_add_tail(&buf->queue, &stream->buf_done_list);
spin_unlock_irqrestore(&stream->vbq_lock, lock_flags);
tasklet_schedule(&stream->buf_done_tasklet);
~~~

驱动将缓冲挂到自己的完成链并安排 tasklet。复盘时记住这是 ISP 的内部链，tasklet 真正运行后才会调用 VB2。

ISP 的 tasklet 把已完成缓冲交给 VB2。框架维护应用等待的完成队列。

`drivers/media/common/videobuf2/videobuf2-core.c:1093`

~~~c
	list_add_tail(&vb->done_entry, &q->done_list);
	vb->state = state;
}
atomic_dec(&q->owned_by_drv_count);
~~~

先提交完成项，再通知等待者。出队端还要重新检查停止、错误和数据是否可用。

源码摘录 `kernel-6.1/drivers/media/common/videobuf2/videobuf2-core.c:1103–1112`

~~~c
spin_unlock_irqrestore(&q->done_lock, flags);

trace_vb2_buf_done(q, vb);

switch (state) {
case VB2_BUF_STATE_QUEUED:
	return;
default:
	/* Inform any processes that may be waiting for buffers */
	wake_up(&q->done_wq);
~~~

队列的上锁与发布先发生。对于正常完成或错误完成等情况，随后才执行 wake_up。由前面的 switch 可以看到，重新标为 QUEUED 的分支会直接返回。消费者的判断如下。

`drivers/media/common/videobuf2/videobuf2-core.c:1869`

~~~c
ret = wait_event_interruptible(q->done_wq,
		!list_empty(&q->done_list) || !q->streaming ||
		q->error);
~~~

done_list 非空、停流或队列错误都能结束这次等待。阻塞路径睡前通过 wait_prepare 配合驱动释放应释放的锁，醒来后 wait_finish 再取得并重新检查。非阻塞路径没有缓冲可取时直接返回 EAGAIN。唤醒还要等调度器运行该线程，也没有替线程保留任何一个 buffer。

hardirq 处理时间紧且不能睡眠；softirq 和本例 tasklet 也不能调用可能阻塞的同步 I2C 操作。tasklet 把工作移出最先处理设备事件的路径，仍有原子上下文的约束。需要等待 I2C 的慢工作可交给普通可睡眠的 worker，但需确定停流或解绑时如何取消、等待并释放对象。用户地址复制通常放在持有正确用户上下文的系统调用路径。短链表更新可以在 IRQ 使用的自旋锁下完成。

| 同步对象 | 状态在哪里 | 先完成后等待会怎样 |
| --- | --- | --- |
| wait queue | 驱动或框架保存可检查条件，如 done_list 非空；队列组织等待者 | 读者先查条件，若已满足可直接继续。单独一次 wake_up 没有替未来读者保存数据 |
| completion | completion 对象维护完成计数和等待者 | complete 可以先发生，随后 wait_for_completion 可消耗一次完成；超时路径仍须保证对象在生产者访问时有效 |

### 一次完成怎样留给尚未到场的等待者

`kernel/sched/completion.c:32`

~~~c
raw_spin_lock_irqsave(&x->wait.lock, flags);

if (x->done != UINT_MAX)
	x->done++;
swake_up_locked(&x->wait);
raw_spin_unlock_irqrestore(&x->wait.lock, flags);
~~~

complete 持锁增加 done 后才唤醒。因此生产者先完成也没有关系：后来等待者仍能观察到 done 非零，再消费一个完成计数。UINT_MAX 是 complete_all 使用的特殊值。

`kernel/sched/completion.c:92`

~~~c
if (x->done != UINT_MAX)
	x->done--;
return timeout ?: 1;
~~~

普通等待队列外部需要一个持久条件，比如列表已非空。completion 的状态集成在完成对象内，适于等待一个明确阶段完成，例如某次 worker 退出。wait_for_completion_timeout 返回 0 表示等超时，返回正数表示完成。超时只结束等待，驱动还要取消或同步生产者，再释放 completion 所在对象。若生产者仍在写，不能重用同一个 completion 作为下一次请求的结果。

用已存在的宿主实验再验证一次“就绪可能变化”。它只验证应用看到的条件变化，内核 completion 的计数与超时则由上述源码和时序推导。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
cc -std=c11 -Wall -Wextra -Werror learning-site/examples/io_contract_demo.c -o "$lab/io-contract"
"$lab/io-contract"
)
~~~

## 选择延后执行方式时先问是否会睡

| 上下文 | 可以做的典型工作 | 如何安全停止 |
| --- | --- | --- |
| hardirq | 确认来源，按手册清源，提交短小状态 | 禁止新事件，并处理已在运行的 ISR。等待前释放 ISR 要拿的锁 |
| softirq / tasklet | 在原子约束下处理队列，把完成缓冲交给框架 | 先阻止新的调度，再同步已排队或正在执行的回调 |
| 普通 workqueue | 访问可能等待的总线或处理更长的任务 | 禁止生产者再次排队，再等待或同步取消相应 work，最后释放实例 |
| 线程化 IRQ 的线程函数 | 执行允许睡眠的后续工作 | 核对主处理函数与线程的屏蔽、唤醒及注销顺序 |

tasklet 与 softirq 可能在返回路径或 ksoftirqd 中运行，切到内核线程执行也不会自动让这段回调可以阻塞。普通 worker 有进程上下文，仍不能在持自旋锁时睡眠。同步 I2C 往往需要等待控制器完成，应交给可睡眠路径。访问用户缓冲还需要合适的用户上下文，通常放在 read 或 ioctl 内。

**纸上排错。** 时刻 A 队列空，消费者睡眠。B 生产者先唤醒，C 消费者被调度、查到仍为空并再次睡眠。D 生产者终于把帧挂到队列，却没有再次通知。系统可能表现为“有数据，应用还在等”。调整生产者顺序，在同步保护下先发布条件，再通知。醒来的读者每次仍须重查条件，因为其他线程可能已经取走缓冲，或停流改变了返回原因。用[卷二的 poll 竞争实验](../02-应用与字符驱动/io-contract.md)可以在 WSL 看到后一个读者得到 EAGAIN。

## 本节复盘

1. 画出“先 wake_up、后写条件”的错误时间线。指出消费者是哪一步在条件仍不成立时再次睡下。
2. 让生产者先 complete，再启动等待者。哪一格状态保留下来了？若使用空的 wake_up，同样的时序要依靠哪一份外部状态？
3. 停流发生时，正在等待 DQBUF 的线程可能因哪一项条件返回？从 SDK 的条件表达式找停流分支，再用卷二实验对照就绪后仍可能 EAGAIN 的现象。

下一节将竞争点落到具体对象上，解释短锁临界区与引用寿命如何配合。[3.5 锁、原子操作与对象寿命](locking.md)
