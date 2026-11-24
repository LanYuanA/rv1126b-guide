# 6.3 v4l2src、appsink 与内存协商

<script setup>
import exampleFile from '../examples/gst-appsink-demo.c?url'
</script>

把源从 `videotestsrc` 换成 `v4l2src` 后，C 应用仍可从 appsink 取样本，但哪些帧直接对应内核槽位，要看协商的缓冲池、I/O 模式和是否发生复制。先沿两端各走一遍，再把它们连起来。

## v4l2src 怎样复用卷五的 ioctl

~~~text
RV1126B 的 ISP mainpath
    │ V4L2 slot（内核队列）
    ▼
v4l2src / GstV4l2BufferPool
    │ GstBuffer（可能包装槽位，也可能经过复制）
    ▼
appsink 内部队列
    │ gst_app_sink_try_pull_sample()
    ▼
应用取得 GstSample → 处理 → gst_sample_unref()
~~~

| 手写单帧逻辑 | 在框架里查什么 |
| --- | --- |
| open、QUERYCAP、枚举设备现有能力 | v4l2src 的状态转换打开 `device` 指定节点，内部 V4L2 object 探测能力 |
| G_FMT / S_FMT 与选择模式 | source pad 和下游协商 caps。框架可能向设备提出新的格式，实际格式读协商结果 |
| 申请并映射 slot、开流 | allocation query 协商候选池、分配器及元数据，随后驱动对应的 pool 启动和管理 |
| poll 与 DQBUF | `gst_v4l2src_create()` 通过 pool 的 process 路径拿缓冲，分配器执行 DQBUF |
| QBUF 复用、STREAMOFF | 支持复用的采集 slot 随底层缓冲归还重新排队；整个源停流时由框架撤销活跃队列 |

跟读 1.24.2 的 `gst_v4l2src_create()`，它把实际取缓冲委托给 `gst_v4l2_buffer_pool_process()`。再找 `gst_v4l2_allocator_dqbuf` 中的 `VIDIOC_DQBUF`，这一步与卷五手写客户端取回 slot 的调用相同。归还时 `release_buffer` 清除 outstanding 标志并进入后续复用路径。若可用槽位低于特定阈值，源码还有先复制、再回收原缓冲的分支。引用放不下和实际每帧都复制要分别查。 [v4l2src 取帧与缓冲池](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2src.c#L1148) · [V4L2 池复制分支](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2bufferpool.c#L1948) · [分配器 DQBUF](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2allocator.c#L1320)

## caps 选出格式，allocation 决定如何交付

先比较相邻 pad 约定的媒体类型、NV12 等像素格式、分辨率和帧率。再查 caps features，例如 `memory:DMABuf`。然后沿 allocation query 查看池、分配器与支持的元数据，最终检查 actual buffer 的内存块与布局。一条协商日志只是这条边的证据。

| 模式 | 由谁提供缓冲 | 哪些条件要验 |
| --- | --- | --- |
| `mmap` | 采集驱动由 V4L2 MMAP 队列提供 | 能申请、映射和出队。驱动和插件可能因条件选择复制 |
| `dmabuf` | v4l2src 通过驱动导出采集缓冲 | 导出成功，邻接下游能使用相应 fd 的布局 |
| `dmabuf-import` | 采集端导入其他分配者提供的缓冲 | 采集端支持导入及 DMA 映射，供给方和双方格式约束一致 |

留意带 DMA-BUF 的格式还可能用 DRM fourcc 与 modifier 表达布局。即使名义像素格式相同，两端也得能解释同一组 plane、offset、stride 与 modifier，并遵守生产与消费同步。在某个 pad 验证 `gst_is_dmabuf_memory()` 为真能证明该处有 DMA-BUF 内存，端到端需同时确认下游导入的是同一底层存储、生命周期和同步正确，并跟踪中间池或转换器的复制分支。 [GStreamer DMA-BUF 协商](https://gstreamer.freedesktop.org/documentation/additional/design/dmabuf.html) · [v4l2src 模式](https://gstreamer.freedesktop.org/documentation/video4linux2/v4l2src.html)

## appsink 拿到的是样本引用

~~~c
GstBuffer *buffer = gst_sample_get_buffer(sample);
GstCaps *caps = gst_sample_get_caps(sample);
~~~

这里的 buffer 和 caps 是借用的。应用持有 sample 时可使用它们。要跨线程传递，交接对象引用或让接收方拥有一份引用。最后一次释放使池有机会复用原来的槽，其他消费者仍持引用时要继续等。若一条支路只看 PTS 或大小，直接访问元数据就够了。

~~~c
if (!gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ))
    return FALSE;
~~~

实验中先从 sample caps 形成 `GstVideoInfo`，再将 buffer 映射为 `GstVideoFrame`。逐 plane 读映射后的 stride，避免假设 `stride == width`。检查动态元数据存在时，映射按缓冲布局解释。这里的 Y 与 UV 是像素分量区域，`gst_buffer_n_memory()` 查的则是底层 `GstMemory` 块数。读完调用 `gst_video_frame_unmap()`，外层随后 unref sample。

应用拉得慢时，appsink 可以积压或反压。这个实验设置 `max-buffers=2`。默认满队列会阻塞相应数据流，直到应用取走样本或框架结束等待。已拉取但仍被应用缓存的样本不计入该队列，因此还要限制应用自己的持有量。对现场视频只保最新帧时，先检查目标版本支持的丢弃属性，再据分支需求设置。 [appsink 1.24.2 的入队与等待](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gst-plugins-base/gst-libs/gst/app/gstappsink.c#L1114)

<a id="sample-timing"></a>

## 宿主实验，记录三个样本与一条真实 ERROR 路径

本机需 GStreamer 开发头文件、链接库和 pkg-config。Ubuntu 的相应包为 `pkg-config`、`libgstreamer1.0-dev`、`libgstreamer-plugins-base1.0-dev`，运行插件见[宿主运行环境](./gstreamer.md#local-runtime)。本工作区另有[解包式构建环境](./gstreamer.md#local-build-env)，可在同一个终端配置 `gst_pc` 后执行。可<a :href="exampleFile" download="gst-appsink-demo.c">下载 gst-appsink-demo.c</a>。

~~~bash
mkdir -p output
cc -std=gnu11 -Wall -Wextra -Werror learning-site/examples/gst-appsink-demo.c \
  $("${gst_pc:-pkg-config}" --cflags --libs gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-allocators-1.0) \
  -o output/gst-appsink-demo
output/gst-appsink-demo
output/gst-appsink-demo --error
~~~

| 次序 | PTS | 大小 | Y/UV stride | 内存块 |
| --- | --- | --- | --- | --- |
| 1 | 0.000000000 s | 115200 | 320 / 320 | 1 块，DMA-BUF 数 0 |
| 2 | 0.033333333 s | 115200 | 320 / 320 | 同上 |
| 3 | 0.066666666 s | 115200 | 320 / 320 | 同上 |

本轮三个样本都能映射，最后收到 `bus EOS`。注入错误时，在第一帧后收到 `bus ERROR [failure]`，进程以失败退出。此反例会让 source 侧也可能继续报告派生错误，定位依据是先收到的注入点错误。sample 拉取有独立超时，拉不到缓冲时由 bus 或总截止时间判断结束原因。NV12 两个分量区域在此可以位于同一内存块，尺寸为 `320 × (240 + 120)`。

## 换成 RV1126B 前需要补齐哪些证据

先做只读检查，原厂主路径节点历史是 `/dev/video23`。以现场拓扑和当前节点为准。确认目标空闲后才执行有限采集。WSL 的 GStreamer 版本和能力不能用于推算板端插件。

~~~bash
adb devices -l
adb shell 'command -v gst-launch-1.0; command -v gst-inspect-1.0'
adb shell 'gst-inspect-1.0 v4l2src'
adb shell 'v4l2-ctl -d /dev/video23 --get-fmt-video'
~~~

现场满足条件时，可以先运行一条板端 mmap 管线。这里主动要求历史的宽、高和格式，保留 `-v` 输出核对两侧 pad，看到 EOS 后停。

~~~bash
adb shell 'gst-launch-1.0 -v v4l2src device=/dev/video23 io-mode=mmap num-buffers=30 ! video/x-raw,format=NV12,width=3840,height=2160 ! fakesink sync=false'
~~~

当前板端未在线，本轮只完成宿主合成源实验。如果现场报 `no element`，先检查镜像插件。如果报 `Device or resource busy`，核对谁占用队列。如果报 `not-negotiated`，先保留直到失败时最后一对有效 caps，再查 device 格式、memory features、pool 配置相容性。板端验证 DMA-BUF 时只改变这一段的 I/O 模式，明确检查导出与实际消费者导入两端。

## 本节复盘

1. **从 appsink 拿到 buffer 后还持有内核槽吗？** 要看 buffer 是否包装原池成员。若是，引用延长槽寿命，直到相关引用释放才可复用。若已经复制，原槽可更早回收。
2. **为什么设置 max-buffers=2，应用仍能积压很多帧？** 该值限制 appsink 队列，应用取出自己留存的引用要独立限制。
3. **一帧报告 `dmabuf=1`，还缺什么证据？** 检查下游导入同一底层存储、实际 layout 和同步，以及经过中间元素时是否复制。

下一节加多个消费者，沿每条边追踪谁持有这帧、哪条支路可能拖住其它消费者。 [6.4 tee、queue、背压与丢帧策略](./gst-queues.md)
