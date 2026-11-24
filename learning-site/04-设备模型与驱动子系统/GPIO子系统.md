# 4.7 GPIO/gpiolib 子系统

<script setup>
import exampleFile from '../examples/inspect-camera-pins.sh?url'
</script>

以一个按键输入和一根低有效使能线为例。消费者知道这根线的用途，控制器知道线在哪一组寄存器，框架连接两边。理解它之后，应能解释 DT 查找、方向设置、逻辑极性、并发占用和睡眠约束。

## 从两组候选引脚预测电平

在 WSL 仓库根目录执行。脚本打印 IMX415 两根控制线的属性和 GPIO4 提供者的 phandle。<a :href="exampleFile" download="inspect-camera-pins.sh">下载候选 DTB 检查脚本</a>。

~~~bash
bash learning-site/examples/inspect-camera-pins.sh gpio
~~~

本轮候选 DTB 中，`reset-gpios = <0xa1 0x00 0x01>`，`power-gpios = <0xa1 0x02 0x00>`。0xa1 对应 GPIO4 provider，偏移 0 对应 RK_PA0，偏移 2 对应 RK_PA2，末格的最低位表示 active-low。经过 descriptor 的逻辑处理后，推挽输出预期如下。观察点先定在 SoC pad。

| consumer | DTS 极性 | 逻辑 0 对应物理电平 | 逻辑 1 对应物理电平 |
| --- | --- | --- | --- |
| reset | 低有效 | 高，释放请求 | 低，复位请求 |
| power | 高有效 | 低，撤销允许 | 高，允许请求 |

保持 reset 的代码值 0，只在纸上改为 active-high，SoC pad 就从高变低。若模组端直连且低有效，这可能让它保持复位。若有反相器或电平转换，再沿该板的原理图推导一次。这里验证了候选 DTB 及软件推导，未操作板端 GPIO。

## 三个内核对象

| 对象 | 谁创建 | 打开源码时先看哪里 |
| --- | --- | --- |
| gpio_chip | 控制器驱动填好并注册 | ngpio、方向和电平回调、can_sleep。offset 是 chip 内编号 |
| gpio_device | gpiolib 管理 | 保存 chip 和描述符数组，承接设备模型中的对象寿命 |
| gpio_desc | core 为一条线维护 | 关联 gpio_device，保存请求、极性、方向等标志，供消费者持有 |

<Sdk id="gpio-register-chip" />

读 gpiochip_add_data_with_key，找分配 gpio_device、初始化各线描述符和把 chip 注册到框架的步骤。注册后多个消费者可在同一 chip 上各申请不同 offset。旧整数 GPIO API 依赖全局编号；描述符接口以设备和 consumer 名定位，调用处通常无需知道全局 base。用户空间 GPIO 字符设备同样按 chip 和 line offset 组织。

## 从 consumer 名追到一根线

~~~text
devm_gpiod_get(dev, "enable", flags)
 → gpiod_get_index 查询固件
 → of_find_gpio 查 enable-gpios，解析 phandle 与 specifier
 → 找已注册 gpiochip，按 provider 的规则取得 offset 和标志
 → 请求描述符，设置初始方向/极性标志 → 返回给消费者
~~~

<Sdk id="gpio-get-index" />

通用获取方法负责资源查找与申请。固件是 OF 时，用下面的查找分支读 consumer 对应属性。

`drivers/gpio/gpiolib-of.c:515`

~~~c
if (con_id)
	snprintf(prop_name, sizeof(prop_name), "%s-%s", con_id,
				 gpio_suffixes[i]);
~~~

con_id 为 reset 时会尝试 reset-gpios 等允许的名字。查找到属性后，OF 的解析函数按 provider 约定读 phandle 和参数，再定位已经注册的 gpio_chip，得到 descriptor 及固件标志。

例如 enable-gpios 可指向 gpio3 的某条线。phandle 识别 provider，后续 cells 格式由其 binding 和 #gpio-cells 约定。看到 −EPROBE_DEFER 时，追提供者是否已注册。看到 −EBUSY 时追谁已请求。optional API 允许属性缺失返回 NULL，其他错误仍可能以错误指针返回。devm 在设备解绑时释放申请的描述符，硬件关断顺序仍由消费者实现。

本版 IMX415 将两个 descriptor 分别保存在私有结构里。传入 GPIOD_ASIS 表示获取时不设置方向或初值。此时申请仍可能关联 pinctrl 的 GPIO 功能及其所有权。

`drivers/media/i2c/imx415.c:3244`

~~~c
imx415->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_ASIS);
if (IS_ERR(imx415->reset_gpio))
	dev_warn(dev, "Failed to get reset-gpios\n");
~~~

这里错误被记录为警告。上电代码随后在句柄有效时调用方向设置。它没有逐项核对这些方向设置的返回值，所以执行到代码的位置仍需结合硬件状态验证。

## 从逻辑值到寄存器

`drivers/gpio/gpiolib.c:2420`

~~~c
VALIDATE_DESC(desc);
if (test_bit(FLAG_ACTIVE_LOW, &desc->flags))
	value = !value;
else
	value = !!value;
~~~

核心把逻辑值规范成原始值后，继续检查 IRQ 使用、开漏等条件，最终由 gpiochip 的方向回调接手。

逻辑电平在核心按标志转换后，SoC GPIO 控制器才收到实际输出值。

`drivers/gpio/gpio-rockchip.c:368`

~~~c
rockchip_gpio_set(gc, offset, value);

return rockchip_gpio_set_direction(gc, offset, false);
~~~

回调按 offset 写输出数据寄存器，再切输出方向，减少切换瞬间带出旧值的风险。对于能选择复用的 pad，本版 Rockchip chip 还使用 gpiochip_generic_request，通过 pin range 让 pinctrl 请求 GPIO 功能。遇到资源占用，从 descriptor 的请求状态和 pinctrl owner 分别查。

读输入时逻辑 API 同样遵循极性。raw API 使用原始电平。开漏输出还可能通过切输入实现高阻态，需要外部上拉，不能直接把逻辑值解释成电压源。

若控制器本身经 I2C 扩展，访问可能阻塞。用 gpiod_cansleep 核对提供者；可睡眠路径使用带 cansleep 的访问器。硬 IRQ 通常只做能在原子上下文完成的动作，把慢操作移到线程化中断或 worker。若把输入作为 IRQ，gpiod_to_irq 取得 Linux IRQ，再通过 IRQ 框架设置处理函数和触发类型。GPIO 的有效极性和 IRQ 的边沿配置各自有语义。

## 本节复盘

- **申请成功为什么还没有输出？** 申请建立消费者引用。GPIOD_ASIS 保留方向，本次还需检查方向设置、pad mux 和线路本身。
- **为什么两处代码都在谈 GPIO 复用？** 某些 gpiochip 的 request 回调还会通过 pin range 请求 pinctrl 的 GPIO 功能。gpiolib 关注哪条线、方向与电平，pinctrl 关注该 pad 的复用和电气属性。先查具体 provider 的回调再决定在哪层找冲突。
- **用什么证明低有效？** 从属性到 descriptor 标志再到原始值，逻辑 1 推出 SoC 侧低电平。实际引脚与外部反相还需量测。拿本板的 reset-gpios 和 power-gpios 各算一遍，观察两个 consumer 的结果。

在 WSL 核对实现，从注册、获取跟到方向回调。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'gpiochip_add_data_with_key|gpiod_get_index\(|FLAG_ACTIVE_LOW' "$k/drivers/gpio/gpiolib.c"
rg -n 'rockchip_gpio_direction_output|gpiochip_generic_request' "$k/drivers/gpio/gpio-rockchip.c"
~~~

下一节沿时钟 provider、consumer 和 CRU 输出，追踪 B1 的 XCLK。[4.8 Common Clock Framework](clock-framework.md)
