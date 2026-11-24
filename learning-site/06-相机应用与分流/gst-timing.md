# 6.2 pipeline 状态、时钟、PTS 与 bus

<script setup>
import exampleFile from '../examples/gst-state-demo.sh?url'
</script>

向 pipeline 请求 PLAYING 后，可以马上断言有图吗？点击停止后，可以马上销毁 MP4 录制管线吗？这两件事都要等具体事件。本节先把状态、媒体时间和通知拆开，再用一台普通 WSL 主机复现。

## 状态是谁在变

| 状态 | 此时可以发生的事 | 相机应关注什么 |
| --- | --- | --- |
| NULL | 对象存在，运行资源已退回 | 构建失败或结束录制后，统一回到这里完成清理 |
| READY | 元素可打开设备、探测能力，尚未流式处理 | 节点错误、权限问题通常可在准备阶段显现 |
| PAUSED | pad 激活，非 live 链路可以送首个缓冲或 EOS 给 sink 完成 preroll | live 源在 PAUSED 不生产缓冲，状态转换可返回 NO_PREROLL |
| PLAYING | live 源开始产出，sink 可按 pipeline 的时钟调度 | 首帧应由样本到达、出队日志或显示事件证明 |

`gst_element_set_state(pipeline, GST_STATE_PLAYING)` 发出请求。需要经过中间状态时由框架推进。返回 ASYNC 表示还有工作，返回 NO_PREROLL 是 live 源的一种正常情况。对非 live 文件源，sink 持有首帧能让后续播放从已准备的数据开始。对 live 相机，等 PAUSED 中的首帧再决定是否进 PLAYING，会把应用逻辑卡在相机尚不产出的阶段。 [GStreamer 状态及返回值](https://gstreamer.freedesktop.org/documentation/additional/design/states.html)

收到 `STATE_CHANGED` 时先核对消息来源。一个 bin 有多个元素，它们各自都发状态消息。用于更新整条管线的状态指示时，应挑 `GST_MESSAGE_SRC(message) == GST_OBJECT(pipeline)`；要定位某个子元素的失败时保留它自己的状态和错误。状态日志会出现 pending state，表示这一转换过程中还有目标待完成。

## 三条时间轴怎样对齐

1. **时钟时间**是 `gst_clock_get_time()` 返回的绝对读数，原点由 clock 实现决定。
2. **管线 running time** 在 PLAYING 时由 `clock_time − base_time` 得出，暂停期间保持之前的进度。pipe 进入 PLAYING 时要在这一轮时钟上重新安排共同基准。
3. **缓冲的媒体时间**由 `GstBuffer` 的 PTS/DTS 给出。PTS 是预期呈现顺序与时间，DTS 用于解码顺序，带重排的视频可能不同。原始帧的 DTS 也可能无值。sink 用当前 `GstSegment` 将 PTS 转成该缓冲应被呈现的 running time。

~~~text
clock_time ── 减 base_time ───────────────→ 当前 running time
PTS ── 按 SEGMENT 的范围、基准与速率换算 ──→ 缓冲目标 running time
~~~

初始 segment 从零开始且正常速率为 1 时，原始视频的 PTS 往往直接等于目标 running time。跳转后两者可能不同。例如速率为 1、正向、offset 为 0、segment.start 为 10 秒且 segment.base 为 0 时，PTS=10.1 秒对应 running time=0.1 秒。如果直接拿 10.1 秒跟当前时钟减 base_time 的结果比较，就多等了十秒。

看 1.24.2 的实现，pipeline 在 PAUSED → PLAYING 为顶层管线挑选或复用 clock，在有效时间下算基准。

~~~c
GstClockTime new_base_time = now - start_time + delay;
~~~

这里的 `start_time` 保存希望续播的 running time，`delay` 是 pipeline 设置的额外启动延后。随后调用 `gst_element_set_base_time()`。在 BaseSink 的等待函数里，`sync=false` 会提前跳过时钟等待。同步路径先把用于调度的时间换回绝对时钟坐标，随后等待相应 clock id。调度还可能包含 pipeline latency 与 sink 偏移，因此分析预览延迟时应保留这些参数。 [pipeline 的基准计算](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gstreamer/gst/gstpipeline.c#L493) · [BaseSink 时钟等待](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gstreamer/libs/gst/base/gstbasesink.c#L2334) · [时钟与 segment](https://gstreamer.freedesktop.org/documentation/application-development/advanced/clocks.html)

## 用相同数据验证时钟等待

在 WSL 仓库根目录执行，先用[运行环境](./gstreamer.md#local-runtime)确认 `gst-launch-1.0`。可<a :href="exampleFile" download="gst-state-demo.sh">下载 gst-state-demo.sh</a>。

~~~bash
bash learning-site/examples/gst-state-demo.sh
~~~

脚本用 `gst-launch-1.0 -m` 保存 bus 消息。对照两份非 live 日志，它们都产出 5 帧、格式都声明 10 fps。时钟开关是唯一区别。

| 日志 | WSL 本轮观察 | 推断依据 |
| --- | --- | --- |
| sync.log | preroll、EOS，执行约 0.51 秒 | sink 随时钟调度，结束时间可能包含最后一帧呈现时长 |
| fast.log | preroll、EOS，执行约 0.0007 秒 | sink 无需等呈现时刻，文件式合成源可连续推数据 |
| live.log | 报 `does not need PREROLL`，随后进入 PLAYING 并到 EOS | live 源在 PAUSED 不产数据，这条链仍可以进入播放 |
| error.log | filesrc 报 `Resource not found` | 源文件错误能在启动时被报告，定位到 filesrc |

工具可能先打印 live 不需要 preroll，之后又打印通用的 `Pipeline is PREROLLED`。判断依据是 live 的转换返回及实际样本何时出现。上述耗时是工具本轮报告，随主机负载或版本变化。若要观察原始帧的 PTS，在[下一节的 C 实验](./gst-appsink.md#sample-timing)中比较同一 30 fps 源的三条记录。

## 记录停止为什么要分 EOS 和 ERROR

| 事件或消息 | 方向 | 谁负责 |
| --- | --- | --- |
| EOS event | 沿 pad 往下游 | 源已经发完，或者应用主动要求有序停录，muxer 结束已进来的数据 |
| EOS message | 发往 bus | pipeline 通常等各 sink 都结束，再向应用报告整条流结束 |
| ERROR message | 发往 bus | 出错元素提供来源和错误，由应用决定停机或恢复 |

录制时停止接收新数据，按拓扑让录制支路收到 EOS，继续排空编码器及 muxer；确认目标文件能读到尾部后回收资源。PLAYING 直接切 NULL 可以满足立即丢弃预览的需求，未完成的普通 MP4 则可能缺少收尾结构。整条 pipeline 的 EOS 等待所有 sink。若用户只停一个录制分支而预览继续，就需要确认这条分支的收尾信号，不能一直等整条 pipeline 的 EOS。响应 ERROR 时保留第一条带元素名称的错误，设置 NULL，再释放引用。 [事件流转](https://gstreamer.freedesktop.org/documentation/additional/design/events.html) · [bus 与消息](https://gstreamer.freedesktop.org/documentation/application-development/basics/bus.html)

## 本节复盘

1. **申请 PLAYING 后怎样证明收到第一帧？** 状态消息是控制路径证据。用实际 DQBUF、appsink 样本或 sink 显示观察确认数据路径。
2. **为什么关掉 sync 后很快结束，PTS 仍有固定间隔？** 时钟等待发生在 sink。生成时赋予帧的媒体时间可以保持原值。
3. **正常停录与出错退出分别记录什么？** 正常路径确认 EOS 到达及文件可读性。出错路径保留最先报错的元素和原因，据资源状态收尾。

下一节将检查 appsink 拿到的缓冲能否延长 V4L2 槽位的寿命，以及怎样查看内存类型。 [6.3 v4l2src、appsink 与内存协商](./gst-appsink.md)
