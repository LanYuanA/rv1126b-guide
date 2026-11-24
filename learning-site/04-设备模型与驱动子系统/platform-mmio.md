# 4.2 platform 总线、资源与 MMIO

上一节区分了控制器、I2C adapter 和 sensor client。这一节问 CPU 怎样碰到**控制器**的寄存器，以及为什么同一段设备树里还会出现另一个完全不同的地址 0x1a。

## 从已编译 DTB 取出资源

在 WSL 仓库根目录运行。使用当前本地候选构建中的 DTB 和同一构建产生的 dtc，输出只写到 output，可与相应节点的 DTS 比对。

~~~bash
base=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
dtb="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
mkdir -p output
"$base/scripts/dtc/dtc" -I dtb -O dts -o output/platform-candidate.dts "$dtb" \
  2>output/platform-candidate-dtc.log
rg -n -A8 '^\s*i2c@21120000 \{' output/platform-candidate.dts
printf '最后一个字节=0x%x\n' "$((0x21120000 + 0x1000 - 1))"
~~~

本轮看到 `reg = <0x21120000 0x1000>`、`interrupts = <0x00 0x33 0x04>`、时钟名 i2c 和 pclk。范围为 0x21120000～0x21120fff，第二个 cell 是长度，区间末端要减 1。反编译告警留在 `output/platform-candidate-dtc.log`。本轮包括 I2C3 下几个候选传感器重复使用 0x1a 的提示。控制器资源值已读出，模组选择还要核对实际启用节点和板上接线。如果找不到文件，先核对本地内核候选构建的位置。本步骤只确认编译产物中的资源值，启动现场另查。

| 读到的数值 | 地址空间 | 谁解释 |
| --- | --- | --- |
| 0x21120000 | RV1126B 控制器的 MMIO 起始地址 | OF 平台资源翻译后由 CPU I/O 访问器使用 |
| 0x1a | 传感器的 I2C 七位地址 | adapter 在 I2C 总线上选择从设备 |
| 0x311a | IMX415 的芯片 ID 寄存器编号 | 传感器根据 I2C 消息解释 |

## 凭什么能够取到第 0 个内存资源？

platform_device 描述实例及资源，platform_driver 描述怎样初始化和移除这一类实例。平台匹配可以走 OF 或 ACPI，也可按 ID 表和设备名等规则。当前控制器的正常路径从 OF 创建 platform_device，rk3x 驱动按 compatible 匹配。

~~~text
DTS 的 controller reg → 编译后的 DTB → 运行的 OF 节点
  → 父总线地址格式和 ranges 翻译 → platform_device 的 resource 表
  → rk3x probe 按类型与索引取资源 → 请求区间并 ioremap
  → __iomem 基址 + 控制器寄存器偏移 → readl / writel
~~~

`drivers/of/platform.c:138`

~~~c
for (i = 0; i < num_reg; i++, res++) {
	rc = of_address_to_resource(np, i, res);
	WARN_ON(rc);
}
~~~

这是 OF 构建内存资源的循环。读取 reg 要按父节点的地址与长度 cell 数解释，若有总线地址转换还需看 ranges。子节点的 `#address-cells = <1>`、`#size-cells = <0>` 则规定 I2C 下属器件 reg 的形状。

`drivers/base/platform.c:104`

~~~c
r = platform_get_resource(pdev, IORESOURCE_MEM, index);
if (res)
	*res = r;
return devm_ioremap_resource(&pdev->dev, r);
~~~

索引在同一资源类型内计数。helper 验证内存资源，请求区间以管理重叠，然后建立供 CPU 访问的映射。资源冲突可返回错误。probe 若失败，或驱动解绑时，devm 按对应生命周期清理托管资源。设备仍有 IRQ、工作项或硬件访问时，驱动仍需按顺序停止这些活动。

`drivers/i2c/busses/i2c-rk3x.c:1965`

~~~c
i2c->regs = devm_platform_ioremap_resource(pdev, 0);
if (IS_ERR(i2c->regs))
	return PTR_ERR(i2c->regs);
~~~

这里拿到的是带 __iomem 注解的内核地址。访问器提供对应的 MMIO 访问语义，不能把寄存器当普通 RAM 随意解引用。具体寄存器还可能读后清除、写一清除或有时序限制。

`drivers/i2c/busses/i2c-rk3x.c:318`

~~~c
static inline u32 i2c_readl(struct rk3x_i2c *i2c, unsigned int offset)
{
	return readl(i2c->regs + offset);
}
~~~

offset 是控制器内的寄存器偏移。要读 sensor 的 0x311a，则由驱动构造 I2C 传输，经 adapter 和控制器发送，结果由传感器返回。两层地址即使数值偶然相同，解释者也不同。

<Sdk id="platform-rk-map" />

## IRQ 索引、硬件号、Linux 号怎么区分？

`drivers/i2c/busses/i2c-rk3x.c:2002`

~~~c
irq = platform_get_irq(pdev, 0);
if (irq < 0)
	return irq;
i2c->irq = irq;
~~~

0 是第一个中断说明符的索引。OF 路径按控制器解析该说明符并经 irqdomain 建立 Linux IRQ。此处 GIC-400 对 SPI 号 51 增加 32，硬件号是 83。下面是 SPI 对应的分支。

`drivers/irqchip/irq-gic.c:1216`

~~~c
case 0:			/* SPI */
	*hwirq = fwspec->param[1] + 32;
	break;
~~~

Linux IRQ 由域映射，不能从 83 直接断定。驱动随后用 Linux IRQ 注册 rk3x_i2c_irq。有关 IRQ 的入口与 action 见[卷三 IRQ 子系统](../03-Linux内核/irq.md)。

时钟也分两路。驱动按名字取 i2c 与 pclk 的句柄，其中一条服务控制器工作时钟，另一条服务外设总线接口。拿到句柄后，还要按实际运行路径准备和开启。排查失败时依次看资源翻译、区间占用、IRQ 与时钟的返回值；控制器成功注册 adapter 后才进一步排查从地址、供电和物理应答。

## 本节复盘

1. 为什么 0x1a 和 0x311a 都不能直接交给 ioremap？说明谁解释这两种地址。
2. resource 请求和 ioremap 分别解决什么？如果前者报告 EBUSY，怎样在不访问硬件寄存器的情况下继续定位？
3. 解释 0、51、83 与 platform_get_irq 返回值的差别。
4. 编译后的 DTB 能验证哪部分？要验证实际启动和中断处理还需哪些现场证据？

下一节看同类资源与板型参数如何通过旧式 C 板文件输入。[4.3 传统板文件与 platform_data](legacy-board.md)
