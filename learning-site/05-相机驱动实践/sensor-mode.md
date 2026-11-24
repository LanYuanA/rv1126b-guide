# 5.4 寄存器表、模式、曝光与增益

<script setup>
import exampleFile from '../examples/imx415-linear-exposure.awk?url'
</script>

保持曝光为 1000 行，只把垂直消隐从 58 行增加到 100 行，传感器仍会写同一个曝光寄存器值吗？本节用本地 SDK 的第一项四 lane 线性模式，追踪格式选择、曝光换算和开流写表。

## 从模式表复算两个曝光值

在 WSL 仓库根目录运行。前两次查找分别核对模式的描述和 link frequency 菜单，再读原厂历史中第一路的开流请求。演算脚本只做算术。<a :href="exampleFile" download="imx415-linear-exposure.awk">下载曝光演算</a>。

~~~bash
f=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/drivers/media/i2c/imx415.c
rg -n -A24 '^static const struct imx415_mode supported_modes\[\]' "$f"
rg -n -A6 '^static const s64 link_freq_items\[\]' "$f"
rg 'imx415 3-001a: s_stream:' output/camera-check/dmesg-after.log
awk -f learning-site/examples/imx415-linear-exposure.awk
~~~

| 本项字段 | 值与单位 |
| --- | --- |
| sensor 有效区域和总线码 | 3864×2192，SGBRG10_1X10，GBRG Bayer 10 位 |
| max_fps | 存的是帧间隔 10000/300000 秒，因此标称 30 fps |
| 曝光布局与通道 | NO_HDR，PAD0 的 VC 为 0 |
| link frequency 和输入参考时钟 | 选菜单索引 1，446 MHz；该模式要求 XVCLK 为 37.125 MHz |
| 默认帧长与寄存器表 | VTS 0x08ca 即 2250 行，指向独立的全局表与模式表 |

原厂历史请求行也是 3864×2192、线性和 10 位。该日志并未打印完整的已选寄存器表，不能仅靠这三个字段断定具体是哪一项。应用随后得到的 3840×2160 NV12 属于 ISP 输出的另一层格式。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:1085–1090`

~~~c
static const struct imx415_mode supported_modes[] = {
	/*
	 * frame rate = 1 / (Vtt * 1H) = 1 / (VMAX * 1H)
	 * VMAX >= (PIX_VWIDTH / 2) + 46 = height + 46
	 */
	{
~~~

## TRY 怎样与 ACTIVE 分开？

`drivers/media/i2c/imx415.c:1499`

~~~c
mode = imx415_find_best_fit(imx415, fmt);
fmt->format.code = mode->bus_fmt;
fmt->format.width = mode->width;
fmt->format.height = mode->height;
fmt->format.field = V4L2_FIELD_NONE;
~~~

驱动先按模式集合选一个可用格式，并把实际尺寸和码回填给调用者。支持 subdev API 时，TRY 把结果放进传入的 pad 试探状态，供协商使用。ACTIVE 会更新实例的当前模式和空白区间、link frequency、pixel rate 等关联控制。核对格式时保留请求、返回与正确 pad 的 ACTIVE 读回。ACTIVE 更新和开流写表是两个阶段。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:1487–1492`

~~~c
static int imx415_set_fmt(struct v4l2_subdev *sd,
			  struct v4l2_subdev_state *sd_state,
			  struct v4l2_subdev_format *fmt)
{
	struct imx415 *imx415 = to_imx415(sd);
	const struct imx415_mode *mode;
~~~

## 帧长改变后，为什么要改曝光上限和 SHR0？

`drivers/media/i2c/imx415.c:2938`

~~~c
if (imx415->cur_mode->hdr_mode == NO_HDR) {
	/* Update max exposure while meeting expected vblanking */
	max = imx415->cur_mode->height + ctrl->val - 8;
~~~

在线性分支，VTS 等于有效高度加垂直消隐行数，最大曝光为 VTS 减 8。实际写入的 SHR0 是 cur_vts 减去曝光行数。增大帧长后可以有更大的曝光范围。同样的曝光行数要用不同的 SHR0。真正要换算成时间，还需按当前模式核对实际行时间。

| VBLANK | VTS | 曝光上限 | 固定曝光 1000 行时的 SHR0 | 低、中、高字节 |
| ---: | ---: | ---: | ---: | --- |
| 58 | 2250 | 2242 | 1250 | e2 04 00 |
| 100 | 2292 | 2284 | 1292 | 0c 05 00 |

`drivers/media/i2c/imx415.c:2956`

~~~c
shr0 = imx415->cur_vts - ctrl->val;
ret = imx415_write_reg(imx415->client, IMX415_LF_EXPO_REG_L,
			       IMX415_REG_VALUE_08BIT,
			       IMX415_FETCH_EXP_L(shr0));
~~~

后面继续写中、高位。模拟增益也通过 control 回调下发，使用单独的增益寄存器。若要把增益码换成分贝，核对模组资料和驱动范围。HDR 的多个曝光时间另有约束，表内结论限定在前述线性练习。

## 设置成功，何时能看到图像变化？

普通开流先写 global_reg_list 和 reg_list，然后应用已保存的控制，最后退出待机。快速启动可绕过普通写表环节。驱动设置控制时若未取得当前运行中的 PM 引用，部分路径会在真正写寄存器前返回。所以上层读回的控制值也可能是软件当前值。

`drivers/media/i2c/imx415.c:2502`

~~~c
ret = __v4l2_ctrl_handler_setup(&imx415->ctrl_handler);
if (ret)
	return ret;
~~~

上面会应用 handler 中保存的值。分层观测时，控制设定时间、I2C 写入时间和哪一帧使用新值分别记录。现场若 3A 仍在运行，它可能随后覆盖手工设定。需在受控窗口确认控制来源，并比较同一光源的帧亮度与帧序号。此轮仅复算控制和读取历史日志，未写板端寄存器或切换控制策略。

## 本节复盘

1. TRY 和 ACTIVE 都能返回格式，为什么读回时仍要明确 pad 和 which？
2. 取帧长 2292 行，复算曝光上限和 1000 行曝光对应的 SHR0。
3. 应用先设置曝光，再开流，哪段代码将保存的值应用到硬件？
4. 设置返回成功后画面不变，如何区分缓存未写、3A 已覆盖及帧生效时刻尚未到？

下一节由模式的 link frequency 和 lane 数算出物理链路的传输尺度。[5.5 MIPI D-PHY 的物理链路](dphy.md)
