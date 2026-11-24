# 5.2 第一次上电、复位、XCLK 与读 ID

<script setup>
import exampleFile from '../examples/imx415-id-evidence.awk?url'
</script>

上一节已经为新板标出了供电、复位、时钟和 I2C 的来源。首次访问时，按顺序问三个问题：执行哪条上电分支，发出了什么事务，返回的值有没有被驱动接受。

## 用原厂历史记录做一次判读

在 WSL 仓库根目录执行。脚本读一份日志，为每一条相关记录分类并保留原文。若缺历史文件，可用下一段合成输入练习。<a :href="exampleFile" download="imx415-id-evidence.awk">下载日志判读脚本</a>。

~~~bash
awk -f learning-site/examples/imx415-id-evidence.awk output/camera-check/dmesg-before.log
~~~

本轮第一路 3-001a 在 3.005832 s 打印接受 0xe0，第二路 4-001a 在 3.077805 s 打印 id=0 和 ret(-5)。两个时间戳来自历史日志。它们分别属于两个实例，不能拿来相减估算同一颗器件的上电时间。

以下两行是合成输入，在宿主离线验证“传输完整但 ID 不符”和“明确跳过检查”。输出应分成两个类别。

~~~bash
printf '%s\n' \
  'imx415 3-001a: Unexpected sensor id(000042), ret(0)' \
  'imx415 4-001a: Enable thunderboot mode, skip sensor id check' |
  awk -f learning-site/examples/imx415-id-evidence.awk
~~~

若当前窗口没有 ID 记录，脚本返回 1。要区分日志范围、过滤及驱动阶段，仍要查更早的启动记录和对应的活动设备。

## 将板级信号和软件调度画在同一张图

~~~text
板级线：POWER(GPIO4_A2) → 供电开关接线待核对
        RESET(GPIO4_A0) → XCLR，模组端电平待测
        CRU 输出 → GPIO4_B1 → XCLK
        I2C3 A4/A5 → SCL/SDA
普通代码：POWER=1 → 等 10～20 ms → RESET=0 → 等 10～20 ms
        → 设置并检查 mode 的 XVCLK → prepare/enable
        → regulator_bulk_enable → 等 20～30 ms → 返回 probe
事务：写方向寻址 0x1a → 0x31 0x1a → 重复 START → 读方向寻址 0x1a
        → 取得一个字节 → 主机结束本次读取 → STOP → 软件检查 ID
~~~

GPIO 数字是逻辑值。按候选极性推导 SoC pad 预期，仍需核对电路后的模组输入。本版模式表含 37.125 MHz 和 27 MHz，实际上电用当前模式字段，不从其他项目复制固定频率。上述时间是 usleep_range 的请求参数，测量时需要对齐轨稳定、模组 XCLR、XCLK 时钟和第一个 I2C START。

`drivers/media/i2c/imx415.c:2628`

~~~c
ret = clk_set_rate(imx415->xvclk, imx415->cur_mode->xvclk);
if (ret < 0)
	dev_warn(dev, "Failed to set xvclk rate\n");
if (clk_get_rate(imx415->xvclk) != imx415->cur_mode->xvclk)
	dev_warn(dev, "xvclk mismatched\n");
~~~

速率不符在这里告警，后续若 enable 失败则进入回退。在“第一次通信前准备好”这道门槛，必须保留设频、使能和引脚电气证据的区别。[4.8 时钟框架](../04-设备模型与驱动子系统/clock-framework.md)与[4.9 供电时序](../04-设备模型与驱动子系统/regulator.md)。

## probe 如何决定何时开始读，何时退出？

`drivers/media/i2c/imx415.c:3281`

~~~c
ret = __imx415_power_on(imx415);
if (ret)
	goto err_free_handler;

ret = imx415_check_sensor_id(imx415, client);
if (ret)
	goto err_power_off;
~~~

上电返回失败时走上电失败后的清理。成功之后才调 ID 检查，若此时不通过，既有电源状态要从 err_power_off 回退。注册媒体实体及异步子设备都在后面。

`drivers/media/i2c/imx415.c:3134`

~~~c
if (imx415->is_thunderboot) {
	dev_info(dev, "Enable thunderboot mode, skip sensor id check\n");
	return 0;
}
~~~

thunderboot 分支直接通过这一项。普通分支调用 4.12 的双消息 helper。它在完成两条消息后才写 id，否则保留初始值。检查针对驱动的预期常量 0xe0。控制链应答证据只覆盖这一寄存器在当次访问中的结果。模组料号、完整模式能力和实际出流仍有独立验收点。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:3127–3132`

~~~c
static int imx415_check_sensor_id(struct imx415 *imx415,
				  struct i2c_client *client)
{
	struct device *dev = &imx415->client->dev;
	u32 id = 0;
	int ret;
~~~

## 按首个缺失的证据继续排错

| 观察 | 当前能确定 | 下一项证据 |
| --- | --- | --- |
| ret(-5)，id 为 0 | helper 未接受底层传输结果 | 底层结果、控制器状态、SCL/SDA 及实际装配 |
| ret(0)，id 仍不同 | helper 接受完整消息并给出一个字节 | 模组型号、内部寄存器、读宽和回包 |
| 明确 skip sensor id check | 当前检查由快速启动短路 | 若需验证器件应答，另外取真实事务证据 |
| Detected … e0 | 普通检查接受期望值 | 异步注册与媒体图，之后再验证帧完成 |

本轮只核对源码、离线模型及历史记录。首次上电波形、另一接口失败的物理原因，以及新板端的控制链仍待验证。

## 本节复盘

1. 把 POWER、XCLR、XCLK、首次 START 排进同一张图。哪些时刻来自软件，哪些要上板量？
2. 为什么一条 ID 日志里的 0 可能只是初始值？哪一项能区分传输完整却确实读回 0？
3. probe 正常返回时，如何区分实读与跳过？如何进一步证明有像素输出？

下一节将上电与探测放回整份驱动结构。[5.3 拆开一个完整 sensor 驱动](sensor-driver.md)
