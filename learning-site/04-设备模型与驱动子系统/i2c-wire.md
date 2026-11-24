# I2C 上篇　从两根线读懂一笔 IMX415 事务

板上的历史日志有一句 `imx415 3-001a: Detected imx415 id 0000e0`。假如面试官只递给你这行字，你能画出控制器为了取得这一个字节，先后向哪颗器件发了哪些字节吗？本篇从导线讲到 Linux 对象。中篇回到设备上电前，追踪内核怎样找到这颗器件。下篇再看一次读取怎样完成、失败时证据在哪里。[中篇　从设备树到消息](i2c-probe.md) · [下篇　从中断到故障定位](i2c-irq.md)

**先在源码中找到三个数。** 在 WSL 项目根目录执行这三行，不需要连接开发板。第一处命中是驱动预期的 ID 值，第二处是保存这个值的寄存器。把它们记在纸上，等会儿分别放进传输图。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n '^#define (CHIP_ID|IMX415_REG_CHIP_ID)\s' "$k/drivers/media/i2c/imx415.c"
rg -A2 'imx415_0: imx415_0@1a' "$k/arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi"
~~~

本地基线 `a04e4b3c9` 的三个输入是 `CHIP_ID = 0xE0`、`IMX415_REG_CHIP_ID = 0x311A`、`reg = <0x1a>`。下方代码块给出这几处定义，块上方标出文件路径和原始行号。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:81–86`

~~~c
#define CHIP_ID				0xE0
#define IMX415_REG_CHIP_ID		0x311A

#define IMX415_REG_CTRL_MODE		0x3000
#define IMX415_MODE_SW_STANDBY		BIT(0)
#define IMX415_MODE_STREAMING		0x0
~~~

头部常量描述要访问的内部寄存器和值。板级节点另给这颗器件的总线地址。

源码摘录 `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi:489–494`

~~~text
&i2c3 {
	status = "okay";
	pinctrl-0 = <&i2c3m1_pins>;

	imx415_0: imx415_0@1a {
		compatible = "sony,imx415";
~~~

下图放在手边。上半部发生在创建和匹配设备时。下半部可以重复很多次，曝光、增益与模式控制也会用到寄存器传输。

~~~text
建立对象   SoC 的 I2C3 节点 → 控制器驱动 → adapter 3
                                              │ 枚举板级子节点
                               sony,imx415 → client（addr 0x1a）→ 匹配 sensor 驱动
运行事务   imx415_read_reg(client, 0x311a, 1, &id)
                        ↓ 两个 i2c_msg
           I2C core → adapter 的传输回调 → 控制器寄存器 → SCL/SDA → IMX415
           id ← 读消息的缓冲区 ← 控制器收到的数据 ← SDA 上的 8 个数据位
~~~

## 1. 怎样知道一串高低电平从哪里开始读

### 先只看两根线，再数九个时钟

SCL 是时钟，SDA 是双向数据。本例按普通 I2C 的开漏方式理解。器件可以把线拉低，释放后由上拉让它回到高电平。双方都释放时，总线空闲，SCL、SDA 都高。主控要传一个普通数据位，通常在 SCL 低时准备好 SDA，让接收方在 SCL 高时读稳定的电平。于是 SCL 保持高时 SDA 的跳变可以有专门的含义。[NXP I²C 规范，第 3.1 节](https://www.nxp.com/docs/en/user-guide/UM10204.pdf)

| 用笔依次标出 | SCL 高时 SDA 怎样变化 | 观察者怎样解释 |
| --- | --- | --- |
| 空闲 → 起始 S | 高转低 | 一笔事务开始，接下来按位读地址 |
| 传普通数据位 | 保持低或保持高 | 低读作 0，高读作 1。将连续 8 位按最高位在先组成一个字节 |
| 第九个时钟 | 发送方释放 SDA，接收方可以拉低 | 低为 ACK，表示对刚过去的字节应答。保持高为 NACK |
| 重复起始 Sr | 已占有总线时，再做一次起始 | 新一段可以换方向。其前没有 STOP |
| 停止 P | 低转高 | 这笔总线事务结束 |

**在纸上解一次码。** 下面第一行是采样位置编号，第二行是起始之后连续九次 SCL 高时的 SDA 采样。这是按协议构造的练习，板上还没有采过逻辑分析仪波形。

~~~text
采样位置        1  2  3  4  5  6  7  8  | 9
SDA             0  0  1  1  0  1  0  0  | 0
                └──── 七位地址 ────┘ 方向   应答
~~~

<details>
<summary>对答案，并指出最后一位由谁驱动</summary>

前七位 `0011010` 得 `0x1a`，第八位 0 表示写，合起来是 `00110100` 即 `0x34`。前八位由控制器发，第九位由被寻址的器件拉低。因此这一组采样只证明地址阶段获得了应答。即使内部寄存器号填错，这个应答也可能照常出现。

</details>

### 为什么读一个字节要先写两个字节

IMX415 内部有许多寄存器。仅叫到它的总线地址，还没告诉它读取哪一个位置。控制器先发送 `0x311a` 的高、低两个字节，接着发重复起始并切到读方向，传感器这时才返回寄存器内容。沿下面一行用两支颜色的笔，一种圈主控发出的字节，另一种圈传感器发出的字节。

~~~text
S  34  A  31  A  1a  A  Sr  35  A  e0  N  P
   └寻址写┘ └寄存器号┘        └寻址读┘ └数据┘
~~~

前四个 `A` 都由传感器给出。读到 `e0` 时角色反转了，传感器发出这八位，控制器在第九拍释放 SDA 给出 NACK，随后结束这一笔读取。如果要读两个字节，控制器会在第一个数据字节后给 ACK 请求继续，到最后一个才给 NACK。诊断报告里只写“发生了 NACK”没有交代故障位置。**读末尾由谁给 NACK、地址之后由谁给 NACK，含义完全不同。** [Linux 6.1 的读事务与组合事务](https://docs.kernel.org/6.1/i2c/i2c-protocol.html)

**自己解码一次。** 把 `e0` 擦掉，改成未知数据 `XX`，再从 S 画一遍。应当仍能标清谁在每个第九拍应答。软件预期的 ID 可以用于事后核对，不能预先当作总线采样填进记录。

## 2. 0x1a、0x311a 和 0xe0 各属于谁

先别背定义，尝试答三个现场问题。换一条控制器总线，哪一个编号可能变？读同一颗芯片的另一个寄存器，哪两个地址字节会变？若只切换线上地址字节的最低位，会影响选芯片，还是会影响传输方向？

| 名字 | 本例的值 | 谁决定、谁使用 |
| --- | --- | --- |
| 适配器编号 | `3` | 本板控制器和 Linux 枚举的结果，对应 sysfs 名称。这个数不会在 SDA 上作为地址发出 |
| 七位器件地址 | `0x1a` | 本板 DTS 的 `reg`，I2C core 保存到 `client->addr`。两条消息用同一个地址 |
| 带方向的线上地址字节 | 写 `0x34`，读 `0x35` | 七位地址左移一位，最低位写 0 或读 1。分析仪可能显示解码后的 `0x1a W/R`，也可能显示原始字节 |
| 内部寄存器号 | `0x311a` | IMX415 驱动选择的寄存器，本例先发送 `31` 再发 `1a`。第二个 `1a` 恰与七位地址数值相同，其所处位置和意义不同 |
| 读回值 | 预期 `0xe0` | 器件在第二条消息的数据阶段发出。驱动等读取完成后才比较 |

在 WSL 根目录运行这个无设备练习。它让你故意把文档上的“写地址字节”当作七位地址，再观察线上的结果。先手算第二行，再运行。

WSL 实测两组分别是 `0x34/0x35` 和 `0x68/0x69`，寄存器字节是 `31 1a`。如果 DTS 写成 `reg = <0x34>`，它本身仍是合法的七位数，编译设备树可以成功。随后发出的却是对七位地址 `0x34` 的访问。修这类问题先对照原理图、器件文档的地址记法和运行节点，再核对总线解码设置。若异址碰巧也有器件，应答也不能替代 ID 校验。

<details>
<summary>本节复盘：分析仪显示 0x35 时，如何描述这个数？</summary>

先说明观察的是地址阶段的原始八位。`0x35 >> 1 = 0x1a` 选器件，最低位 1 选读。若界面已勾选“七位地址解码”，它会把同样的位显示成 `0x1a Read`。第八位本来是 1，要切换到写应将它清零。

</details>

## 3. 一颗芯片为什么涉及两种驱动

上节已经把数字正确地放到线上，接下来问“谁知道要发这些数字”。如果将同一颗 IMX415 接到另一种主控，`0x311a` 这种寄存器知识可以沿用，但让 SCL 跳变的硬件寄存器大概率换了。Linux 把这两种知识交给不同驱动，`struct i2c_msg` 是它们共同使用的传输描述。

| 对象 | 本板对应什么 | 第一次读源码先圈哪个字段 |
| --- | --- | --- |
| `platform_device` 与 `platform_driver` | SoC 内存映射的 I2C3 控制器及驱动 `i2c-rk3x.c` | 从控制器节点的 `reg` 和 IRQ 取得硬件资源。可在该节点看到 `i2c@21120000` |
| `i2c_adapter` | 该控制器对 Linux 提供的一条总线 | `adap.algo` 指向传输操作表，`algo_data` 指回控制器的私有状态 |
| `i2c_client` | adapter 3 上七位地址为 `0x1a` 的这个实例 | `client->addr` 是地址，`client->adapter` 指回它所在的总线 |
| `i2c_driver` | 认识 IMX415 的器件驱动 | 匹配表声明型号，`probe` 接收具体 client，寄存器读函数接收这个 client |

在 WSL 根目录执行，沿前文的两条线读代码，一条找操作表选中的函数，另一条找传入的实例。先看 `adap.algo` 的赋值，再看传感器传入哪个 `adapter`。两个位置之间由 I2C core 接起来。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'i2c3: i2c@|rockchip,rv1126b-i2c' "$k/arch/arm64/boot/dts/rockchip/rv1126b.dtsi"
rg -n 'adap.algo =|adap.algo_data =|i2c_add_numbered_adapter\(' "$k/drivers/i2c/busses/i2c-rk3x.c"
rg -n 'msgs\[0\].addr = client->addr|i2c_transfer\(client->adapter' "$k/drivers/media/i2c/imx415.c"
~~~

源码摘录 `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b.dtsi:2539–2544`

~~~text
i2c3: i2c@21120000 {
	compatible = "rockchip,rv1126b-i2c";
	reg = <0x21120000 0x1000>;
	interrupts = <GIC_SPI 51 IRQ_TYPE_LEVEL_HIGH>;
	#address-cells = <1>;
	#size-cells = <0>;
~~~

SoC 节点描述控制器资源。控制器驱动初始化后把通信能力挂在 adapter 上。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:1953–1958`

~~~c
i2c->adap.algo = &rk3x_i2c_algorithm;
i2c->adap.retries = 3;
i2c->adap.dev.of_node = pdev->dev.of_node;
i2c->adap.algo_data = i2c;
i2c->adap.dev.parent = &pdev->dev;
i2c->adap.dev.fwnode = fw;
~~~

adapter 提供传输入口；sensor helper 交给它的是已组织好的两条消息。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:1408–1413`

~~~c
static int imx415_read_reg(struct i2c_client *client, u16 reg, unsigned int len,
			   u32 *val)
{
	struct i2c_msg msgs[2];
	u8 *data_be_p;
	__be32 data_be = 0;
~~~

## 本节复盘

**给同事解释 `3-001a`。** `3` 标识总线，`001a` 是按十六进制补足位数的器件地址。client 被创建只说明内核按板级描述建立了软件对象。要说明谁已绑定，应看它的 `driver` 链接。要说明物理器件曾有正确回应，应看未跳过读取的 ID 检查。要证明像素到达了用户态，还要看采集队列完成和图像。

**画出一次传输。** 试着凭记忆画两条箭头。一条从 `client` 沿 `adapter → algo` 指到控制器，另一条从 `0x311a` 指到 `31 1a`。能画出第一条，说明你分清代码职责。能画出第二条，说明你能解释总线上真正传了什么。接下来回到开机时刻，追到生成这个 `client` 的那一行。[继续读中篇](i2c-probe.md)
