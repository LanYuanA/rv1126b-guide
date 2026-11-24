# 4.8 Common Clock Framework

<script setup>
import exampleFile from '../examples/xvclk-divider.awk?url'
</script>

IMX415 的 DTS 里已经写了 xvclk。插座何时应看到 37.125 MHz 或 27 MHz？先验证本版候选时钟的来源，再从 consumer 跟到设置和使能。上一节的 pinctrl 负责把输出接到 GPIO4_B1，时钟框架负责让这路输出按所需频率工作。

## 核对模式请求和可行除数

在 WSL 仓库根目录运行。前两条路径定位 CRU 的时钟 ID 和输出；第三条核对模式和驱动调用。最后执行独立整数分频模型。<a :href="exampleFile" download="xvclk-divider.awk">下载分频演算</a>。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'CLK_MIPI0_OUT2IO' "$k/include/dt-bindings/clock/rockchip,rv1126b-cru.h"
rg -n 'CLK_MIPI0_OUT2IO|mux_600m_24m_p' "$k/drivers/clk/rockchip/clk-rv1126b.c"
rg -n '#define IMX415_XVCLK_FREQ_|\.xvclk =|clk_set_rate\(|clk_get_rate\(|clk_prepare_enable\(' \
  "$k/drivers/media/i2c/imx415.c"
awk -f learning-site/examples/xvclk-divider.awk
~~~

ID 为 109。例子假设 GPLL 按 SoC 公共 DTS 的 assigned-clock-rates 配为 1,188,000,000 Hz，且 clk_gpll_div2 实际采用除 2，于是候选父频为 594,000,000 Hz。对应目标除数是 16 与 22。两者均落在这个理想五位整数分频模型的范围内。另一候选父时钟 xin24m 无法通过整数分频得到这两个更高的值。真实父时钟及中间分频从运行时状态核对，名字中的 div2 和此模型不能证明当前寄存器值。

## DTS、时钟句柄与核心对象怎样对应？

| 一端的对象或属性 | 其责任 |
| --- | --- |
| sensor 节点的 clocks、clock-names | 按同一索引配对。xvclk 指向 CRU 的第 109 号输出 |
| CRU 节点、#clock-cells | 标明提供者及每个引用携带的参数数。此处参数是一格 ID |
| struct clk | 消费者持有的句柄，通过 CCF 访问所需时钟 |
| clk_core 与 clk_hw | core 维护父关系、速率和引用状态，hw 衔接 provider 的 ops |
| Rockchip 复合时钟 | 依据 mux、divider 和 gate 配置实现选择、变速与使能 |

~~~text
sensor clock-names="xvclk" → clocks 的对应索引 → &cru + 输出 ID
  → devm_clk_get → 取得消费者句柄
  → clk_set_rate → 框架选速及分配父时钟约束 → 提供者操作
  → prepare / enable → 输出可运行
  → pinctrl 的复用 → GPIO4_B1 → 板级线路 → 模组 XCLK
~~~

`drivers/clk/rockchip/clk-rv1126b.c:484`

~~~c
COMPOSITE(CLK_MIPI0_OUT2IO, "clk_mipi0_out2io", mux_600m_24m_p, 0,
				RV1126B_CLKSEL_CON(67), 11, 1, MFLAGS, 0, 5, DFLAGS,
				RV1126B_CLKGATE_CON(15), 3, GFLAGS),
~~~

这里指定了父列表、mux 位域、五位分频字段和 gate 位。理解宏的参数，应对照 Rockchip 的注册结构与对应实现。consumer 只按名字取得输出并提出频率要求，具体寄存器由时钟提供者管理。

## 设频、读回和使能各有什么分支？

`drivers/media/i2c/imx415.c:2628`

~~~c
ret = clk_set_rate(imx415->xvclk, imx415->cur_mode->xvclk);
if (ret < 0)
	dev_warn(dev, "Failed to set xvclk rate\n");
if (clk_get_rate(imx415->xvclk) != imx415->cur_mode->xvclk)
	dev_warn(dev, "xvclk mismatched\n");
~~~

请求来自当前模式的 Hz 值，不能从宏名中的 37M 猜准确数字。父时钟选择、可用分频和其他消费者约束会影响结果。这个版本即使设频报错或读回不一致也继续到 clk_prepare_enable。后者失败才跳转到本函数的回退路径。

<Sdk id="ccf-set-rate" />

`include/linux/clk.h:1072`

~~~c
ret = clk_prepare(clk);
if (ret)
	return ret;
ret = clk_enable(clk);
if (ret)
	clk_unprepare(clk);
~~~

prepare 可以做需要睡眠的准备工作，enable 回调按 CCF 的原子上下文约束执行。成对的 helper 在 enable 失败时回滚已经取得的 prepare 引用；成功路径在结束使用时用 clk_disable_unprepare 归还。句柄由 devm 管理，并不替代显式使能的引用配对。

`drivers/clk/clk.c:1192`

~~~c
if (core->enable_count == 0) {
	ret = clk_core_enable(core->parent);

	if (ret)
		return ret;
~~~

第一次使能要先使能父时钟，再调用本级 provider，成功后记引用。两个消费者都在使用同一时钟时，一次 disable 只归还一份；两个叶子输出共用父时钟时，关闭一个叶子也可能让父时钟继续为另一条路径服务。

## I2C 工作但读不到 ID，怎样验证 XCLK？

| 想确认的阶段 | 证据 | 边界 |
| --- | --- | --- |
| 找对资源 | 活动树的 clocks、clock-names 与 devm_clk_get 返回 | 说明找到哪个输出 |
| 框架采用何种频率与使能状态 | 该模式的请求值、clk_get_rate、可读时的 clk_summary | 说明框架观察的时钟树和引用 |
| 模组实际收到合格时钟 | 核对 pinmux 并在上电窗口测 B1 与插座 XCLK | 核对波形、幅值和时间关系 |

不要把 I2C 的 SCL 和传感器输入 XVCLK 当同一时钟。即使 SCL 有波形，仍需验证模组的 XCLK、电源和复位。当前只核对本地源码和分频可行性，板端父频、分频和波形均待测。

## 本节复盘

1. xvclk 名字和 ID 109 从哪读？为什么双方的名字不同也能匹配？
2. 父频是 594 MHz 时，如何复算两种目标频率？如果父频变成 600 MHz，原除数会给出什么？
3. prepare 成功而 enable 失败，引用怎样回退？共享父时钟为什么可能继续运行？
4. clk_summary 有速率，模组仍没有时钟，下一份证据从哪里取？

下一节把时钟放回供电和首次 I2C 的时间轴。[4.9 regulator 与供电时序](regulator.md)
