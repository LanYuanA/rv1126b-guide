# 从打开设备到取帧

- [5.10 RKISP 与视频设备节点](rkisp-video-node.md)
- [5.11 VB2 缓冲队列、DMA 与帧完成](vb2-queue.md)
- [5.12 独立实现 C 采帧与图像验证](capture-client.md)

## 用 v4l2-ctl 复查一帧

以下是**到这节再做**的主动实验。先核实输出路径未被业务占用并保留 3A。若占用，记录持有者后停在只读步骤。在板端有 `mktemp`、`timeout`、`v4l2-ctl` 且 mainpath 仍为 video23 的前提下，从 WSL 执行。使用新的临时目录以排除旧文件被误认为新帧。

~~~bash
adb shell 'v4l2-ctl -d /dev/video23 --get-fmt-video'
adb shell 'set -e; d=$(mktemp -d /tmp/frame.XXXXXX); echo "$d"; timeout -s INT -k 3 15 v4l2-ctl -d /dev/video23 --stream-mmap=3 --stream-skip=30 --stream-count=1 --stream-poll --stream-to="$d/one.nv12" --verbose; wc -c "$d/one.nv12"'
~~~

可以先离线看已有图和日志。若 WSL 有 ffplay，`ffplay -f rawvideo -pixel_format nv12 -video_size 3840x2160 output/camera-check/frame.nv12` 可预览；已有 `output/camera-check/preview.png` 也可直接打开。此命令假设紧排 stride 3840；颜色精确验证还需量化范围、矩阵和显示链。

历史实验中 buffer index 轮转 0、1、2，而 sequence 为 0 到 30；前 30 帧跳过，保存第 31 帧的 12,441,600 字节。首末单调 EOF 时间戳相差约一秒，`(31−1)/Δt ≈ 30 fps`。这证明一次短采集和可解释的帧布局。长时间稳定、首帧延迟和多路并发需要各自的实验。

想把表格变成自己的程序，接着读 [实作：编译完整的单帧客户端](capture-client.md)。这个程序直接操作 MPLANE API、映射驱动实际返回的长度，并在每一条失败路径释放已经取得的资源。

**本节复盘**　index 从 2 回到 0 是丢帧吗？index 是复用的槽位号。查 sequence、时间戳类型、ERROR 和驱动统计分析连续性。GStreamer 管线把用户态的格式协商、缓冲和线程连接起来。[GStreamer](../06-相机应用与分流/gstreamer.md)
