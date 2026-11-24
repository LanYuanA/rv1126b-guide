# 3.1 进程、线程与资源共享

<script setup>
import exampleFile from '../examples/task_resources_demo.c?url'
</script>

摄像头已经写完一帧，应用却过了几毫秒才从 poll 返回。要拆解这几毫秒，先认清现场中的三个角色：持有设备 fd 的进程、等待事件的线程、最后真正执行这个线程的 CPU。下面用一根 pipe 做生产者和消费者，分别改变文件引用的寿命和线程被选中运行的时间。

## 3.1 进程、线程与共享资源 {#tasks}

假设一个录像进程有采集和写盘两个线程。Linux 会给两个可调度任务各留一份 task_struct。程序读到的进程号通常是线程组 ID（TGID），每个线程还有自己的 TID。拿应用日志里的进程号去匹配调度轨迹，可能恰好把真正等帧的线程漏掉。

先预测同一进程两次查询的哪一列相同。实际的数字会随运行变化。

从同一进程的 `/proc/<TGID>/task/*/status` 读取 Tgid 和 Pid，比较主线程与其他线程。需要现成多线程进程时可用 `ps -eLo pid,tid,comm` 选择一个 TGID。

在主线程行，三个数相等；工作线程的前两列与主线程相同，Tid 变了。每个线程有独立的寄存器现场、栈与调度状态。普通 POSIX 线程共享地址空间和 fd 表，所以写盘线程 close 某个共享 fd，采集线程再使用那个编号就可能失败，甚至碰上编号已被新打开的文件复用。

### fork 后各有一份 fd 表，为什么还收不到 EOF？

打开 SDK 的 copy_files 和 copy_mm。先看是否设置 CLONE_FILES：设置时增加同一 files_struct 的引用，否则复制 fd 表，复制出的条目仍可引用原来的 struct file。CLONE_VM 控制是否共享 mm。普通 fork 后父子有各自的地址空间，私有可写页常用写时复制实现。已有的 pipe 是内核里的同一个对象，两张 fd 表都能引用它。

源码摘录 `kernel-6.1/kernel/fork.c:1620–1625`

~~~c
static int copy_files(unsigned long clone_flags, struct task_struct *tsk)
{
	struct files_struct *oldf, *newf;

	/*
	 * A background process may not have any files ...
~~~

文件表可以共享或复制。地址空间有自己的决定条件，不能从文件表推出来。

源码摘录 `kernel-6.1/kernel/fork.c:1563–1568`

~~~c
static int copy_mm(unsigned long clone_flags, struct task_struct *tsk)
{
	struct mm_struct *mm, *oldmm;

	tsk->min_flt = tsk->maj_flt = 0;
	tsk->nvcsw = tsk->nivcsw = 0;
~~~

在此前的 WSL 对照中，父进程创建 pipe 后 fork，子进程写一个字节并退出。父进程在 waitpid 成功后才继续观察，这样能排除“子进程还没跑到 close”这个干扰。读端设置非阻塞，空读和 poll 都有明确的结束条件。

将父进程 write fd 保留或关闭各画一次，先数剩余写端引用，再读下表。

| 父进程的动作 | 子进程退出且读走 F 后 | 原因 |
| --- | --- | --- |
| 及时关闭自己的写端 | 挂断 True，再次读取为空 | 缓冲已空，最后一个写端引用也已释放 |
| 留着自己的写端 | 挂断 False，再次读取报 EAGAIN | 父进程仍能写入。若改为阻塞读，且没有人写入或关闭，这里可能一直等待 |

单线程子进程 exit 时会释放文件引用，结束后的退出状态可以留给父进程 wait；退出后尚待回收状态的子进程称为僵尸。保留这个等待状态不会让其继续持有 pipe 写端。exec 则是当前任务换入新程序映像，成功时调用点不会返回；带 FD_CLOEXEC 的描述符会在这个过程中关闭。录像程序若启动辅助进程，应同时审查 fork 后谁关闭哪端，以及 exec 时还会留下哪些 fd。两者都可能改变 EOF 出现的时间。

**本节复盘。** 如果真正退出的只是同进程的工作线程，能指望它退出时替整个进程关掉写端吗？先在纸上画 fd 表的所有者。普通线程退出只少了一个共享者，其他线程仍然使用同一张表。这个区别决定了应该在哪里编写显式关闭逻辑。

## 沿创建、执行和退出分开读资源

fork 通过内核的任务创建入口构造新任务，具体哪些资源复制、哪些共享，要看构建 copy_process 的 clone 标志。普通 fork 产生新线程组并单独复制 fd 表；fork 之后的表项仍能引用同一打开对象。POSIX 线程由用户态库采用相应 clone 标志建立，同组任务共享进程级资源，仍各自有任务身份与运行状态。TID 的数值来自可见的 PID 命名空间，跨容器核对事件时先确认观察口径。

源码摘录 `kernel-6.1/kernel/fork.c:2716–2721`

~~~c
pid_t kernel_clone(struct kernel_clone_args *args)
{
	u64 clone_flags = args->flags;
	struct completion vfork;
	struct pid *pid;
	struct task_struct *p;
~~~

exec 成功时用新程序映像替换旧执行环境。同一个进程身份继续存在，地址空间替换，带 FD_CLOEXEC 的描述符关闭。普通子进程随后 exit 时释放自己的文件引用，wait 则负责读取退出状态。僵尸保留退出信息供回收。应用排查时，如果已经知道子进程退出，仍需检查父进程或其他引用者是不是留着写端。

源码摘录 `kernel-6.1/fs/exec.c:983–988`

~~~c
static int exec_mmap(struct mm_struct *mm)
{
	struct task_struct *tsk;
	struct mm_struct *old_mm, *active_mm;
	int ret;

~~~

进程替换映像后仍需管理退出。查看对子进程退出信息的处理，区别等待者已经观察到退出和正式回收这两个时刻。

源码摘录 `kernel-6.1/kernel/exit.c:1096–1101`

~~~c
static int wait_task_zombie(struct wait_opts *wo, struct task_struct *p)
{
	int state, status;
	pid_t pid = task_pid_vnr(p);
	uid_t uid = from_kuid_munged(current_user_ns(), task_uid(p));
	struct waitid_info *infop;
~~~

## 实测两种“共享”的差别

<a :href="exampleFile" download="task_resources_demo.c">下载完整 C 实验</a>。在仓库根目录运行，程序只打开 /dev/null 和自己的管道。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pthread learning-site/examples/task_resources_demo.c -o "$lab/tasks"
"$lab/tasks"
)
~~~

工作线程关闭的槽位会在主线程也变成 EBADF。fork 对照先用 waitid 的 WNOWAIT 确认子进程已退出，再读取管道，最后才 waitpid 回收。父进程关闭自己的写端时读到 EOF。保留写端时读到 EAGAIN。这个对照排除了“父进程必须先回收僵尸，管道才能结束”的假设。

## 本节复盘

如果录像进程同时使用多个线程与辅助子进程，请给其中同一个读 fd 画出两张图。线程共享一张表，子进程通常有自己的一张表；在对象层，它们仍可能指到同一个打开文件。说明各方在哪个时刻关闭描述符，以及为什么只等 pid 退出不足以解释还有没有生产者。

下一节把“等数据”拆成线程睡眠、唤醒、入队和切入。[3.2 调度器与唤醒延迟](调度器实现.md)

## 调度延迟案例与 3.2 导读 {#wakeup}

调度器的实现主线见[3.2 调度器与唤醒延迟](调度器实现.md)。下面保留 pipe 与相机的时间线对照。

想象读者线程对空 pipe 调用 poll。驱动登记等待队列并检查就绪条件，框架在需要时让线程睡眠。写者发布数据并唤醒队列，调度器才有机会安排读者运行。此前的 WSL 实验用单调时钟，在读者侧标记开始和结束，在写者侧标记写入前的时刻。先判断能否从这三个时间点算出读者等 CPU 的时间。

把应用在写前与读后取得的两个单调时间相减，再和下节的调度事件对齐。

从开始等待到读完的时间包含生产者人为等待的约 20 ms。从准备写到读完的时间包含写系统调用、事件发布以及读者返回用户态和读取的开销。即使第二项很大，也缺少两个边界：读者何时变成 runnable，何时真正得到 CPU。上例没有开启系统追踪，甚至可能在读者进入内核等待之前写者已经写完；两端时间无法证明发生过一次睡眠。

### 用两个调度事件配出哪一段时间？

源码摘录 `kernel-6.1/kernel/sched/core.c:4086–4091`

~~~c
try_to_wake_up(struct task_struct *p, unsigned int state, int wake_flags)
{
	unsigned long flags;
	int cpu, success = 0;

	preempt_disable();
~~~

唤醒只改变任务的可运行机会。公平调度按运行时间和权重记账。

源码摘录 `kernel-6.1/kernel/sched/fair.c:882–887`

~~~c
static void update_curr(struct cfs_rq *cfs_rq)
{
	struct sched_entity *curr = cfs_rq->curr;
	u64 now = rq_clock_task(rq_of(cfs_rq));
	u64 delta_exec;

~~~

更新运行时间后，选择路径还须根据队列中的候选决定下一位。

源码摘录 `kernel-6.1/kernel/sched/fair.c:7793–7798`

~~~c
pick_next_task_fair(struct rq *rq, struct task_struct *prev, struct rq_flags *rf)
{
	struct cfs_rq *cfs_rq = &rq->cfs;
	struct sched_entity *se;
	struct task_struct *p;
	int new_tasks;
~~~

在 try_to_wake_up 中找任务状态检查和目标 CPU 的选择。任务可以进入某个 CPU 的运行队列，也可在迁移后到另一个 CPU 执行。源码里的 TASK_RUNNING 涵盖就绪和正在运行两种情况；只看 /proc 的瞬时 R 无法分出其间的等待。再看普通调度类 update_curr：把当前实体实际运行增量按权重换算，累加到 vruntime；pick_next_task_fair 从可运行实体中选择。权重影响竞争 CPU 的份额。组调度、亲和性、更高优先级调度类都会影响某个线程下一次何时运行。

下表是**人工给定的事件样本**，时钟统一，单位 µs。目标读者 TID 为 72。筛选 wakeup 看被唤醒的 pid；筛选 switch 看 next_pid。事件行开头的当前任务可能是写者。

| 时间 | 记录 CPU | 事件 | 应如何配对 |
| ---: | ---: | --- | --- |
| 1000 | 0 | sched_wakeup pid=72 target_cpu=1 | 记录等待起点 |
| 1050 | 1 | sched_switch next_pid=88 | 切入其他任务 |
| 1370 | 1 | sched_switch next_pid=72 | 读者本次等待可计算为 1370−1000=370 µs |
| 1420 | 1 | 读者在用户态记下已读一字节 | 后续 50 µs 包含返回与读操作 |
| 2100 | 0 | sched_wakeup pid=72，之后记录结束 | 缺少下一次切入，结果记为不可判定 |

若看见线程被抢占时仍 runnable，之后重新切入之前可能没有新的 wakeup。那一段用 switch-out 与 switch-in 配对，并保留切出状态。统计真实板端时还应记录 TID、运行负载、CPU 亲和性、trace 时钟、丢失记录和样本数；再在相同分辨率、帧率与录像负载下比较分布。单次最慢帧可回到时间线核查。

### 为什么提高采集线程优先级有时仍等不到帧？

当采集线程在等设备事件时，即使 CPU 空闲它也无帧可取。若高优先级采集线程等低优先级写盘线程手中的 mutex，而中优先级线程持续占用 CPU，锁持有者可能迟迟无法运行，形成优先级反转。能否继承优先级取决于锁的实现。先找锁持有者与临界区，把阻塞 I/O 移出共享锁；若追踪显示采集线程醒后确实长期等 CPU，再检查调度类、竞争者、亲和性及迁移。

### 把超时、就绪和结束放进同一个对照

此前 WSL 验证保持同一对 pipe fd，先空等一次，再写入两个字节并关闭写端。第一次等待没有生产事件。第二次同时存在可读数据和结束标志，因此需要先读完数据。

先空等 20 ms，再写入 OK 后关闭最后一个写端。已有宿主记录见下方。

超时行通常在 20 ms 左右，调度或系统负载可使返回变晚。后两行应分别打印 `b'OK'` 和 EOF。`poll(0)` 是立即查询，空的事件列表表示没有就绪 fd。`POLLIN` 与 `POLLHUP` 是可组合的位，使用相等比较会漏掉同时成立的情况。

源码摘录 `kernel-6.1/fs/pipe.c:654–659`

~~~c
pipe_poll(struct file *filp, poll_table *wait)
{
	__poll_t mask;
	struct pipe_inode_info *pipe = filp->private_data;
	unsigned int head, tail;

~~~

对象返回当前就绪位并登记等待。poll 的通用循环决定空结果时是否等待和重查。

源码摘录 `kernel-6.1/fs/select.c:882–887`

~~~c
static int do_poll(struct poll_list *list, struct poll_wqueues *wait,
		   struct timespec64 *end_time)
{
	poll_table* pt = &wait->pt;
	ktime_t expire, *to = NULL;
	int timed_out = 0, count = 0;
~~~

阅读 `pipe_poll` 时，先找 `poll_wait` 对读写队列的登记，再找数据与 writer 数量怎样形成 mask。到 `do_poll` 看扫描结果为空时何时等待，以及唤醒后怎样重新扫描。应用观测到的区间包含从睡眠到再次获得 CPU 的时间。要测调度等待，需要把目标线程的唤醒事件与真正切入的事件配对。

换到相机，VB2 的可完成条件包括完成列表有缓冲，也关注停止流与队列错误。读 `__vb2_wait_for_done_vb` 时圈出三步。先在阻塞前检查状态，空且非阻塞时返回 `-EAGAIN`。阻塞路径经 `wait_prepare` 做等待前准备，再等 `done_wq` 的条件。醒来后经 `wait_finish` 恢复并重新检查。若驱动使用这些回调释放和重新获取队列锁，可继续跟读驱动所填的函数。pipe 结束标志和相机停止流各有自己的判断规则。

源码摘录 `kernel-6.1/drivers/media/common/videobuf2/videobuf2-core.c:1811–1816`

~~~c
static int __vb2_wait_for_done_vb(struct vb2_queue *q, int nonblocking)
{
	/*
	 * All operations on vb_done_list are performed under done_lock
	 * spinlock protection. However, buffers may be removed from
	 * it and returned to userspace only while holding both driver's
~~~

**排错。** 应用报告等了 60 ms 时，先记下是 `poll` 超时、`DQBUF` 报错，还是已成功取帧但间隔拉长。若同时有缓冲完成和线程切入的时间戳，就能分别计算硬件到缓冲完成、唤醒到切入的区间。需要保证时间戳口径一致，再与帧序号对照。[中断和缓冲完成](interrupts.md)
