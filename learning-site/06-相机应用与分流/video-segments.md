# 6.6 H.264/H.265、GOP、封装与分段

<script setup>
import exampleFile from '../examples/gst-segment-demo.sh?url'
</script>

如果编码器每三秒才产生一次可随机访问的画面，按两秒切文件会发生什么？用相同的合成源，只改变 GOP 长度，再对每个文件重新启动解码器验收。

## 文件开始处为什么需要可随机访问点

H.264（AVC）和 H.265（HEVC）都会把图像划成区域编码，已经解码的图像可用作后续图像的预测参考。粗略读一段视频时，可先用三种画面理解依赖。

| 画面类型 | 主要特征 | 切段时的影响 |
| --- | --- | --- |
| I | 图像内部预测，无需另一画面来预测此图像 | 还要确认它对应的访问点及跨段参考关系 |
| P | 可参考先前已解码的图像 | 若引用前一段的参考图像，单独打开新段可能解码失败或花屏 |
| B | 可参考显示顺序前后两侧的图像，编码器也可允许某些 B 图像作参考 | 解码顺序可能和展示顺序不同 |

设显示顺序是 I0、B1、B2、P3。如果两个 B 图像都引用 P3，解码器需先取得 I0、P3，才能解 B1、B2。容器用 DTS 排解码顺序，用 PTS 表示何时呈现。B 帧重排会影响缓存和低延迟目标，不能只凭包在文件里的排列去估计显示时间。6.2 里的 running time 还需要按 segment 换算。

GOP 是一组有依赖关系的图像。独立分段通常要求闭合 GOP，保证片段所需的图像参考都在片段内。H.264 的 IDR 会重置相关参考状态。HEVC 还区分 IDR、CRA 等随机访问点，CRA 要留意 leading pictures 的处理约束。普通 I 图像和编码器报告的“关键帧”都需要结合具体码流验证。重新打开解码器读每段，比只看标志更接近交付判据。

## 码流、parser 和容器分别交付什么

~~~text
NV12/I420 原始像素 → 编码器 → H.264/H.265 访问单元
                               ↓ parser
                       边界、流格式、参数集
                               ↓ muxer
                       MP4 或 MKV 文件与轨道
~~~

一个访问单元大致对应一张需要解码的图像及相关 NAL 单元。H.264 的 SPS/PPS 和 HEVC 的 VPS/SPS/PPS 传达解码需要的参数。封装时可能放入 track 的 decoder configuration，某些裸流或流式布局也会随访问单元携带参数集。VENC 返回的包长度只描述输出数据区。要得出容器文件，还要处理流格式、时间戳、轨道与收尾信息。

- `h264parse` 或 `h265parse` 显式处理码流的切分和对齐。GStreamer 可用 `alignment=au` 表示访问单元对齐。byte-stream 与带长度前缀的容器码流格式要按 muxer pad 要求协商。
- 普通 MP4 保存轨道、样本索引、计时等信息，录制结束时需让 muxer 正常收尾。Matroska 也具有独立的容器结构，streamable 模式与普通可寻址文件的索引策略不同。
- `splitmuxsink` 等待允许的 GOP 边界切段。配置的时间是阈值，不能凭它把有参考关系的帧切开。异步 finalize 可并行结束旧段，仍需跟踪旧段的收尾状态。

在 1.24.2 的视频输入路径中，`GST_BUFFER_FLAG_DELTA_UNIT` 用来判断该 buffer 是否依赖其它图像。标志未置位时记录 keyframe，并结合参考流的时间和 GOP 的采集状态推进。源端必须提供正确标志和独立分段所需的参数或轨道配置。 [splitmuxsink 源码](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gst-plugins-good/gst/multifile/gstsplitmuxsink.c#L3148) · [splitmuxsink 的闭合 GOP 要求](https://gstreamer.freedesktop.org/documentation/multifile/splitmuxsink.html) · [H.264 parser 的格式与对齐](https://gstreamer.freedesktop.org/documentation/videoparsersbad/h264parse.html)

## WSL 实测 2 秒阈值遇到 1 秒或 3 秒 GOP

先按[编解码插件环境](./gstreamer.md#local-codecs)检查工具。脚本以软件编码器生成 70 帧、10 fps 的测试图，禁用场景切换触发额外关键帧，配置闭合 GOP。三个用例的文件和输出各自保留。可<a :href="exampleFile" download="gst-segment-demo.sh">下载 gst-segment-demo.sh</a>。

~~~bash
bash learning-site/examples/gst-segment-demo.sh
~~~

| 编码与 GOP | 分段起点，沿源 running time | 逐段解码帧数 | 首段字节数 |
| --- | --- | --- | --- |
| AVC，10 帧 | 0、2、4、6 s | 20、20、20、10 | 162834 |
| AVC，30 帧 | 0、3、6 s | 30、30、10 | 240940 |
| HEVC，10 帧 | 0、2、4、6 s | 20、20、20、10 | 159136 |

大小记录随编码器版本和输入而变，不用于两种编码效率的比较。实验读取 `splitmuxsink-fragment-opened` 的 running time 作为全局起点，再在新解码管线里检查文件从零附近开始的本地 PTS、首个访问单元标志、EOS 和解码帧数。首段只看到自己时间从 0 开始，不能拿它判断该段在整个录制中位于哪里。三个用例各解出 70 帧。阈值 2 秒却得到 3 秒片段的对照，只改变了 AVC 的 GOP 长度。

如果第一段能播，第二段打不开，先查第二段首个访问单元是否为允许的随机访问点、解码所需参数集是否存在，以及 muxer 是否已完成轨道信息。再看每段的新解码器是否能到 EOS、是否少帧或有启动花屏。编码参数中 `send-keyframe-requests` 可让特定管线请求关键帧，实际效果取决于编码器是否遵循请求。板端 VENC 的 GOP 和分段仍需按实际码流验证。

段内媒体时长、muxer 完成时刻、文件增长以及真实持久化时刻属于不同观测。应用收到 fragment-closed 可以记录封装器的进度。按产品需要，再测文件 `fsync` 以及重命名后的目录持久化。存储延迟与顺序可回看 [3.11 页缓存与写回](../03-Linux内核/writeback.md) 和 [3.12 块层尾延迟](../03-Linux内核/block-io.md)。

## 本节复盘

1. **预计每 2 秒一个文件，为什么实际 3 秒？** 分段只能在可用 GOP 边界进行。先核对编码器最后实际产出的随机访问点，再看 muxer 的切段策略。
2. **开了 B 帧还可以按 PTS 排序后送解码器吗？** 解码需要先获得参考画面，按 DTS 或容器规定的解码顺序提交，呈现阶段再按 PTS 调度。
3. **有没有首个关键帧就能验收文件？** 还要有匹配的参数集及时间和容器信息，并用独立解码至 EOS 确认帧数和可见画面。

下面把已能解码的录像作为一条支路，和预览、第二录像、JPEG 共享一个源。 [6.7 单 sensor 的预览、主录、备录与拍照](./multistream.md)
