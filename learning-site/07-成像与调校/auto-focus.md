# 7.7 自动对焦 AF 与镜头执行器

<script setup>
import exampleFile from '../examples/focus-metric-demo.awk?url'
</script>

先确认镜头里有可控执行器，再讨论 AF。只有图像节点和 lens-name，能记录模组和描述镜头，但没有给出能调位置的设备。

## 什么叫合焦，为什么可以用清晰度测量

焦距描述镜头的成像特性，对焦是让给定距离的物体在传感器面上形成清晰像。移动镜组会改变清晰距离，清晰范围还与光圈、放大倍率和容许模糊有关。对比度 AF 用 ROI 内高频或梯度指标寻找峰值。比如对一排像素求相邻灰度差的平方和，清晰边缘通常给出更大的值。

纯色墙几乎没有梯度，任何位置分数都小。低光噪声、锐化过强和运动也可能提高或改变分数。AF 需要判断峰值是否显著，拒绝参数变化、移动目标和重复纹理制造的假峰。PDAF 可以使用相位差给出失焦方向的线索，要求 sensor/ISP 提供有效的相位统计和标定。有 PDAF 节点名只说明拓扑接口存在，仍要检查数据和模组能力。

## 先列出四层硬件能力证据

| 可观测层 | 需要的证据 |
| --- | --- |
| 模组实物 | 镜头料号、定焦或可动镜组、是否有 VCM 及接线与电源 |
| 设备树 | 执行器节点、地址、供应资源及 sensor 对镜头的引用 |
| 内核运行 | 执行器驱动成功 probe 与 lens entity，支持枚举位置控件 |
| 光学响应 | 同场景移动镜头时出现可复现的位置与清晰度曲线 |

固定焦点的模组可在对焦距离附近成清晰像。可手调的镜头也可以移动焦平面，但由人改变。可控执行器则还必须有驱动和标定，含位置方向、有效范围和移动后等待。

### sensor 怎样关联执行器

IMX415 通过 `v4l2_async_register_subdev_sensor()` 注册。V4L2 解析 sensor 的 fwnode 附属引用时，`lens-focus` 会交给异步框架匹配镜头子设备。

~~~c
{ "lens-focus", NULL, 0 },
~~~

这个字段应来自实际 actuator 与模块配置。 `rockchip,camera-module-lens-name` 则可参与模块信息和 IQ 文件名匹配。看到字符串 `default` 无法知道 I2C 总线上执行器是什么、有没有供电或是否绑定。

源码摘录 `kernel-6.1/drivers/media/v4l2-core/v4l2-fwnode.c:1262–1267`

~~~c
	{ "lens-focus", NULL, 0 },
};
unsigned int i;

for (i = 0; i < ARRAY_SIZE(props); i++) {
	int ret;
~~~

### 执行器驱动接受什么

以本地 SDK 的 DW9714 为跟读例。驱动注册 `MEDIA_ENT_F_LENS`，创建 `V4L2_CID_FOCUS_ABSOLUTE` 控件，逻辑位置接受 0 到 `max_logicalpos`。 `dw9714_set_pos()` 将逻辑位置映射到 DAC 并发 I2C。这个刻度由该驱动定义，不表示实际毫米值。

~~~c
ret = dw9714_set_pos(dev_vcm, dest_pos);
~~~

驱动按移动级差或模式计算移动时间，写成功和机械镜组已经稳定是两次事件。应用应核对控件值域、更新时间和影像结果。部分马达只能读到设定的 DAC 或驱动内位置记录，进一步的光学确认凭拍到的图。以上是可跟读的通用执行器驱动，当前板上尚未证实使用 DW9714。 [V4L2 对焦控件](https://docs.kernel.org/6.1/userspace-api/media/v4l/ext-ctrls-camera.html)

源码摘录 `kernel-6.1/drivers/media/i2c/dw9714.c:594–599`

~~~c
if (ctrl->id == V4L2_CID_FOCUS_ABSOLUTE) {
	if (dest_pos > dev_vcm->max_logicalpos) {
		dev_err(&client->dev,
			"%s dest_pos is error. %d > %d\n",
			__func__, dest_pos, dev_vcm->max_logicalpos);
		return -EINVAL;
~~~

## 用离线靶标模拟搜索、迟滞和拒答

对比度搜索可先全范围粗扫，再在最佳候选附近细扫。每步到位后丢掉移动期间的帧，选多帧中位数。正反各扫一次，若最佳位置有差异，可固定最终接近方向，避免机械迟滞；实际是否需要由数据决定。持续 AF 则在确认主体或清晰度趋势变化后再重新搜索，避免每帧来回寻峰。

在 WSL 仓库根目录执行。可<a :href="exampleFile" download="focus-metric-demo.awk">下载 focus-metric-demo.awk</a>。它用一维黑白靶标模拟不同失焦程度，并输出每个位置的梯度平方和。往返方向的峰位差由模型预设，验证测量可以检出这种迟滞。

~~~bash
mkdir -p output
lab=$(mktemp -d "$PWD/output/focus-metric.XXXXXX")
LC_ALL=C awk -v trace="$lab/sweep.tsv" -f learning-site/examples/focus-metric-demo.awk
head "$lab/sweep.tsv"
~~~

| 用例 | 本轮结果 |
| --- | --- |
| 正扫 0→100 | 位置 60，分数 57600 |
| 反扫 100→0 | 位置 55，分数 57600 |
| 平坦 ROI | 峰谷差 0，拒绝宣称合焦 |

实拍时要固定靶标距离、ROI、照明、曝光和 ISP 锐化，记录位置控件、等待时间、帧号与稳定分数。测试两种距离与纹理不足场景。若没有可控镜头，也可以人工取得清晰/失焦图，验证指标而不向硬件写入位置。

## 本板当前能够确认到哪里

审计已编译的候选 DTB 和原厂历史拓扑。在 WSL 执行下面命令。候选 DTB 的 `imx415_0@1a` 显示 lens-name 为 default，没有 `lens-focus` 引用。历史 media-ctl 未出现本模组的 lens 实体或已知 VCM。需要模组规格、原理图与当前系统查询才能判断硬件可控能力。

~~~bash
base=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
dtb="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
"$base/scripts/dtc/dtc" -q -I dtb -O dts "$dtb" |
  awk '/imx415_0@1a \{/ { sensor=1 } sensor {print} sensor && /^\t\t};/ { exit }'
rg -ni 'subtype lens|function lens|dw97|dw98|vcm|focus_absolute' output/camera-check/isp-before.log
~~~

最后的 grep 在当前历史记录下预期无匹配，返回码 1。若现场确有执行器，先用 `media-ctl -p` 找关联实体，再对那个 lens subdev 运行 `v4l2-ctl --list-ctrls` 做只读核对。可控范围和控制归属明确后才开始位置扫描。

## 本节复盘

1. **lens-name=default 能证明 AF 吗？** 它是模组描述的一部分。还要查执行器实物、DTS 引用、驱动能力与真实光学响应。
2. **位置设置成功后为什么还要等待？** I2C 写入完成、机械移动稳定和采集到对应帧是不同事件。
3. **纹理少时怎样处理最大分数？** 先看峰谷差和跨帧稳定度。缺少置信度时保持原位或选择可靠目标重试。

下一节讨论多曝光 HDR。通过多个曝光保住亮暗细节时，跨曝光的运动也会改变图像。 [7.8 多曝光 HDR 与运动伪影](./hdr-exposure.md)
