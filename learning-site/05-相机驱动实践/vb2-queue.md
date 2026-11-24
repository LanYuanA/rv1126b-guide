# 5.11 VB2 缓冲队列、DMA 与帧完成

<script setup>
import exampleFile from '../examples/vb2-slots.awk?url'
</script>

连续十几帧都在用 index 0、1、2，怎么判断帧有没有丢？先给每块缓冲固定一个槽位编号，再把每次交还的帧写上序号。把这两条记录带进 VB2 状态机。

## 在历史日志里找到同一槽的不同帧

在 WSL 仓库根目录运行。脚本按一次采集会话读 DQBUF 日志的 index 和 sequence。它拒绝无效字段和非递增序号。跨会话、回绕或需要支持其他计数语义时应调整窗口。<a :href="exampleFile" download="vb2-slots.awk">下载槽位统计脚本</a>。

~~~bash
awk -f learning-site/examples/vb2-slots.awk output/camera-check/capture.log
~~~

本轮有 **31 次出队、3 个使用槽、0 个序号缺口**。槽位 0 先后装 sequence 0、3、6。原厂这段记录的序号连续，不能靠这一项得出板端长期无丢帧，也不能发现所有内部丢失。还要结合上游计数、ERROR 与时间戳，审视观察窗口。

## 应用与驱动怎样交接一个槽位？

~~~text
REQBUFS 分配 → QUERYBUF 给位置和映射长度 → mmap 建立 CPU 映射
  → QBUF 排入队列（QUEUED）→ 交给驱动（ACTIVE）→ 设备写缓冲
  → DONE 或 ERROR → 加入已完成队列并唤醒
  → DQBUF 取回 → 应用检查并读有效范围 → 用完后再次 QBUF
STREAMOFF → 停止管线并回收队列中的缓冲 → 清理映射和队列
~~~

| 步骤 | 应用要留的返回值或字段 |
| --- | --- |
| REQBUFS(MMAP) | 使用分配返回的 count 建映射表。分配数量与开启所需已排队数量分别检查 |
| QUERYBUF 和 mmap | 按 index 与 memory plane 获得 offset/length。映射长度不由宽高直接推算 |
| QBUF | 用相同队列类型、内存方式和索引，交出捕获槽；DMA 使用期间应用暂停访问 |
| STREAMON | 确认队列类型、返回和实际启动条件，此时尚不代表已出帧 |
| poll 和 DQBUF | 检查返回、index、sequence、timestamp、flags。非阻塞 DQBUF 可返回 EAGAIN |
| 消费后归还 | 按已完成的有效范围访问，再 QBUF。停止时 STREAMOFF，解除映射后释放队列并 close |

MPLANE 用 v4l2_plane 数组描述，v4l2_buffer.length 在这时表示数组容量。实际每个 memory plane 的 length、bytesused 和 data_offset 各有含义。取数范围应同时验证索引与平面边界。[Linux 6.1 MMAP](https://docs.kernel.org/6.1/userspace-api/media/v4l/mmap.html) · [QBUF 与 DQBUF](https://docs.kernel.org/6.1/userspace-api/media/v4l/vidioc-qbuf.html)

## STREAMON 如何受队列水位影响？

`drivers/media/common/videobuf2/videobuf2-core.c:2144`

~~~c
if (q->queued_count >= q->min_buffers_needed) {
	ret = v4l_vb2q_enable_media_source(q);
	if (ret)
		return ret;
	ret = vb2_start_streaming(q);
	if (ret)
		return ret;
}
~~~

这是 VB2 的通用门槛，取决于具体驱动配置。已分配数量够但尚未排入足够缓冲时，部分队列可延后到后续 QBUF 才实际调用 start_streaming。本地 V35 静态配置将 min_buffers_needed 设为 0，历史应用使用的三个槽位并非这个门槛。应用仍需先准备有效的可写缓冲，并保留启动与帧完成证据。

## 中断产生的缓冲怎样到 DQBUF？

本地 RKISP V35 的静态分支在处理完成缓冲时，把帧序号和时间戳填入对象。实际触发哪一条分支需要运行轨迹证实。

`drivers/media/platform/rockchip/isp/capture_v35.c:1135`

~~~c
buf->vb.sequence = seq;
vb2_buf->timestamp = ns;
~~~

VB2 的完整交还路径先执行必要的内存交接，持 done_lock 将缓冲加入完成队列并标记状态。正常 DONE 与 ERROR 都要向应用交付状态。

`drivers/media/common/videobuf2/videobuf2-core.c:1093`

~~~c
list_add_tail(&vb->done_entry, &q->done_list);
vb->state = state;
~~~

稍后解锁，并唤醒 done_wq 上的等待者。poll 返回就绪只给一个观察点，应用仍以 DQBUF 返回判定是否得到槽位。若 ERROR 标志置位，应用按错误帧处理，再根据当前驱动的规则归还。用户实际获得的时间要另外用自己的时钟打点。

<Sdk id="done" />

## 两种超时怎样用最小证据区分？

假设一开始排了三槽，下面两次都出现“没有下一次 DQBUF”。不要只看同一条超时文案。

| 纸上情形 | 应用能观察到 | 内核或上游补查 |
| --- | --- | --- |
| 三帧已出队，应用一直没有再 QBUF | 用户持有 3，驱动无可用空槽 | 记录每个槽的最后 QBUF/DQBUF，看看是否还有帧边界却无法交付 |
| 三个空槽已提交，上游没有帧 | 用户没有取到槽，已排队的缓冲还待写 | 对齐 STREAMON 后的 sensor、CSI/CIF/ISP 帧事件、IRQ 和错误 |

若上游仍有帧边界且用户占着全部槽，先修归还策略。若驱动确实有可写槽但上游一直没帧，继续追前一级。STREAMOFF 负责停止并清理队列。调试中还应记录成功映射数、开始状态与队列归属，以便失败时只回收已取得的资源。

## 本节复盘

1. index 又变成 0，如何用 sequence 和历史例子解释？
2. mmap 成功时缓冲由谁访问？QBUF 后又是谁？
3. 两种超时都没有新帧，哪些槽位计数与上游事件能把它们分开？
4. 为什么 STREAMON 返回、硬件帧结束、任务被唤醒、DQBUF 返回要各自打点？

本轮只分析历史记录与本地静态实现，板端实时队列尚待采样。下一节把这些调用与清理逻辑写进可复现的 C 客户端。[5.12 独立实现 C 采帧与图像验证](capture-client.md)
