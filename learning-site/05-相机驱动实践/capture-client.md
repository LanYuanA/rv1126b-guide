# 5.12 独立实现 C 采帧与图像验证

<script setup>
import exampleFile from '../examples/one_frame.c?url'
import fixtureFile from '../examples/one-frame-fixture.c?url'
</script>

手上只有一个 `/dev/videoN` 时，先问四件事。节点能采集吗？协商的是哪种内存布局？哪一刻可以访问像素？写到磁盘的帧能按这个布局解释吗？本节客户端从驱动当前的格式开始，只启动一次有限采集。完整程序可<a :href="exampleFile" download="one_frame.c">下载 one_frame.c</a>。上一步的[VB2 生命周期](./vb2-queue.md)可以放在旁边对照。

~~~mermaid
flowchart LR
    A["open + QUERYCAP"] --> B["G_FMT 核对布局"]
    B --> C["REQBUFS → QUERYBUF → mmap → QBUF"]
    C --> D["STREAMON → poll → DQBUF"]
    D --> E["验证槽号、错误标志及载荷"]
    E --> F["读取或保存紧排 NV12"]
    F --> G["STREAMOFF → munmap → close"]
~~~

## 先判断节点，再读取正在使用的格式

程序以 `O_RDWR | O_NONBLOCK | O_CLOEXEC` 打开节点。非阻塞使 DQBUF 在暂时无帧时可以返回 EAGAIN。先读 `QUERYCAP`，下段选出实际节点的能力。ISP 有多个节点，整个设备支持某种能力不代表每个节点都支持它。

~~~c
unsigned int caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ?
    cap.device_caps : cap.capabilities;
~~~

检查 `V4L2_CAP_VIDEO_CAPTURE_MPLANE` 与 `V4L2_CAP_STREAMING` 后，调用 `G_FMT` 读取当前尺寸与格式。这个例子要求 FourCC 为 NV12 且 `num_planes == 1`。MPLANE 是 ioctl 的参数组织方式。NV12 的 Y 和交错 UV 能同处一个内存平面，NV12M 则分别用两个内存平面描述。即使二者都由亮度和色度两个图像分量区域组成，应用传给驱动的 plane 数组也不同。

| 布局信息 | 从哪里来 | 怎样使用 |
| --- | --- | --- |
| 可见宽、高 | `pix_mp.width/height` | NV12 每行有 width 字节有效数据，色度区行数是亮度区的一半 |
| 步长 | `plane_fmt[0].bytesperline` | 从一行首走到下一行首，可能包含填充 |
| 格式所需空间 | `plane_fmt[0].sizeimage` | 在请求缓冲前检查能否放下最后一行 |
| 映射长度 | `QUERYBUF` 的 plane.length | `mmap` 用它限制可访问地址 |
| 本帧起点与范围 | `DQBUF` 的 data_offset、bytesused | 有效区是 `[data_offset, bytesused)`，再按 stride 找像素 |

举个可以手算的例子。宽 4、高 2、stride 6 时有两行 Y、一行 UV，各行分别从偏移 0、6、12 开始，末行的第 4 个有效字节在偏移 15。源数据至少要覆盖 16 字节，按行只写 4 字节后文件只有 12 字节。原厂 3840×2160 的紧排文件应是 `3840 × (2160 + 1080) = 12,441,600` 字节。NV12 的色度顺序是 U、V。用 NV21 解释同一份文件则会交换二者。 [Linux 6.1 的 NV12 与 NV12M 布局](https://docs.kernel.org/6.1/userspace-api/media/v4l/pixfmt-yuv-planar.html)

## 映射长度和槽号由驱动返回

`REQBUFS` 请求三个槽，循环上限采用返回的 `req.count`。对每个槽从 `QUERYBUF` 得到长度及映射偏移。偏移是传给这个 fd 的映射参数。用户地址由 `mmap` 返回并留在 `maps[i]`，下次凭 index 找回。

~~~c
maps[i].size = p.length;
maps[i].ptr = mmap(NULL, p.length, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, p.m.mem_offset);
~~~

成功映射后才增加 `mapped`，接着 QBUF 把槽交给驱动。尚未 DQBUF 时，即使指针仍可解引用，设备也可能还在写。STREAMON 打开队列后，程序用单调时钟固定一个三秒截止点。每次唤醒或被信号打断都重新算剩余时间，避免重试把总等待不断拉长。

~~~c
if (ioctl(fd, VIDIOC_DQBUF, frame) == 0)
    return 0;
if (errno != EINTR && errno != EAGAIN)
    return -1;
~~~

poll 说明可以尝试 dequeue。若两步之间观察的状态发生变化，非阻塞 DQBUF 仍可能返回 EAGAIN。下一轮继续等，超过截止点按 ETIMEDOUT 结束。这个三秒只约束取帧等待，诸如写文件和驱动停流另有自己的耗时。

## 拿回缓冲后逐层检查边界

~~~c
if (frame.index >= mapped || (frame.flags & V4L2_BUF_FLAG_ERROR) ||
    plane.bytesused > maps[frame.index].size || plane.data_offset >= plane.bytesused ||
    plane.bytesused - plane.data_offset < needed) {
    fprintf(stderr, "错误帧或有效范围越界\n");
    goto finish;
}
~~~

短路求值保证 index 越界时不会访问映射表，`data_offset >= bytesused` 时不会做无符号减法。最后一项用上面例子里的末行范围核对有效载荷。检查通过后，`save_nv12` 用 `row × stride` 找每行的首地址，每行写 width 字节。目标文件已存在时报错并保留旧文件。写到一半失败时，程序清理本次创建的文件。

持续采集时，读完要 QBUF 让槽再利用。单帧模式直接 STREAMOFF。第三个 mmap 如果失败，`mapped` 仍记录已成功的两个，退出时逐个解除；STREAMON 前失败则跳过 STREAMOFF，最终 close 释放该 fd 的队列。若本版平台上的停流失败，程序记录错误和失败退出状态。

## 编译与复现

在 WSL 仓库根目录构建并验证 `/dev/null` 能打开，但 QUERYCAP 返回 ENOTTY。目标程序静态链接，避免依赖板端的动态加载器路径。

~~~bash
mkdir -p output
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
cross="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc"
cc -std=gnu11 -Wall -Wextra -Werror learning-site/examples/one_frame.c -o output/one-frame-host
"$cross" -std=gnu11 -Wall -Wextra -Werror -static learning-site/examples/one_frame.c -o output/one-frame-board
file output/one-frame-board
output/one-frame-host /dev/null
~~~

本轮宿主与 AArch64 编译通过。另用独立的<a :href="fixtureFile" download="one-frame-fixture.c">宿主模拟文件</a>替换 ioctl、poll、mmap、munmap。模拟首个 DQBUF 返回 EAGAIN，随后提供 2 字节起点偏移和行末填充。正常保存应得到 12 字节，短载荷用环境变量触发，应拒绝保存。

~~~bash
cc -std=gnu11 -Wall -Wextra -Werror learning-site/examples/{one_frame,one-frame-fixture}.c \
  -Wl,--wrap=ioctl,--wrap=poll,--wrap=mmap,--wrap=munmap -o output/one-frame-mock
lab=$(mktemp -d "$PWD/output/one-frame-mock.XXXXXX")
output/one-frame-mock /dev/null "$lab/frame.nv12"
od -An -tx1 "$lab/frame.nv12"
SHORT_FRAME=1 output/one-frame-mock /dev/null "$lab/bad.nv12"
test ! -e "$lab/bad.nv12"
~~~

本轮正常输出为 `01 02 03 04 05 06 07 08 09 0a 0b 0c`，短载荷报“错误帧或有效范围越界”。以相同输出路径再执行正常分支，程序报文件已存在，内容保持原样。真实驱动的 DMA、停流和图像验证需在板端采集时执行。

板端实操先用媒体实体和 `v4l2-ctl --get-fmt-video` 确认节点，再确认没有业务采集者、已有格式满足条件。以下用历史的 mainpath 节点举例，只有核对后仍是它才填 `/dev/video23`。测试目录和采集文件在结束后按需要留作证据。

~~~bash
adb devices -l
board_lab=$(adb shell 'mktemp -d /tmp/rv-one-frame.XXXXXX' | tr -d '\r')
test -n "$board_lab" &&
  adb push output/one-frame-board "$board_lab/one-frame" &&
  adb shell "chmod 700 '$board_lab/one-frame' && '$board_lab/one-frame' /dev/video23 '$board_lab/frame.nv12'" &&
  adb pull "$board_lab/frame.nv12" output/one-frame-new.nv12
~~~

## 字节数、外观和连续性分别验证

在 WSL 用原厂历史采集样本复现。若 GStreamer 工具缺失，先按[宿主环境设置](../06-相机应用与分流/gstreamer.md#local-runtime)配置当前 shell。生成 PNG 时必须给出 NV12 的实际宽高。若板端刚取到的是其他尺寸，按它报告的参数替换。

~~~bash
wc -c output/camera-check/frame.nv12
lab=$(mktemp -d "$PWD/output/nv12-preview.XXXXXX")
gst-launch-1.0 -q filesrc location=output/camera-check/frame.nv12 ! \
  rawvideoparse format=nv12 width=3840 height=2160 framerate=1/1 ! \
  videoscale ! 'video/x-raw,width=960,height=540' ! videoconvert ! \
  pngenc snapshot=true ! filesink location="$lab/preview.png"
file "$lab/preview.png"
bash learning-site/examples/frame-intervals.sh output/camera-check/capture.log
~~~

本轮历史样本为 12,441,600 字节，成功生成 960×540 PNG。打开图片时先用有方向的物体边缘找行错位，再用已知颜色确认 U/V 顺序。图像出现整体偏色，还要核对 limited/full range 和色彩矩阵。生成预览只说明能把字节解释成图像，色彩准确性需要在受控场景中比较。

31 次历史出队的时间戳跨度包含 30 个间隔，按 `(N−1)/(t_last−t_first)` 得到 30.000 fps，间隔 P95 为 33.377 ms。先确认 flags 标示的时钟和时间戳来源一致，再比较间隔。sequence 缺口能检查一定范围内的出队连续性。画面重复需要在运动场景比较帧内容，单帧程序不计算帧率。

## 本节复盘

1. **宽 4、高 2、stride 6，为什么有效载荷至少要 16 字节？** 三行开头分别为 0、6、12，最后一行要读到第 15 字节。保存时每行只拷 4 字节，共 12 字节。
2. **看到 `poll` 就绪后，哪个调用把内存槽交给用户？** DQBUF 成功才握有具体 index。接着检查 ERROR、data_offset、bytesused 和映射长度。
3. **拿到正确大小为什么仍会看到绿图或斜纹？** 解释文件还依赖步长、UV 顺序以及色彩参数。连续性还要收集时间戳、序号与可比的多帧内容。

单 fd 的职责已经清楚。下一节把取帧、格式转换及输出拆成可连接的元素，先用一个可控的合成源练习。 [6.1 GStreamer 元素、pad 与 caps](../06-相机应用与分流/gst-elements.md)
