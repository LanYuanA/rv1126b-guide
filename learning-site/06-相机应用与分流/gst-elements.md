# 6.1 GStreamer 元素、pad 与 caps

<script setup>
import exampleFile from '../examples/gst-caps-demo.sh?url'
</script>

手写采帧程序把收到的 NV12 写到磁盘。如果再接一个只接受 RGB 的处理模块，双方怎样知道能不能直接连？GStreamer 把处理封装成 element，把接口建模为 pad，用 caps 描述接口支持或正在传输的媒体类型。

## 从源到收尾，先画三个 element

~~~text
videotestsrc              capsfilter                fakesink
         src ──────────── sink    src ──────────── sink
合成并产生测试帧           约束允许的格式             接收后丢弃
~~~

元素可能有零个或多个 source/sink pad。方向从该元素本身看，上一元素的 `src` 连到下一元素的 `sink`。一个 bin 把一组元素作为容器管理，如果内部 pad 要给外部连接，通常通过 ghost pad 暴露。pipeline 是特殊的 bin，提供整条处理链的 bus 与时钟管理。画图时可以先把编码和封装框成一个 bin，再展开内部每条边。

三种常见 pad 生命周期（存在时机）各有用途。

| 类型 | 怎样出现 | 看哪个元素 |
| --- | --- | --- |
| Always | 元素创建时即可取得 | `videoconvert` 的 sink 与 src |
| Sometimes | 元素识别到数据内的流后才出现，应用常监听 `pad-added` | 解复用器不同媒体轨道的输出 |
| Request | 需要时从模板申请实例，拆分支时释放 request pad | `tee` 的 `src_%u` |

申请一个 tee 输出 pad，只是新增一个连接口。队列线程、缓冲引用和慢消费者的处理要在分流时独立设计。

## 看模板、查询结果和当前 caps

在装有 GStreamer 的 WSL 执行。当前工作区的工具可按[宿主环境设置](./gstreamer.md#local-runtime)启用。

~~~bash
gst-inspect-1.0 videotestsrc
gst-inspect-1.0 videoconvert
gst-inspect-1.0 tee
~~~

在 `Pad Templates` 中先找方向和存在条件，再看 caps。模板能列出范围或多个像素格式，表示可选边界。运行中还可以用 pad caps 查询结合对端和过滤条件得出可选集合。真正确定本段数据格式时，上游发出 CAPS 事件，下游按本次协商的具体格式处理。C 应用中 `gst_pad_query_caps()` 返回查询结果，`gst_pad_get_current_caps()` 读取当前 caps，还未协商时后者可返回空。 `ANY` 表示这一层未筛选格式，它仍需要遵守对端限制。 [GStreamer pad 与 caps 接口说明](https://gstreamer.freedesktop.org/documentation/tutorials/basic/media-formats-and-pad-capabilities.html)

~~~text
videotestsrc num-buffers=3 !
  video/x-raw,format=RGB,width=320,height=240,framerate=30/1 !
  fakesink sync=false
~~~

`!` 表示链接。中间写的 caps 是 `capsfilter` 的简写。`video/x-raw` 是未压缩的图像，`format=RGB` 再指定像素布局，尺寸和帧率继续缩小范围。H.264 是不同的媒体类型，需要编码元素来产生。上面的合成源有能力直接输出 RGB，进入滤镜前已是 RGB。指定格式只约束格式选择。 [GStreamer capsfilter 元素说明](https://gstreamer.freedesktop.org/documentation/coreelements/capsfilter.html)

把这条边接回相机时，还可能看到 caps features，例如 `video/x-raw(memory:DMABuf)`。两边即使都写 NV12，也要检查所用内存类型及布局是否能被下游导入。V4L2 的原始图像格式、GStreamer caps、每帧实际的缓冲元数据各自描述一层条件。

## 实验只改变一件事，验证是哪条边失败

在仓库根目录执行。独立脚本保留三次运行的详细日志，文件都在本地 `output/gst-caps.*`。可<a :href="exampleFile" download="gst-caps-demo.sh">下载 gst-caps-demo.sh</a>。

~~~bash
bash learning-site/examples/gst-caps-demo.sh
~~~

| 步骤 | 条件 | 本轮 WSL 观察 |
| --- | --- | --- |
| 1 | 源约束为 RGB，空 sink 接收 | `GstFakeSink` 的 sink 报 RGB，收到 EOS |
| 2 | RGB filter 紧挨着 NV12 filter | 链接报 `could not link left to right` |
| 3 | 在两个约束之间加 `videoconvert` | convert 的 sink 为 RGB、src 为 NV12，收到 EOS |

第二步第一条有用错误指向 filter 之间的边。因为两张格式集合的交集为空，连接在处理任何像素前失败。第三步将互斥约束挪到转换器两侧，允许入口和出口协商为不同格式。log 的每条 `GstPad` 都能对应到图中的一个端口。固定尺寸和帧率后再改 format，便于把修复原因归到转换上。

如果报 `no element`，先检查插件和工具路径。如果 pipeline 已经开始但报 `not-negotiated`，去看出错元素前后的 caps、memory features 以及哪一边先拒绝格式。可以为当次命令增加 `GST_DEBUG=GST_CAPS:5`，保留首条失败附近的上下文。若是板端打算用 `v4l2src`，插件必须在板端重新查，实际 caps 也要由板端的节点、输出格式和内存模式重新决定。

## 本节复盘

1. **为什么同一个 sink pad 在模板中能列很多格式，却只有一条当前 caps？** 模板提供可选范围，当前 caps 记录这条边在此时约定的具体格式，协商可以随条件改变。
2. **RGB 与 NV12 都属于 raw video，为什么直接连接仍失败？** 这一条边的像素布局字段没有交集。插入具备两侧能力的转换器后，入口和出口可以各自协商。
3. **三帧跑完又收到 EOS，能推断出真实摄像头以 30 fps 输出吗？** 本次数据来自合成源，空 sink 关闭了时钟同步。30/1 写的是媒体格式，实时时间测量还需要源、时间戳与时钟。

下一节拆开 pipeline 的状态转换，解释 preroll、PTS、running time 和 EOS 属于哪些对象，以及怎样在应用中安全收尾。 [6.2 pipeline 状态、时钟、PTS 与 bus](./gst-timing.md)
