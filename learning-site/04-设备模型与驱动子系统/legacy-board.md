# 4.3 传统板文件与 platform_data

<script setup>
import cExample from '../examples/board-polarity.c?url'
import dtExample from '../examples/board-polarity-b.dts?url'
</script>

如果 PCB B 把一颗 LED 从 4 号线改到 7 号线，并把有效电平反过来，驱动的点亮动作需要变吗？先用同一逻辑操作跑两份板级输入，再与固件属性对照。

## 离线跑一次板型差异

在 WSL 仓库根目录运行。C 文件只模拟逻辑值与物理电平的换算。DTS 片段只用来观察本地 dtc 如何编码示例引用。<a :href="cExample" download="board-polarity.c">下载 C 模型</a>与<a :href="dtExample" download="board-polarity-b.dts">下载 B 板 DTS</a>。

~~~bash
base=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
dtc="$base/scripts/dtc/dtc"
mkdir -p output
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/board-polarity.c -o output/board-polarity
./output/board-polarity
"$dtc" -I dts -O dtb -o output/board-polarity-b.dtb learning-site/examples/board-polarity-b.dts
"$dtc" -I dtb -O dts output/board-polarity-b.dtb | rg 'gpios =|phandle ='
~~~

本轮 A 输出线号 4、on=1、off=0，B 输出线号 7、on=0、off=1。反编译得到 `gpios = <0x01 0x07 0x01>`，第一个 0x01 是本次编译给提供者分配的 phandle，后两个单元是线号与极性标志。例子提供者没有实际控制器实现。真实系统按对应 GPIO binding 决定单元含义及编号空间，硬编码全局线号也不能直接照搬为 bank 内偏移。

## 传统 C 板文件给内核哪些输入？

~~~text
板型选择
  ├─ platform_device 加资源与 platform_data → platform 匹配 → 驱动读取
  └─ I2C board_info 加 busnum → 对应 adapter 注册 → 创建 client → I2C 匹配
~~~

资源用于 MMIO、IRQ 等内核统一描述。platform_data 是设备附带的板级数据，结构由板代码和使用它的驱动约定。普通指针携带这份数据，指向对象应覆盖驱动使用期。I2C board_info 则描述要在某条总线上实例化什么器件，也可包含传给 client 的 platform_data。板级代码本身还能包含条件与启动逻辑。共同点是由内核镜像里的 C 文件提供实例信息。

在本地 SDK 中，可对读旧 ARM 板 DNS-323 的 C 修订。GPIO LED 的 platform_device 名为 leds-gpio。其他修订用默认结构，C 修订在注册前换掉指针。

`arch/arm/mach-orion5x/dns323-setup.c:632`

~~~c
case DNS323_REV_C1:
	/* Hookup LEDs & Buttons */
	dns323_gpio_leds.dev.platform_data = &dns323c_led_data;
	dns323_button_device.dev.platform_data = &dns323c_button_data;
~~~

板文件最终注册设备。同一 LED 驱动的 probe 读取板级数据，由此得知对象数、线路和极性。下面是读取指针的位置。

`drivers/leds/leds-gpio.c:242`

~~~c
struct gpio_led_platform_data *pdata = dev_get_platdata(&pdev->dev);
~~~

该驱动还有按固件描述读取 GPIO 的路径。增加一个接线不同的板型时，优先表达接线差异。常规点亮和熄灭仍是同一逻辑操作。

<Sdk id="legacy-board-select" />

## I2C board_info 如何等到 adapter？

在 DNS-323 例子中，A/B 表有 g760a 0x3e，C 不含这一项。两张表都有 0x48 与 0x68。选择表后用 i2c_register_board_info 登记到编号 0。以下命令在仓库根目录核对原文。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'I2C_BOARD_INFO|dev.platform_data =|i2c_register_board_info|platform_device_register\(&dns323_gpio_leds' \
  "$k/arch/arm/mach-orion5x/dns323-setup.c"
rg -n 'i2c_scan_static_board_info\(|client->dev.platform_data' "$k/drivers/i2c/i2c-core-base.c"
~~~

登记函数保存 busnum 和 board_info，并把条目放到列表。板文件应在相关适配器注册以前登记。后续 I2C 核心查看适配器编号是否匹配，再实例化 client。

`drivers/i2c/i2c-core-base.c:1419`

~~~c
list_for_each_entry(devinfo, &__i2c_board_list, list) {
	if (devinfo->busnum == adapter->nr &&
	    IS_ERR(i2c_new_client_device(adapter, &devinfo->board_info)))
		dev_err(&adapter->dev,
			"Can't create device at 0x%02x\n",
			devinfo->board_info.addr);
}
~~~

创建 client 描述的是预期连接。实例化阶段不读取芯片 ID。若旧板没有器件响应，以适配器实际传输和芯片 probe 结果为准。

<Sdk id="legacy-info-register" />

## 迁移到设备树时逐项对照

| 旧输入 | 可对应的固件描述 | 驱动仍要做的事 |
| --- | --- | --- |
| platform_device 的资源数组 | 由父总线和 binding 解释的 reg、interrupts | 取资源、映射、检查并初始化 |
| I2C 总线号、type、addr | 正确的 I2C 父节点、compatible、reg | 匹配器件、确认 ID 与能力 |
| GPIO 编号及 active_low | 引用 GPIO 提供者及其 specifier，在规定位置编码极性 | 取得 descriptor，按逻辑有效或无效使用 |
| 板代码函数指针、等待及执行顺序 | binding 支持的供电、时钟、复位或延时约束 | 实现正确顺序、等待与失败回退 |

切换到 RV1126B 的 IMX415 时，假如只换 RESET 线路，先核对原理图、板级反相、模组有效电平和驱动使用的逻辑值，再确定应改的板级参数。若旧实现已经在软件中反相，迁移时要核对新的 descriptor 语义，避免重复反相。器件型号变化还涉及驱动 ID、寄存器表和媒体能力。上述离线模型验证到值的对应关系，未修改实际板级文件，也未进行物理测量。

## 本节复盘

1. platform_data 和 i2c_board_info 各说明什么？为什么一个穿过 platform，另一个要等对应 adapter？
2. A、B 两块板点亮语义相同，为什么物理电平相反？哪个属性应承担这次变化？
3. 某旧板文件把复位时序放到一个函数回调，迁移时哪些内容可以用 binding 描述，哪些需要代码？
4. client 创建成功能否作为物理应答证据？要补查什么？

下一节从属性、编译产物和活动树验证一次完整的描述链。[4.4 DTS、DTSI、binding 与 DTB](devicetree.md#dtb)
