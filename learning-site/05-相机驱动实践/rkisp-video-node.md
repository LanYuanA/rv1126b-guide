# 5.10 RKISP 与视频设备节点

<script setup>
import exampleFile from '../examples/querycap.c?url'
</script>

打开 /dev/video23 时，会进入 sensor 的 open 吗？先从节点能力和媒体图确定它属于哪一路，再从 V4L2 通用入口跟到 RKISP 建立打开上下文的位置。

## 先分辨“能打开”和“能采集”

在 WSL 仓库根目录运行。这个程序只打开设备并查询能力。这里故意选 /dev/null，预期 open 成功，随后 VIDIOC_QUERYCAP 返回 ENOTTY，程序退出码为 1。<a :href="exampleFile" download="querycap.c">下载能力查询示例</a>。

~~~bash
mkdir -p output
cc -std=gnu11 -Wall -Wextra -Werror learning-site/examples/querycap.c -o output/querycap
rc=0
LC_ALL=C ./output/querycap /dev/null 2>output/querycap-null.log || rc=$?
test "$rc" -eq 1
rg '^VIDIOC_QUERYCAP: Inappropriate ioctl for device$' output/querycap-null.log
~~~

能力查询成功以后，若 capabilities 设有 V4L2_CAP_DEVICE_CAPS，按 device_caps 判定当前节点的角色。采集、元数据输入和元数据输出会用不同的能力与队列类型。不能依据 open 成功或设备名中的数字判断。

## 从实体名称定位历史节点

下面读原厂历史媒体图和格式。该次 mainpath 名称对应 /dev/video23。不同启动环境应根据实体和能力重定位。

~~~bash
awk -f learning-site/examples/isp-topology.awk output/camera-check/isp-before.log
rg 'Format Video Capture Multiplanar|Pixel Format|Number of planes' output/camera-check/isp-before.log
~~~

| 实体 | 数据方向 | 使用者 |
| --- | --- | --- |
| rkisp_mainpath | ISP → 图像应用 | 通过采集队列读取画面，历史格式为 MPLANE NV12，一个 memory plane |
| rkisp_selfpath | ISP → 另一输出队列 | 查看实际尺寸、格式和硬件可用性后使用 |
| rkisp-input-params | 应用 → ISP | 图像算法组件提交参数元数据 |
| rkisp-statistics | ISP → 应用 | 图像算法组件取得统计元数据 |

rkisp-vir0 代表一个逻辑 ISP 实例，图中不同输出与元数据节点围绕它组织。多个虚拟实例可能共享同一个物理 ISP。实体名称和媒体链接可定位职责，并发资源要按驱动和实测再判断。MPLANE 只表示多平面 API。历史 NV12 的一个内存 plane 同时容纳 Y 与交错 UV，两块颜色分量区域不会自动拆成两个 mmap。

## video_device 怎样接到 RKISP 这一份流？

`drivers/media/platform/rockchip/isp/capture.c:1881`

~~~c
vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE |
				V4L2_CAP_STREAMING;
video_set_drvdata(vdev, stream);
vdev->vfl_dir = VFL_DIR_RX;
node->pad.flags = MEDIA_PAD_FL_SINK;
vdev->queue = &node->buf_queue;
~~~

这个 video_device 挂到当前 stream、媒体 sink pad 和 VB2 队列。其 fops、ioctl_ops 在前面已经设置。注册时选择一个可用视频编号。V4L2 通用层在打开时查 video_device 并持有引用，然后调用节点自己的 fops。

`drivers/media/v4l2-core/v4l2-dev.c:425`

~~~c
if (vdev->fops->open) {
	if (video_is_registered(vdev))
		ret = vdev->fops->open(filp);
	else
		ret = -ENODEV;
}
~~~

此处当前视频节点的回调是 rkisp_fh_open。应用 ioctl 到 video_ioctl2，之后按命令分发给 ioctl 表。应用 open 的这个节点和 sensor subdev 的独立节点走各自的 fops。

## 打开上下文和管线引用怎样建立？

`drivers/media/platform/rockchip/isp/capture.c:1016`

~~~c
ret = v4l2_fh_open(filp);
if (!ret) {
	ret = v4l2_pipeline_pm_get(&stream->vnode.vdev.entity);
	if (ret < 0)
		vb2_fop_release(filp);
}
~~~

video_drvdata 取出前面保存在 video_device 的 stream。v4l2_fh_open 建立该次打开的上下文，随后管线 PM 取引用。失败会释放已建立的上下文。正常 release 再归还持有的 PM 引用。管线可能因引用发生电源动作。真正开始传输还需要格式配置、队列准备和开流。

~~~text
openat → VFS 字符节点 → v4l2_open → rkisp_fh_open
  → 建立当前 file 的 fh → 持有媒体管线 PM 引用
  → ioctl 分发到格式、控制或 VB2
  → 缓冲排队并启动 → 驱动才开始产生后续帧
~~~

板端当前未新开节点。本轮实测 /dev/null 的反例，并对照原厂历史和本地源码。

## 本节复盘

1. open 成功但 QUERYCAP 返回 ENOTTY，失败落在哪一层？
2. 同一个 ISP 的 mainpath、params、statistics 分别传什么，数据往哪走？
3. 为什么打开主路径可能取得电源引用，却没有一帧？哪一步才交给硬件可用的缓冲？
4. 开另一份 fd 与已有 fd 的关系该从哪两层查？

下一节跟一块空缓冲进入驱动、完成和归还。[5.11 VB2 缓冲队列、DMA 与帧完成](vb2-queue.md)
