# 4.10 reset controller 与复位 GPIO

<script setup>
import exampleFile from '../examples/reset-window.awk?url'
</script>

SoC 的 SAI0 和板外的 IMX415 都需要复位。一个引用 CRU 的复位 ID，另一个把 SoC pad 接到模组的 XCLR。选接口之前，先问复位动作由哪个硬件产生，又要在什么条件下解除。

## 先对照两个节点和一次时序演算

在 WSL 仓库根目录执行。前两条分别核对 SAI0 与第一路 IMX415 的复位属性。最后一条比较两种虚构波形。<a :href="exampleFile" download="reset-window.awk">下载首次 I2C 时间窗演算</a>。

~~~bash
tree=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/arch/arm64/boot/dts/rockchip
rg -n -A1 'resets = <&cru SRST_MRESETN_SAI0' "$tree/rv1126b.dtsi"
rg -n -m1 -A1 'reset-gpios = <&gpio4 RK_PA0' "$tree/rv1126b-alientek.dtsi"
awk -f learning-site/examples/reset-window.awk
~~~

模型假设 XCLR 在 100 µs 释放，释放后需至少 20 µs，电源在 110 µs 达到阈值，时钟在 150 µs 稳定。最早可开始时刻取三个条件的最大值，为 150 µs。170 µs 开始有 20 µs 余量，140 µs 开始则比时钟就绪早 10 µs，即使已经满足了假设的复位等待。数字为顺序演算输入，目标硬件需使用实际手册规定及波形。

## SoC 内部复位怎样从名字找到控制器？

~~~text
SAI0 的 reset-names "m"/"h"
  → 所在索引的 resets 引用 → CRU 提供者 + 复位 ID
  → provider 翻译 ID → reset_control
  → assert / deassert → CRU 复位回调
~~~

SAI0 的 resets 有两项，每项有 CRU 的 phandle 与一个复位 ID。m 和 h 对应不同复位线。驱动取得两个句柄后可以分别操作。ID 是 CRU binding 的资源编号，工作时钟的编号也不能代替它。

`drivers/reset/core.c:829`

~~~c
if (id) {
	index = of_property_match_string(node,
						 "reset-names", id);
	if (index == -EILSEQ)
		return ERR_PTR(index);
	if (index < 0)
		return optional ? NULL : ERR_PTR(-ENOENT);
}
~~~

随后以该索引解析 resets 及 #reset-cells。provider 未注册时可能返回 EPROBE_DEFER。已注册的 provider 将参数翻译成内部 ID，再建立或取得 reset_control。optional 仅允许相应资源缺失返回 NULL，错误指针仍须检查。

`sound/soc/rockchip/rockchip_sai.c:2058`

~~~c
sai->rst_h = devm_reset_control_get_optional_exclusive(&pdev->dev, "h");
if (IS_ERR(sai->rst_h))
	return PTR_ERR(sai->rst_h);
~~~

同一驱动还取得 m。实际复位操作中先 assert h、等 10 µs、deassert h，再处理 m，后面恢复寄存器设置。该顺序由 SAI 的时钟依赖决定。这个数字不能直接拿给模组上电用。

`drivers/reset/core.c:562`

~~~c
if (!rstc->rcdev->ops->deassert)
	return 0;

return rstc->rcdev->ops->deassert(rstc->rcdev, rstc->id);
~~~

这里分派到具体控制器。有些硬件通过单次 reset 产生自动释放的脉冲，要看 provider 实现。对共享的 assert/deassert 用法，框架按 deassert_count 管理使用。一个消费者归还时，其他消费者仍需要解除复位，就不会立即拉回复位。独占句柄则遵循对应的取得和操作约定。

<Sdk id="reset-framework" />

## 板外 XCLR 如何随 GPIO 改变？

~~~text
IMX415 的 reset-gpios → GPIO4_A0 的 descriptor
  → 驱动请求逻辑 1 或 0 → gpiolib 按低有效映射成 SoC 低或高
  → 板级线路和电平转换 → 模组 XCLR
~~~

`drivers/media/i2c/imx415.c:2621`

~~~c
if (!IS_ERR(imx415->reset_gpio))
	gpiod_direction_output(imx415->reset_gpio, 0);
~~~

普通上电请求逻辑 0，按本候选的 active-low 属性推导 SoC pad 为高、释放请求。实际模组 XCLR 要继续核对线间反相、移位和供电。正常断电先用逻辑 1 请求复位，再关闭时钟等资源，较细顺序见[供电时序](regulator.md)。

<Sdk id="sensor-power-down" />

## 首次 I2C NACK 怎样缩小原因？

| 待区分的因素 | 同一时间轴要采什么 |
| --- | --- |
| XCLR 没真正释放或脉宽不够 | SoC pad 与模组端观察点、有效电平和脉宽 |
| 供电或 XVCLK 太晚稳定 | 轨电压、XCLK 幅值和稳定起点 |
| 主机访问过早或寻址错误 | 第一个 START、七位地址和 ACK，关联到上面三个条件 |
| 软件没有走到预期路径 | probe 模式、资源错误、延时参数与日志 |

先验证连线和时间要求，再判断是否要改延时。复位请求和软件睡眠均已从源码核对，未采到目标波形。共享供电、定时器调度和快速启动路径都会影响现场现象。

## 本节复盘

1. 为什么 SAI0 的 rst_h 用 reset_control，而 XCLR 用 GPIO descriptor？各自由谁实现动作？
2. 共享 reset 的一个使用者调用 assert，什么时候还不能真正拉回复位？
3. 模型中按复位条件 120 µs 已经可以继续，为什么最早 START 却是 150 µs？
4. 出现 NACK 后，怎样把复位、电源、时钟和 I2C 地址错误分别验证？

下一节跟踪谁在反复调用上电和下电，以及怎样配对引用。[4.11 runtime PM 与系统休眠](runtime-pm.md)
