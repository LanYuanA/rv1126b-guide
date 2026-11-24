# 4.4 DTS、DTSI、binding 与 DTB

<script setup>
import exampleFile from '../examples/disable-imx415-overlay.dts?url'
import scriptFile from '../examples/check-imx415-overlay.sh?url'
</script>

## 改动进入哪一份 DTB？ {#dtb}

在 WSL 的工作区根目录执行。先验证 include 关系，再观察基线的编译产物。DTS 是板级源码，DTSI 复用公共描述，DTB 是编译后的扁平设备树。启动时由引导器选择 DTB，内核展开后才有活动设备树。

~~~text
SoC DTSI → 板级 DTSI 覆盖 → 顶层 DTS → Kbuild 预处理与 dtc
  → 候选 DTB → 打包及引导器选用 → 内核展开 → 总线枚举
~~~

~~~bash
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
tree="$sdk/kernel-6.1/arch/arm64/boot/dts/rockchip"
rg -n '#include|imx415_0|&i2c3|csi_dphy_input0' "$tree/rv1126b-alientek-mipi720x1280.dts" "$tree/rv1126b-alientek.dtsi"
out="$sdk/output/kernel-baseline/normal"
dtb="$out/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
"$out/scripts/dtc/dtc" -q -I dtb -O dts "$dtb" | rg -A15 'imx415_0@1a'

~~~

SoC 文件 `rv1126b.dtsi` 描述 I2C3 寄存器区间 `0x21120000`、大小 `0x1000`、IRQ、时钟和默认关闭状态。板级 `rv1126b-alientek.dtsi` 重新打开 `&i2c3` 并选择实际的管脚组。候选顶层 `rv1126b-alientek-mipi720x1280.dts` 引入板级公共描述。同地址候选 sensor 在厂商文件中并存时，必须检查继承、最终 status 和活动树；移植新产品应只启用实际装配的同总线同地址器件。

**先学会按父节点读 cell。** 本版 SoC 根节点使用一格地址和一格长度，所以控制器的 reg 有两格。I2C3 自己规定一格地址、零格长度，sensor 的 reg 只有从地址一格。ports 下的 port@1 则按图结构使用编号。尖括号中的一格通常是 32 位，含义取决于父总线或提供者的 binding。label 用于源码引用，编译时 &引用 可编码成 phandle；反编译后可能只见数字，仍能经目标节点的 phandle 找回关系。status 未写或为 okay 的节点按可用处理，父总线也必须可用才能枚举子设备。

~~~bash
tree=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n -A5 'data-lanes:|link-frequencies:' "$tree/Documentation/devicetree/bindings/media/video-interfaces.yaml"
rg -n '#include' "$tree/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dts"
~~~

binding 给属性的类型、含义和顺序提供约定。例如 data-lanes 的数组位置表示逻辑 lane，值表示物理 lane；link-frequencies 表达允许的链路频率，单位 Hz。schema 能约束能用哪些字段和类型；判断本版驱动究竟消费了哪个字段还需看 parser 和驱动。编译 DTB 的完整 Kbuild 命令沿用[1.7 本地构建基线](../01-开发环境/build.md#用已有工具链生成独立输出)。只复编 DTB 时，可把同一环境中的 make 目标限制为 `rockchip/rv1126b-alientek-mipi720x1280.dtb`。dtc 的编译与可用时的 schema 检查分别回答语法与属性契约。厂商扩展应查本地 binding 及其实际消费者。

### 把原理图翻译成一段节点

先从原理图抄出插座到 SoC 的 SCL/SDA、XCLK、RESET、POWER、供电和 CSI 差分对。有模组手册才能填写电平、上电时序和可用输入时钟。将原理图上的连接按总线身份、资源引用和媒体端口分开填。下面三处取自 `arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi`。

第 493 行起先给 Adapter 枚举用的名字、驱动匹配字符串和七位从地址。

~~~text
imx415_0: imx415_0@1a {
	compatible = "sony,imx415";
	reg = <0x1a>;
~~~

第 496 行起引用提供者。时钟名字给消费者查找，GPIO 的标志随线号交给各自的控制器驱动处理。

~~~text
clocks = <&cru CLK_MIPI0_OUT2IO>;
clock-names = "xvclk";
reset-gpios = <&gpio4 RK_PA0 GPIO_ACTIVE_LOW>;
power-gpios = <&gpio4 RK_PA2 GPIO_ACTIVE_HIGH>;
~~~

第 507 行起给媒体图上另一端提供引用。本端被远端引用时也要有自己的 label。

~~~text
imx415_out0: endpoint {
	remote-endpoint = <&csi_dphy_input0>;
	data-lanes = <1 2 3 4>;
};
~~~

| 输入与编码 | 谁取、存到哪里 | 怎样证实生效 / 写错会看到什么 |
| --- | --- | --- |
| `imx415_0:`、`@1a`、`reg=<0x1a>` | label 给源码引用；unit-address 方便识别；I2C core 从 reg 建立 `client->addr`。父节点规定一格地址、零格长度 | 运行路径 `3-001a`。把 8 位读写地址照填为 reg 会发到别的地址 |
| `compatible` | OF 与驱动的 match table 比对，设备模型据此选择候选 driver | 比较活动树字符串与匹配表，再看 driver 符号链接和日志 |
| `clocks`、`clock-names` | phandle 指 CRU、后面一格选 CRU 输出；consumer 以名字 `xvclk` 取句柄 | probe 得句柄，上电时才设频率与 enable；示波器测插座时钟才是引脚波形证据 |
| `reset-gpios / power-gpios` | GPIO bank、bank 内偏移、极性标志由 gpiolib 解析为 descriptor | 对照 `reset_gpio / power_gpio` 和上电代码的逻辑值，再核实板上电平 |
| `pinctrl-names / pinctrl-0` | 状态列表索引 0 对应 default，phandle 指 pin group | 控制器的组用于 SCL/SDA，sensor 的组用于 XCLK。错组时控制器可注册而引脚无波形 |
| 四个 `rockchip,camera-module-*` | `imx415_probe` 读 index、facing、name、lens-name，保存到这颗 sensor 的私有结构 | index、facing 参与 subdev 命名；模组/镜头字符串供信息查询。缺字段走模组信息错误分支 |
| `port/endpoint/remote-endpoint` | graph 描述本端口和远端端点，接收端异步匹配使用固件节点关系 | 沿两端引用检查互指、端口编号和最终 media link |
| `data-lanes` | V4L2 fwnode parser 填到 `bus_cfg.bus.mipi_csi2`。数值是物理 lane 的索引序列 | 驱动依据数量选择模式表。顺序还需匹配模组和接收器，四个数不能证明信号完整性 |

源码摘录 `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi:489–494`

~~~text
&i2c3 {
	status = "okay";
	pinctrl-0 = <&i2c3m1_pins>;

	imx415_0: imx415_0@1a {
		compatible = "sony,imx415";
~~~

### 从传感器另一端把图接完整

本板 `&csi2_dphy0` 的 `ports/port@0` 中，接收端 `csi_dphy_input0` 写 `remote-endpoint = <&imx415_out0>` 与 `data-lanes = <1 2 3 4>`。同一 DPHY 的 `port@1` 是输出。接新模组时把物理接线与**两边**的端点核对，以本 SDK 的第一路为例逐段填写：

~~~text
sensor.imx415_out0              ↔ DPHY.csi_dphy_input0
DPHY.csidphy0_out               ↔ CSI.mipi0_csi2_input
CSI.mipi0_csi2_output           ↔ CIF.cif_mipi_in0
CIF 输出接口.mipi_lvds_sditf     ↔ ISP 虚拟输入.isp_vir0
~~~

这里 DPHY 的 `port@1` 中 `reg=<1>` 由父节点的地址规则解释，是 graph 端口编号。若再给 endpoint 编号，也要读该端口下的地址规则。I2C 子节点的 `reg=<0x1a>` 则是从地址。两处都叫 reg，要先问“父总线是谁”。相机连线有误时，sensor 仍可能成功 probe，接收端的异步 notifier 却无法完成配对；先比较固件图和运行 media graph，再决定需改哪一端。

## 用离线 overlay 隔离一个变量

从仓库根目录执行。脚本读取现有候选 DTB，用同一个 dtc 反编译输入和结果。它构造“只在目标节点加入 status”的预期文本，再与实际输出做完整 diff。所有生成文件及告警日志保留在本次独立的 output 子目录。<a :href="scriptFile" download="check-imx415-overlay.sh">下载复验脚本</a>和<a :href="exampleFile" download="disable-imx415-overlay.dts">下载 overlay 源文件</a>。

~~~bash
bash learning-site/examples/check-imx415-overlay.sh
~~~

本轮只在 `/i2c@21120000/imx415_0@1a` 新增 `status = "disabled"`。脚本失败时先看产物目录和 fdtoverlay 的报错。目标找不到就从反编译的路径确认父总线与节点名。若目标已带显式 status，则这一实验的“新增一行”前提不成立，应换对照基线。这个步骤只验证离线产物里的字段和范围。

`drivers/of/base.c:620`

~~~c
status = __of_get_property(device, "status", &statlen);
if (status == NULL)
	return true;

if (statlen > 0) {
	if (!strcmp(status, "okay") || !strcmp(status, "ok"))
		return true;
}
~~~

内核以这个判断筛选可用节点。没有 status 等同可用，disabled 不会进入正常的可用子节点枚举。更上层总线也必须能注册，且节点是否已对应运行设备还要到 sysfs 另查。

## 怎样核对启动现场采用了哪份描述？

| 证据层 | 查询什么 | 能支持的结论 |
| --- | --- | --- |
| 预处理与编译 | 顶层 DTS、include、编译命令和生成 DTB 路径 | 知道哪些文件参与形成输出 |
| 启动物料与引导 | 打包输入、镜像版本与引导选择 | 知道候选产物交到哪一份启动配置 |
| 活动树 | /sys/firmware/devicetree/base 下目标节点的 status、compatible、reg 和端点 | 知道本次内核看到的属性 |
| 运行对象与硬件 | client 的 of_node、driver、ID 日志及媒体图 | 知道内核创建与探测到哪一层 |

真实适配从板修订、供电和引脚表出发，再选择 DTS、实际安装的同地址 sensor 和配套驱动。完成后按活动树、client、读 ID、媒体图、首帧依次取证。编译器能编码属性，也能发现部分描述问题。供电电压和排线方向要另查图纸、模组手册或测量。

## 本节复盘

1. 几处 reg 含义为什么不同？逐个说明谁规定参数结构、谁消费数值。
2. DTS 写了 label，反编译只看到数字，怎样找到对应节点？
3. 候选 DTB 里禁用了 sensor，板端却还有 client。沿打包、启动选择和活动树列出检查步骤。
4. 编译通过后，哪些错误仍只能靠现场证据区分？

<a id="probe"></a>

下一节追活动节点怎样进入匹配，以及探测从哪里退出。[4.5 OF 匹配、probe、remove 与延迟探测](of-probe.md)
