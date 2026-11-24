# 7.4 RKAIQ、统计节点、参数节点与 IQ

<script setup>
import exampleFile from '../examples/rkaiq-media-map.awk?url'
</script>

同一颗 IMX415 能从 V4L2 出图，画面却会自动变亮或变色。先判断是谁在做测量与决策，再追它怎样把结果给 sensor 或 ISP。三个图像相关的 fd 在这条路上有不同职责。

## 服务怎样找到对应 sensor

`rkaiq_3A_server.cpp` 打开每个候选 media device，枚举 entity、pad 和 link，再按名字读取 ISP 子设备、图像主路径、参数与统计节点。它借主路径找与之绑定的 sensor entity。

~~~c
sensor_name = rk_aiq_uapi2_sysctl_getBindedSnsEntNmByVd(media_info->mainpath);
~~~

sensor entity 名包含模组索引、方向等信息，交给 RKAIQ 用于选上下文。历史 IMX415 是 `m00_b_imx415 3-001a`。若另一 ISP 没绑定可用传感器，服务应按实际枚举结果处理。video 编号会因驱动注册顺序变化，不能按历史号固定控制设备。

<Sdk id="rkaiq-media-discovery" />

## init、prepare、start 分别解决什么问题

| 步骤 | 该服务路径可看到的参数 | 关注的错误 |
| --- | --- | --- |
| init | sensor entity 名、IQ_PATH、回调等 | 找不到 sensor、IQ 路径或校准信息 |
| prepare | 图像尺寸与 `RK_AIQ_WORKING_MODE_NORMAL` | 运行模式、格式与算法资源没准备好 |
| start | 启动这个已准备的上下文 | 按状态与真实流事件检查是否开始处理 |

~~~c
media_info->aiq_ctx = rk_aiq_uapi2_sysctl_init(media_info->sensor_entity_name,
                                              IQ_PATH, NULL, NULL);
~~~

样例的 IQ_PATH 是 `/etc/iqfiles/`，prepare 展示的是这条启动分支。其源码还把框架对 stream status 的内建监听关闭，注明服务器自己监听事件。这说明这一服务可以把生命周期和视频开关协调起来。验证现场模式时应看实际启动程序、参数与日志，应用加载两个上下文同时操作同一个物理 sensor 和 ISP 参数队列会使结果难以解释。

<Sdk id="rkaiq" />

## 统计数据和应用图像走的是两条路

~~~mermaid
flowchart LR
    A["sensor 出第 n 帧"] --> B["ISP 处理"]
    B --> C["mainpath 图像 → 应用"]
    B --> D["statistics 元数据 → RKAIQ"]
    D --> E["AE、AWB、AF 等按需计算"]
    E --> F["sensor ctrl/专用接口"]
    E --> G["params 缓冲 → ISP"]
    F --> H["后续帧图像及统计"]
    G --> H
~~~

1. ISP 统计结构提供测量值和有效标记，用户态要先核对当前 meas_type 及配置的统计窗口。
2. RKAIQ 用统计、模式和当前参数求解。曝光、增益属于 sensor 控制；ISP 的白平衡增益、矩阵等属于 ISP 参数。对焦是否写入 lens 取决于硬件存在及控制路径。每种结果的提交和生效时机可以不同。
3. V35 的统计端有 `frame_id` 和 `params_id`，参数端按目标 `frame_id` 检查队列。记录某帧统计用的参数号，才能做跨帧 A/B 对齐。sensor 曝光和增益也可能有不同更新延迟，对应 IQ 的 `CISExpUpdate` 字段。SDK C 硬件层按线性或 HDR 读延迟配置，不能只截一个返回值推断开始生效的帧。

<Sdk id="rkaiq-exposure-delay" />

## IQ 文件从哪里选，模组换了怎么核对

SDK 的 C 接口通过 sensor 名找到模块信息，读取 sensor、module 和 lens 三个字符串选文件。在自动选取分支可见 `sensor_module_lens.json` 形式。调用方预置文件、环境参数以及工作模式可能改变实际路径。比如源树中的 `imx415_default_default.json` 是一个指向 `imx415_ATKMC_V1_5.json` 的符号链接。下载一个其他 ISP 或镜头的同 sensor 文件，不能自动匹配噪声、镜头阴影、AWB 聚类和曝光时序。

换镜头或模组时，核对实物料号 → 设备树 module/lens 属性 → 驱动回报 → 运行库/ISP 版本 → 选中的路径与版本 → 画质 A/B 各步。最后记录从启动日志得到的实际文件名，方便回溯。源树中出现候选文件或默认链接只能说明构建素材，镜像也可能选择不同打包路径。

<Sdk id="rkaiq-iq-selection" />

## 复核原厂运行时的三个视频节点

在 WSL 仓库根目录执行。专家调试常常按目标实体选设备，脚本也只从 entity 标题下读 devnode。可<a :href="exampleFile" download="rkaiq-media-map.awk">下载 rkaiq-media-map.awk</a>。

~~~bash
awk -f learning-site/examples/rkaiq-media-map.awk output/camera-check/isp-before.log
aiq=atk_dlrv1126b_linux6.1_sdk/external/camera_engine_rkaiq
readlink "$aiq/rkaiq/iqfiles/isp35/common/imx415_default_default.json"
~~~

| 历史记录 | 数据含义 | 用户态角色 |
| --- | --- | --- |
| `/dev/video23`，mainpath | 图像 | 应用读取 ISP 输出的 NV12 |
| `/dev/video28`，statistics | ISP 统计数据 | RKAIQ 采集 |
| `/dev/video29`，input-params | 待写入 ISP 的参数 | RKAIQ 提交 |
| `/dev/v4l-subdev6`，isp-subdev | ISP 子设备 | 查看或配置 pad 格式与图像管线 |

历史记录确立的是该版拓扑与服务相关 fd。目标可连时先用 ADB 查 `media-ctl -p`、`ps`，再对服务进程查看 `/proc/<PID>/fd` 和实际 IQ 加载日志。既有 3A 服务保留。若从应用写曝光返回成功，稍后值改变，先看新值是否被驱动实际写入过，再看之后谁写了什么，而后匹配 SOF、stats、图像时戳。若第一笔 ioctl 返回失败，则先查值域、模式及错误码。成功和失败的两条时序都要保留。

## 本节复盘

1. **mainpath、statistics 和 params 三个节点方向如何区分？** mainpath 向应用给图像，statistics 向算法给测量元数据，params 接收用户态传给 ISP 的配置。
2. **看见一个 imx415 的 IQ 文件就能迁移吗？** 核对模组、镜头、ISP 版本、工作模式和运行态加载记录。图像变更要在同场景验收。
3. **为何手动设置曝光可能会被改回？** 先区分底层写失败、尚未生效和 3A 后续刷新。把 ioctl、readback、帧号和画面变化对齐。

下一节只分析 AE，把曝光时间、增益、测光区域和帧率放在同一个反馈环里。 [7.5 自动曝光 AE](./auto-exposure.md)
