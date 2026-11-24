# 6.4 tee、queue、背压与丢帧策略

<script setup>
import exampleFile from '../examples/gst-queue-demo.sh?url'
</script>

预览和录像都能单独工作，放在一起却一顿一顿。先查共享源在哪个线程推帧，哪个消费线程握着缓冲，以及它什么时候能归还。资源问题与画面格式问题要用不同证据定位。

## tee 把同一帧交给多个消费者

~~~text
上游线程 → tee ┬→ queue A 的 sink      queue A 的 src 线程 → 预览
              └→ queue B 的 sink      queue B 的 src 线程 → 录像
~~~

在 GStreamer 1.24.2 的多分支普通 buffer 路径，`gst_tee_do_push()` 给当前分支持有一份 buffer 引用。

~~~c
res = gst_pad_push (pad, gst_buffer_ref (GST_BUFFER_CAST (data)));
~~~

这行本身只增加引用。两路通常指向同一个底层缓冲，一支还持有时，源池就可能还不能复用。某支后面的缩放、格式转换或写时复制可以产生新缓冲。异步分支的对象引用还需要各自按约定释放。 `tee` 向下游 push 仍有串行部分。没有 queue 时，慢支路的处理可以直接占住上游调用路径。 [GStreamer 1.24.2 tee 推送实现](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gstreamer/plugins/elements/gsttee.c#L843)

## queue 隔开执行线程，也定义等待上限

queue 把上游 push 写到它的队列，让自己的 src 线程取走。缓冲从入口到出口可以经过四个阶段。

| 阶段 | 慢支路队列 | 对上游的影响 |
| --- | --- | --- |
| 起步 | 基本空，消费者取走一帧进入处理 | push 很快返回 |
| 短时积压 | 下一个帧到时，上一帧仍在处理 | 新帧先排队，另一支可继续 |
| 达到上限 | 一次 push 遇到满队列 | 阻塞等待空间，或者按 leaky 策略做丢弃 |
| 恢复或排空 | 消费者继续取帧并陆续释放引用 | 阻塞的上游被唤醒，EOS 也能有序向下游推进 |

队列可用 `max-size-buffers`、`max-size-bytes` 或 `max-size-time` 限制。多个非零上限同时配置时，先命中的限制生效。设为 0 会关闭该维度。用 30 fps 粗算，三个待处理帧代表约 100 ms 的媒体时长。这个值没有包含正在处理的帧、源池、编码器或其它队列。若源稳定到达 30 fps、消费者仅能处理 20 fps，从空队列直到多积三帧约需 `3/(30−20) = 0.3 s`。等待延迟仍要测同一帧的进队和出队实际时间。

| leaky | 满时怎么处理 | 观察结果 |
| --- | --- | --- |
| `no` | 等待有空位 | 原始序列保留，积压可把上游以及其他支路一起拖慢 |
| `upstream` | 丢当前新到的帧 | 已积压的旧帧仍按顺序送出 |
| `downstream` | 先丢队列中的旧帧，再收新帧 | 剩余帧更接近当前，但能看到序列跳变 |

有需要时在程序里读 `current-level-buffers`、`current-level-bytes`、`current-level-time`，配合 `overrun` 信号观察满队列。信号可以来自 streaming thread，回调里做简短计数或异步转交事件。默认阻塞、丢新和丢旧都能在 1.24.2 的入队实现中对上。 [queue 属性与线程](https://gstreamer.freedesktop.org/documentation/coreelements/queue.html) · [queue 入队与满队列分支](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gstreamer/plugins/elements/gstqueue.c#L1262)

## 复现同一个慢分支的三种策略

先启用 [WSL GStreamer 环境](./gstreamer.md#local-runtime)，在仓库根目录执行。可<a :href="exampleFile" download="gst-queue-demo.sh">下载 gst-queue-demo.sh</a>。慢支在 `identity` 每处理一帧休眠 40 ms，队列只保留三帧的上限。非 live 源按吞吐尽快推入，30/1 是时间戳的节拍，便于在很短时间内反复看见拥塞。

~~~bash
bash learning-site/examples/gst-queue-demo.sh
~~~

| 慢支 leaky | 预览样本 | 慢支样本 offset | 整条管线运行耗时 |
| --- | --- | --- | --- |
| no | 18 | 0–17，共 18 | 约 0.73 s |
| upstream | 18 | 0、1、2、3 | 约 0.13 s |
| downstream | 18 | 0、15、16、17 | 约 0.13 s |

每次都等到 EOS。实验按合成源 buffer offset 去重和计数。属性通知可能重复显示同一个值，thread 调度也会改变慢支具体保留的首帧和数量。只看耗时看不出丢的是哪一段；offset 说明 upstream 更倾向保留旧待处理帧，downstream 更倾向保留尾部。阻塞时预览仍最终收齐 18 帧。日志计时显示预览队列末帧约在 0.57 秒出队，两种丢弃策略下约在 0.05 秒出队。后者表示预览更早拿到最后一帧。

日志目录中每份 `*.queue.log` 同时记录相邻两侧的时间位置与各线程。对比 `<slowq> sink position updated` 和 `src position updated`，能看到两侧最后处理的媒体位置。要测精确的单帧排队耗时，需要对同一个 offset 记录进入和离开时的单调时钟。这套实验模拟消费者变慢，板端吞吐、显示延时和池上限要以后用真实硬件定量。

## 为每种用途设计受压时的行为

- **预览**　先明确目标是显示最新画面。可配小队列、丢旧帧，使用 PTS 计算帧龄并跟进丢帧计数。
- **主录像**　先确定允许短时阻塞多久，文件须有序排空。持续过载时明确告警、停录或降规格，保留受影响片段的时间范围。若要丢已编码数据，先检查 GOP 依赖及后续是否能从关键帧恢复。
- **备录像**　共用主码流时，慢备盘可以被限制在独立文件分支。若主备每一路都要求无缺口，应把持续写入能力和独立故障域纳入验收。
- **拍照**　短时取得需要的帧引用，编码或慢磁盘另行处理。持续持有源帧会占用有限池容量。

动态撤掉录制分支时，先在受控的 pad 阻塞点禁止新帧进入，再让已入队数据经编码和封装排空。收到分支收尾证据后解绑、释放 request pad 与引用。把 queue 的 `flush-on-eos` 设为 true 能更快结束，但待写帧会被放弃。正常录制与紧急中止可采用不同顺序，并各自验证输出尾部。

## 本节复盘

1. **每支有 queue，为何仍能拖住共享源？** queue 的线程能吸收短时速度差。持续过载触到不丢帧的上限后，push 阻塞并沿 tee 反传。
2. **三个队列帧是不是设备只占三个槽？** 还可能有正在处理、被别的支路持有或临时复制的帧。由缓冲引用和底层池的实际占用判断。
3. **看到 EOS 而且耗时变短，录像能交付吗？** 查收到哪些帧、GOP 依赖、封装尾部以及解码验证，才知道发生了什么。

应用的分流策略能在宿主复现。下一节读 Rockchip 的模块、通道、绑定和编码包，看看硬件分支怎样接。 [6.5 Rockchip VI、VPSS、VENC 与 MPP](./rockchip-media.md)
