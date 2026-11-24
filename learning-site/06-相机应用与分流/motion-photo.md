# 6.8 快门前后缓存与动态照片

<script setup>
import experimentFile from '../examples/gst-motion-photo-demo.sh?url'
import remuxFile from '../examples/gst-motion-remux.c?url'
</script>

照片已经有了，为什么再打开录像只能得到按下快门之后的画面？在触发之前就需要一个有限的滚动窗口。按下的一刻要锁定封面时间，并且保存能从正确参考点独立解码的视频。

## 从请求时间找窗口和随机访问点

设快门选择的源帧时间为 T，要求保留 `pre` 秒之前到 `post` 秒之后。编码环内每项至少记录访问单元、源帧标识、PTS、DTS、duration 和是否为可用随机访问点。收到请求的顺序如下。

1. 把请求时钟对到源帧时钟，按策略确定封面帧 T。用该序号关联 JPEG 与录像。
2. 在缓存中找到不晚于 `T−pre` 的最近可用访问点。参数集或轨道配置也要随片段可用。距目标起点过远时可以保留更长前缀，或重编码起点所在的 GOP。后一种方案多用一次编解码。
3. 给已选片段持引用，继续收后半段直到 `T+post`。同时要限制并发快门数量和每个任务的内存。
4. 从访问点开始重建文件时间轴，保留 decode order 和显示关系。封面在短片内的时刻是 `T−clip_start`。封装收尾并可独立解码之后再发布文件。

~~~text
源时间       2.0 s   2.2 s          3.2 s           4.2 s
             关键帧   请求的前沿       封面 / 快门        请求的末端
短片时间      0 s                    1.2 s           2.2 s
~~~

环形缓存按编码数据设计，估算用 `码率 × (窗口时长 + 最多等一个 GOP 的余量) / 8`。例如 8 Mbit/s、按下前 1.5 秒、后 1.5 秒、GOP 余量 1 秒，平均约 4 MB。实际还要考虑瞬时码率、参数集、对象开销和并发快门，给字节与时间分别设上限。淘汰旧数据尽量以完整 GOP 为单位，遇到缺少可用起点、源重启或新的格式应标记窗口不连续。

## 裸码流有访问单元，封装还要时间

WSL 实验从同一合成源生成 60 帧，将闭合 GOP 的 AVC 逐 AU 保存，同时按源帧生成 JPEG。离线文件模拟环形缓存里已有的项。脚本从日志找不晚于第 22 帧的关键帧，选第 20 帧起包，并等模拟后半段到第 42 帧。封面用源 PTS 为 3.2 秒的第 32 帧。

直接拼这些 Annex B 单元后经 filesrc、parser 交给 mp4mux，第一次试验收到 `Buffer has no PTS`。裸字节仍有可解码的 NAL 单元，先前 `GstBuffer` 的时间戳没有随文件保存。因此实验用独立 C 程序通过 appsrc 逐个提交，并为固定 10 fps 的受控样本重新填时间。

~~~c
GST_BUFFER_PTS(buffer) = (index - start) * (GST_SECOND / 10);
GST_BUFFER_DTS(buffer) = GST_BUFFER_PTS(buffer);
GST_BUFFER_DURATION(buffer) = GST_SECOND / 10;
~~~

每个包从本段第一个访问单元开始数，100 ms 增长。实验禁用了 B 帧并保持固定帧率，允许 DTS 等于 PTS。真实流应保存原始两组时间与 segment，裁切时按同一参考做时间变换并保留重排关系。只把要提交的帧按编号乘帧周期，会丢掉 VFR、缺帧和 B 帧的时间信息。封装程序发送 EOS 并等 bus 消息后退出。 [GStreamer appsrc 的缓冲输入](https://gstreamer.freedesktop.org/documentation/app/appsrc.html)

## 动态 JPG 的文件结构与相册识别

Android Motion Photo 1.0 的 JPEG 路径在 JPEG 中放标准 XMP，其中 Camera 字段描述动态标志、版本与封面对应的视频呈现时间，Container 目录描述两项资源。第一项是 `image/jpeg, Primary`，第二项是 `video/mp4, MotionPhoto`。第二项的 `Item:Length` 为尾部 MP4 的实际字节数。

~~~text
[ JPEG SOI | JFIF APP0 | XMP APP1 | 图像段与扫描数据 | EOI ][ MP4 ]
  0                                                  视频起点      EOF
~~~

从文件末尾回退 `Item:Length` 可找到视频起点。这个实验无 padding，起点的前两个字节应是 JPEG EOI。XMP APP1 长度按 JPEG 的大端 16 位字段写入，包含长度字段自身字节，不含 marker。 `Camera:MotionPhotoPresentationTimestampUs` 用微秒记录短片中的封面呈现时刻，实验为 1,200,000。文件名采用 `RV1126B_MP.jpg` 以符合规范的建议命名。单视频轨即可演示；音频和评分元数据轨可选。 [Android Motion Photo 1.0](https://developer.android.com/media/platform/motion-photo-format)

Apple Live Photo 在 PhotoKit 中使用配对照片和视频资源，相关联的标识、静帧时序以及目标系统导入都要验证。Android 单文件 Motion Photo 的尾部结构不能用来推断 iOS 相册识别。若目标设备指定为 iOS，使用 Apple 资源接口与测试环境验证配对导入。 [Apple PhotoKit 的 Live Photo](https://developer.apple.com/documentation/photos/phlivephoto)

## WSL 生成、拆回原视频和静图

先准备[编解码插件](./gstreamer.md#local-codecs)与 [C 构建环境](./gstreamer.md#local-build-env)，保留同一个 shell。在仓库根目录运行。完整示例可分别<a :href="experimentFile" download="gst-motion-photo-demo.sh">下载实验脚本</a>与<a :href="remuxFile" download="gst-motion-remux.c">下载 remux 程序</a>。

~~~bash
bash learning-site/examples/gst-motion-photo-demo.sh
~~~

| 检查 | 本轮结果 |
| --- | --- |
| 源帧与相对快门 | 起始 20、封面 32、结束 42，封面 PTS 对应 1.2 秒 |
| JPEG 与 XMP/视频边界 | 由尾部长度算出 MP4 起点 3058，前面两个字节为 JPEG EOI |
| 视频按目录取出 | MP4 有 17762 字节，与封装前交给打包器的 MP4 逐字节相同 |
| 解码 | 静态 JPEG 能解码；新解码器从 MP4 解出 23 帧，含 PTS 1.2 秒并到 EOS |

文件大小和视频偏移随编码器版本变化，判据是字节边界、完整解码及封面时刻一致。实验只解码和检查受控文件。手机验收仍需要指定相册版本，并分别确认静图能看、动态入口出现、片段在正确快门位置呈现。复制或编辑后再验证一次文件尾部，避免编辑器保留 XMP 却移除了视频。

## 本节复盘

1. **为什么选比 T−pre 更早的一帧？** 找完整 GOP 的起点给解码器真实参考。保留更早前缀后要把封面相对时刻重新计算。
2. **先拼视频字节再放进 MP4，为什么报无 PTS？** 裸字节中没有原始容器时间表及 GstBuffer 的时间信息。记录下时间再交给封装器。
3. **静态 JPEG 能看，为什么仍不能宣布手机动态相册兼容？** 还要核对格式语义、媒体长度、起点与封面时刻，并在目标相册看动态识别和播放。

卷六完成了应用接帧、分流、编码与动态文件的宿主路径。卷七回到曝光和感光问题，从一张图在传感器中怎样形成开始。 [7.1 光学、曝光、噪声与 Bayer 采样](../07-成像与调校/optics-exposure.md)
