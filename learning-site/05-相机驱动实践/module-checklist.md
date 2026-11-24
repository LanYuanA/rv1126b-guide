# 5.1 接手未适配模组，先写移植清单

<script setup>
import exampleFile from '../examples/check-camera-reference.sh?url'
</script>

假设拿到一块 RV1126B 新板和一颗标有 IMX415 的模组，厂商尚未适配这个接口。目标先定为一个已知的线性模式，分阶段证明器件应答、媒体图匹配和应用取帧。

## 先遮住参考 DTS，填自己的清单

每个格子都记下来源和板修订。芯片型号相同时，模组上的稳压器、供电接口和连接器方向仍可能不同。

| 需要确认 | 先记录的输入 | 缺证据去哪里找 |
| --- | --- | --- |
| PCB 修订、模组料号、FPC 脚序与方向、镜头 | 芯片型号 IMX415，另记新板与模组版本和镜头 | 实物丝印、同修订原理图、连接器和模组图纸 |
| 电源、RESET、XCLK | 每条轨的电压容限、复位极性与准备时间、频率及可达 pad | 两端资料和测点，查电平转换、反相与电源开关 |
| I2C | 用哪条总线、上拉电压、七位地址、同地址装配 | 原理图、模组手册、候选树和活动树 |
| CSI-2 | 两端的时钟对、数据对、lane 数、次序和极性 | 接线表、模组模式能力、接收端 binding 及驱动 |
| 输出 | 固定先验收线性的一种位深和帧率，分别记录 sensor 与 ISP 格式 | 模式表、接收端配置和运行时协商结果 |

供电电压、接插件方向和引脚映射没确认时，先停在资料与接线核对。首次部署前，还需要确认引导器选择与原厂恢复条件。

~~~text
控制链：CPU → adapter → SCL/SDA → sensor 寄存器
像素链：sensor → CSI-2/D-PHY → CSI 接收器 → CIF → ISP
返回链：ISP → DMA 缓冲 → VB2 → DQBUF → 应用检验图像
~~~

三条链各留一个边界证据。控制链读出 ID 后，还需观察媒体链和返回链。

## 揭开参考节点，校对最小改动范围

在 WSL 仓库根目录运行，只读取本地 SDK。把对照结果填在原清单旁边，标出属性归属的设备。

~~~bash
sdk=atk_dlrv1126b_linux6.1_sdk
tree="$sdk/kernel-6.1/arch/arm64/boot/dts/rockchip"
rg -n -A15 '^&i2c3 ' "$tree/rv1126b-alientek.dtsi"
rg -n 'imx415_out0|csi_dphy_input0|csi2_dphy0|rkisp_vir0' "$tree/rv1126b-alientek.dtsi"
rg -n -A5 '^config VIDEO_IMX415' "$sdk/kernel-6.1/drivers/media/i2c/Kconfig"
~~~

第一路参考采用 I2C3 和 0x1a，I2C3 走 GPIO4_A4/A5，XCLK 走 GPIO4_B1。板级文件声明 RESET 低有效、POWER 高有效。新板若更换供电开关、pad 或模组地址，按原理图重新确认。厂商公共描述含同地址候选节点，新板的最终 DTB 应核对实际启用的器件。

像素链要对照两端。以下接收端的 reg 给 endpoint 编号，remote-endpoint 指回 sensor 端。本地候选的 DPHY 接收配置描述了四条 data lane。实际要逐段检查接收端支持的 lane 数、速率、通道和位深，以及 CSI、CIF、ISP 路由。

`arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi:414`

~~~text
csi_dphy_input0: endpoint@1 {
	reg = <1>;
	remote-endpoint = <&imx415_out0>;
	data-lanes = <1 2 3 4>;
};
~~~

`drivers/media/i2c/Kconfig:810`

~~~text
config VIDEO_IMX415
	tristate "Sony IMX415 sensor support"
	depends on I2C && VIDEO_DEV
	depends on MEDIA_CAMERA_SUPPORT
	select MEDIA_CONTROLLER
	select VIDEO_V4L2_SUBDEV_API
~~~

选项决定驱动参与构建。若现有驱动支持所需模式和供电接口，首版候选可只改板级 DTS、接收端配置和必要的构建选项。若驱动不满足模组条件，先写清缺的是属性、上电顺序、时钟还是模式，再决定代码改动点。

## 分别保存候选构建和原厂运行证据

在 WSL 仓库根目录运行。脚本读取现有候选 DTB 和原厂历史文件。若个人检出缺少这些本地文件，先标记待取得，仍可用上面的源码命令。<a :href="exampleFile" download="check-camera-reference.sh">下载基线证据查询</a>。

~~~bash
bash learning-site/examples/check-camera-reference.sh
~~~

本轮候选有 CONFIG_VIDEO_IMX415=y，脚本单独打印了候选 DTB 的 SHA-256。另一组运行证据来自原厂 Linux 6.1.141。第一路 3-001a 读到 0xe0，同批保存 31 条出队记录和一个 12,441,600 字节的 NV12 帧文件。这个大小与紧排 3840×2160 NV12 相符，换分辨率、stride 或格式应再核对。要确认原厂当时采用哪份 DTB，仍需部署或活动树证据。历史短采集也无法推出新板长期稳定性。

## 把每个阶段变成一个验收点

| 阶段 | 留什么证据 | 若缺失先查 |
| --- | --- | --- |
| 准备候选 | 板修订与端点清单、最小差异、Kconfig、编译和反编译结果、DTB 哈希 | 顶层 DTS、include、资源依赖 |
| 准备恢复 | 引导与打包选项、原厂镜像来源、可用的恢复方式 | 当前实际启动项和恢复入口 |
| 确认本次启动选树 | 活动节点和对应的 of_node | 启动物料、选项和 overlay |
| 验证控制链 | client、稳定绑定、普通路径的读 ID | 启用、总线、电源、复位、时钟、应答 |
| 验证像素链 | 媒体图、两端格式和开流结果 | 端点互指、lane、接收路由与模式 |
| 应用得到一帧 | 节点身份、出队 sequence、bytesused、stride 和图像预览 | 队列、DMA、格式和帧完成 |

本轮核对清单、候选和历史文件。新板的物理条件、启动与恢复待现场验证。构建与离线检查用[本地编译](../01-开发环境/build.md)及[反编译对照](../04-设备模型与驱动子系统/devicetree.md#dtb)。

## 本节复盘

1. 同是 IMX415，换另一块板的 DTS 哪些属性最不能直接抄？分别举出接线、供电和媒体链的例子。
2. 返回 e0 后，为什么还不能判断 ISP 图像质量？哪条链仍需取证？
3. 候选 DTB 哈希与历史出帧文件各说明什么？怎样再确认启动时采用的描述？
4. 如果最先缺失的是 client，先查哪些条件？为什么曝光寄存器与这个阶段无关？

下一节按本版实际分支跟读上电、复位和读 ID。[5.2 第一次上电、复位、XCLK 与读 ID](first-power-id.md)
