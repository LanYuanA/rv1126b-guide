# 7.5 自动曝光 AE

<script setup>
import exampleFile from '../examples/ae-feedback-demo.awk?url'
</script>

灯突然变暗，画面第一帧先变暗。算法看到这帧之后才取得新的测量，又要过若干帧才看到自己调节的结果。如何让主体更快回到期望亮度，同时控制拖影、噪声和帧周期？

## 目标亮度取决于测光区域

AE 的输入可以包括窗口均值、直方图、亮部/暗部比例与曝光记录。全画面平均容易被窗户、路灯或大块反光背景主导。中心权重、指定 ROI 或跟踪主体的测光，能选择不同的妥协。亮部占比过高还要加约束，避免为了抬亮主体让整片高光溢出。

设背景比人脸亮两倍。人脸占四分之一时，整幅平均在目标 0.42，人脸仍可只有 0.24。改成只对人脸测光时，背景可能太亮。这是目标选择，实验要分别定义主体和背景的验收范围，再看动态变化。

## 一个亮度目标如何拆成曝光时间和增益

在未饱和的线性近似下，观测亮度随光强、积分时间和总倍率变化。AE 可以先把需要增亮的比例换成 EV，再查曝光策略分配为时间和增益。实板还要考虑以下约束。

- 积分时间受当前行时间、VTS、滚动快门和运动速度约束。运动与闪烁条件变化时，允许的曝光上限可小于帧周期。
- 模拟增益与数字增益都能抬高输出码值。曝光时间受限时可用增益，仍要检查暗部噪声、数值量化和高光余量。
- 某些光源在 50 Hz 电网下的强度重复周期约 10 ms，在 60 Hz 下约 8.33 ms。接近整周期的积分可减小明暗条纹。真正的周期要按光源驱动测量，PWM 或调光下不一定与电网一致。
- 如果产品必须保持 30 fps，AE 要在该 VTS 边界内找折衷。允许低光降帧率时，主动加大 VTS 应能从源周期观察到。

用 7.1 的约 14.814 µs 行时间估算，10 ms 约 675 行，8.33 ms 约 562 行。线数取整与量化曝光的误差要核对真实光源。

## 跟读从 RKAIQ 的曝光结果到 IMX415

本地 SDK 的 sensor 硬件层把算法结果拆成帧长、模拟增益码和粗积分行数，线性示例先更新 VBLANK，再提交曝光。VTS 决定一帧有哪些行，因此先更新控制范围，再写新的积分。

~~~c
ctrl.id    = V4L2_CID_VBLANK;
ctrl.value = frame_line_length - sensor_desc.sensor_output_height;
~~~

源码摘录 `external/camera_engine_rkaiq/rkaiq/hwi_c/aiq_sensorHw.c:74–79`

~~~c
memset(&ctrl, 0, sizeof(ctrl));
ctrl.id    = V4L2_CID_VBLANK;
ctrl.value = frame_line_length - sensor_desc.sensor_output_height;
if (AiqV4l2SubDevice_ioctl(pSnsHw->mSd, VIDIOC_S_CTRL, &ctrl) < 0) {
    LOGE_CAMHW_SUBM(SENSOR_SUBM, "cam%d failed to set vblank result(val: %d)",
                    pSnsHw->mCamPhyId, ctrl.value);
~~~

在 IMX415 的 `imx415_set_ctrl()`，修改 VBLANK 时先更新线性曝光上限。后续曝光控制把行数转换成 SHR0。运行时电源状态可以影响是否立即写寄存器，正常开流时框架还会把控件值应用到设备。S_CTRL 成功、读到寄存器、画面变化是不同时间点。 [7.1 曝光行时间和 readback](./optics-exposure.md)

~~~c
max = imx415->cur_mode->height + ctrl->val - 8;
~~~

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:2937–2942`

~~~c
case V4L2_CID_VBLANK:
	if (imx415->cur_mode->hdr_mode == NO_HDR) {
		/* Update max exposure while meeting expected vblanking */
		max = imx415->cur_mode->height + ctrl->val - 8;
		__v4l2_ctrl_modify_range(imx415->exposure,
				 imx415->exposure->minimum, max,
~~~

在保持同一行时间的线性模式里，若 VTS 从 2250 改为 2700，估算周期由 33.33 ms 变为 40.00 ms，即 30 fps 变为 25 fps。同步记录 sensor SOF 和应用 DQBUF 时戳，才能把期望周期与实际处理延迟分开。

## 复现阶跃、控制过冲与测光偏差

在仓库根目录执行 AWK 模型。帧 12 光照变为 1/4，提交的控制量经过两帧才生效。初始积分 4 ms，最多 8 ms，到上限后再加倍率。可<a :href="exampleFile" download="ae-feedback-demo.awk">下载 ae-feedback-demo.awk</a>。

~~~bash
mkdir -p output
lab=$(mktemp -d "$PWD/output/ae-feedback.XXXXXX")
LC_ALL=C awk -v trace="$lab/trace.tsv" -f learning-site/examples/ae-feedback-demo.awk
awk -F '\t' '$1 == "center-smooth" && $2 >= 11 && $2 <= 22' "$lab/trace.tsv"
~~~

收敛的操作定义是主体亮度进入目标 0.42 的 ±5%，并至少连续四帧。过冲取阶跃后出现的最高超出比例，以目标归一。模型记录每一帧**实际应用**的积分和倍率，以及新提议的排队乘数。

| 用例 | 进入容差带 | 过冲 | 最后一帧主体亮度 |
| --- | --- | --- | --- |
| 中心测光，温和响应 | 阶跃后第 7 帧 | 0.4% | 0.420 |
| 同区域，激进响应 | 60 帧窗口内没有 | 138.1% | 0.519 |
| 全画面式测光，温和响应 | 主体没有进入 | 0.0% | 0.240 |

温和路径帧 12、13 仍用原命令，亮度都约 0.105。帧 14 应用第一条新命令，积分到约 5.90 ms；帧 15 达到 8 ms 上限，才开始增益补偿。激进策略连续更新时依然看到旧控制的结果，导致几次调节叠加。全画面式测光将均值稳定到 0.42，主体依然欠曝。脚本用来观察延迟、取舍与指标，真实 RKAIQ 策略要按实际 IQ 和逐帧证据分析。

## 上板应该如何设计阶跃与丢帧对照

固定构图、光源、镜头和模式，仅在已知时刻改变照明。用灰卡或可重复的目标覆盖主体 ROI。试验记录请求变化时刻、源 SOF/sequence、统计的测光值和配置号，以及实际曝光、增益和 VTS。使用同一基准和一致采样窗口，定义稳定帧数、过冲、亮区饱和与最低画质要求。真实 AWB 和光源可能同时变化，必要时记录能否固定白平衡与 IQ。

| 现象 | 先核对 |
| --- | --- |
| SOF 间隔稳定变长，sequence 连续，VTS 同时上升 | 主动降低帧率 |
| SOF 周期稳定，采集 sequence 出现缺口 | 查接收、缓冲队列和下游负载，检查哪个阶段先跳号 |
| SOF 周期与 sequence 都稳定，只有用户态收到帧的间隔抖动 | 查调度、队列等待和应用时钟域 |
| 读回不变，但亮度来回跳 | 查光源闪烁、ISP 曲线或统计 ROI，再考虑控制不生效 |

本轮完成了宿主模型及源码跟读，未改动板端 3A。若实际固件没有逐帧曝光元数据，只能用图像与可见的时间证据给出假设，待日志或硬件观测再定位控制生效时刻。

## 本节复盘

1. **光照变暗后哪一帧能第一次看到新的曝光？** 当次测量要先到达算法，再排队给 sensor，并在硬件采用该控制的曝光后形成图像。需要真实帧号对齐。
2. **全局平均达标，为什么主体还是黑？** 亮背景的权重会抬高平均，测光目标应与用户关心的主体一致。
3. **如何区分 AE 降帧率和驱动丢帧？** 联合 SOF 周期、VTS、源及应用的 sequence 分析，定位周期变化起点或丢失层级。

下一节固定光和曝光变量，只改变光源色温或色偏，跟踪白点与通道增益。 [7.6 自动白平衡 AWB](./auto-white-balance.md)
