# 3.12 块层、存储请求与尾延迟

<script setup>
import exampleFile from '../examples/storage-queue.awk?url'
</script>

30 fps 的录像，每帧平均只占写者 15.6 ms，是否只要一项缓冲就够？用一样的平均时间做两组对照，再看应用日志和块层统计各能解释什么。

## 计算队列水位

在 WSL 仓库根目录运行。模型包含一个 FIFO 串行写者、30 个等大小项，按每帧 1000/30 ms 均匀到达。模型先允许无限容量，方便推导最少需要几项。<a :href="exampleFile" download="storage-queue.awk">下载队列模型</a>。

~~~bash
awk -f learning-site/examples/storage-queue.awk
~~~

| 合成输入 | 平均服务耗时 | 服务 P95 | 在途峰值 | 最长等待开始服务 |
| --- | --- | --- | --- | --- |
| 每项 15.6 ms | 15.6 ms | 15.6 ms | 1 | 0 ms |
| 每 10 项一项 120 ms，其余 4 ms | 15.6 ms | 120.0 ms | 4 | 86.667 ms |

一次请求的实际开始时刻取上一项完成时刻与本项到达时刻中的较晚者。已完成的项从在途中剔除，水位包括正在服务的那一项。脚本用 1/30 ms 作为整数时间单位。P95 采用最近秩，30 项按由小至大排，取第 29 项。

突发组第一项在 0 ms 到达，到 120 ms 才完成。后面三项在约 33.33、66.67、100 ms 到达，暂时只能排队。若总容量为 3，第 4 项到达时必须阻塞或丢弃。若队列容量只数等待项，则另算当前正在写的那一项。表中是模拟的应用写者服务时间和等待，未混入真实设备的并行度、编码批次或写回行为。

## 文件偏移怎样变成块 I/O？

上一节的脏页属于文件和逻辑偏移。文件系统根据自己的 extent、分配策略和映射组织 I/O，构建携带方向、目标和内存段的 bio。块层会考虑设备限制、队列和合并，构建或复用 request。驱动处理 request，并报告完成。

~~~text
写回选择脏页 → 文件系统确定逻辑块与设备范围 → bio
  → 拆分、合并或建立 request → 调度或直接派发
  → 驱动开始处理 → 块层收到部分或全部完成
  → bio 的完成回调更新上层状态，等待者可继续
~~~

一个 write 可拆成多次 I/O，多个 write 也可被合并成后续写回。日志提交和设备 flush 自己也会产生请求。想把应用耗时归到设备，必须另存匹配的设备和时间窗口。

`block/blk-mq.c:3002`

~~~c
if (unlikely(bio_may_exceed_limits(bio, &q->limits))) {
	bio = __bio_split_to_limits(bio, &q->limits, &nr_segs);
	if (!bio)
		goto fail;
}
~~~

这里按队列限制检查 bio。拆分之后的请求生成仍需题设之外的资源，例如队列标签。合并允许的条件也受方向、相邻范围和队列限制影响。块设备整合的粒度会直接改变统计中的请求数。

源码摘录 `kernel-6.1/block/blk-core.c:824–829`

~~~c
void submit_bio(struct bio *bio)
{
	if (blkcg_punt_bio_submit(bio))
		return;

	if (bio_op(bio) == REQ_OP_READ) {
~~~

## 排队、派发和完成在哪里打点？

`block/blk-mq.c:1251`

~~~c
trace_block_rq_issue(rq);

if (test_bit(QUEUE_FLAG_STATS, &q->queue_flags)) {
	rq->io_start_time_ns = ktime_get_ns();
	rq->stats_sectors = blk_rq_sectors(rq);
~~~

驱动开始处理 request 时进入起始路径。开始时刻已经晚于应用入队，也可能晚于块层插入队列。不同调度和直接派发路径的插入事件覆盖不同。比较插入与 issue 可估算有匹配记录的请求排队时间。

`block/blk-mq.c:1050`

~~~c
if (blk_update_request(rq, error, blk_rq_bytes(rq)))
	BUG();
__blk_mq_end_request(rq, error);
~~~

完整请求结束路径先根据结果更新剩余字节及关联 bio，再做请求结束处理。驱动也可以分段完成请求。若使用 trace 计算 issue 到 complete，先核对实际事件是否只覆盖一部分、是否发生重排或重试。时间差描述块层看见的区间，无法单独证明断电后仍可读取。

源码摘录 `kernel-6.1/block/blk-mq.c:1048–1053`

~~~c
void blk_mq_end_request(struct request *rq, blk_status_t error)
{
	if (blk_update_request(rq, error, blk_rq_bytes(rq)))
		BUG();
	__blk_mq_end_request(rq, error);
}
~~~

## 怎么读短窗口的 diskstats？

下面只读 WSL。两个快照间隔约 1 秒。若当前路径落在虚拟、网络或内存文件系统上，可能没有匹配块设备行。板端应在实际录像路径重新选设备。堆叠设备要固定层级，避免同一 I/O 重复算两遍。

~~~bash
findmnt -no TARGET,MAJ:MIN,FSTYPE -T "$PWD"
device=$(findmnt -no MAJ:MIN -T "$PWD" | xargs)
for sample in 1 2; do
  awk -v id="$device" '$1 ":" $2 == id {
    print $3, "已完成写", $8, "写扇区", $10, "累计写毫秒", $11, "在途", $12
  }' /proc/diskstats
  if [ "$sample" -eq 1 ]; then sleep 1; fi
done
~~~

本轮宿主路径映射到 ext4 的主次设备号 8:48，匹配 `sdd`。按同一设备的前后差值计算。

| 希望得到什么 | 怎么算或怎么看 |
| --- | --- |
| 写吞吐 B/s | 写扇区增量 × 512 / 实际窗口秒数。这里扇区计数用 512 B 单位 |
| 粗略平均写耗时 | 累计写毫秒增量 / 已完成写请求增量。零完成不可除，跨窗口请求会影响口径 |
| 采样瞬间在途数 | 直接读该时刻的在途字段。几个快照容易错过真实峰值 |
| 单个请求尾延迟或本应用的写耗时 | 另记逐请求事件或应用调用时间，diskstats 是整设备聚合 |

## 录制卡顿怎样查到最早一跳？

固定输入、编码参数、队列深度、封装和数据量。让写者消费同一编码输出，比较空 sink 和目标介质。每轮记录相机帧序号、编码输出大小、入队深度、写与同步耗时。用同一单调时间轴先确定最早变化的那一层。

- 如果两组都在同类关键帧处开始积压，先检查编码突发、CPU 争用或消费者调度。
- 如果只有介质组在写入或同步后积压，继续关联脏页节流、写回和目标设备的插入、派发与完成。
- 如果块设备很忙但应用队列还空着，核对是否来自其他进程或其他文件。只有时间顺序、设备与工作负载对照都相符，才进一步缩小原因。

本轮验证模型和宿主只读计数。板端压力、编码负载与写盘因果链待另取运行证据。

## 本节复盘

1. 两组平均耗时都低于帧间隔，为什么只有一组会超过总容量 3？把前四次到达和第一次完成画出来。
2. bio 与 request 为什么不能一一对应？举出一种拆分和一种合并情形。
3. diskstats 能否得出本应用的 P95？要采哪些额外事件，怎样匹配时间和设备？
4. 如何用空 sink 验证阻塞是否最早出现在存储路径？指出真正需要固定的输入和观察量。

下一节回到编码输入与相机内存，追踪 CPU、设备与缓冲所有权。[3.13 DMA 与缓冲所有权](dma-ownership.md)
