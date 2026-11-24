# 4.6 pinctrl 子系统

<script setup>
import exampleFile from '../examples/inspect-camera-pins.sh?url'
</script>

一块芯片的同一个 pad 可能接到 UART、时钟或 GPIO。驱动的时钟控制器已打开输出时，信号仍要经过正确的 pad 路由才会到达板上。pinctrl 将这层路由及电气属性组织成消费者可以按名字选择的状态。

## 先沿 phandle 找到真正选中的组

在 WSL 仓库根目录用本地 SDK 的 dtc 读取候选 DTB。脚本打印两个消费者的状态引用和三个候选组的配置。<a :href="exampleFile" download="inspect-camera-pins.sh">下载候选 DTB 检查脚本</a>。

~~~bash
bash learning-site/examples/inspect-camera-pins.sh pinctrl
rg 'imx415 3-001a:.*(pinstate|Detected imx415 id)' output/camera-check/dmesg-before.log
~~~

本轮 I2C3 的 default 指向 0xa0，匹配 i2c3m1-pins。IMX415 的 default 指向 0xa2，匹配 cam-clk0-pins。公共文件中的 i2c3m0-pins 仍存在，phandle 为 0x2cb，但当前引用选了 m1。数字属于这份编译结果，换 DTB 须重新核对。

在 `rv1126b-pinctrl.dtsi` 中，每条 rockchip,pins 用 bank、bank 内偏移、复用值、pinconf 引用四格。它们由厂商 pinctrl provider 解释。

| pad | 选中的用途和复用值 | 电气配置 | 谁选择、何时生效 |
| --- | --- | --- | --- |
| GPIO4_A4／偏移 4 | I2C3 SCL，6 | pcfg_pull_none_smt | 控制器的 default，probe 前准备 |
| GPIO4_A5／偏移 5 | I2C3 SDA，6 | pcfg_pull_none_smt | 同一控制器状态，同组应用 |
| GPIO4_B1／偏移 9 | cam_clk0_out，3 | pcfg_pull_none | sensor 的 default，sensor 探测时路由到 pad |

若只改 I2C3 的 pinctrl-0，控制器资源、IRQ 或总线编号仍可能看起来正确，实际波形却可能送到了另一对 pad。先将最终 phandle 与原理图网名对照。若脚本找不到预期组，检查候选 DTB、节点路径和输出缩进，脚本不读取活动树。

## 从物理 pin 到状态

| 名词 | 描述什么 | 示例 |
| --- | --- | --- |
| pin | 控制器编号体系中的一个 pad | 一条数据线的单个 pad |
| group | 由 provider 定义的一组 pin | UART 的 TX/RX |
| function | 选择该组可连接的芯片内部功能 | UART 复用或 GPIO 功能 |
| pinconf | 与电气行为相关的设置 | 上拉、输入施密特、驱动能力 |
| state | consumer 一次要应用的一组设置 | default 或低功耗 sleep |

provider 用 pinctrl_desc 注册能力。pctlops 负责组及 DT 映射等描述，pmxops 负责功能选择，confops 应用电气参数。consumer 通过 pinctrl 句柄拥有一组按名查找的状态，核心将每项状态表示成可以逐项应用的 settings。这与板级节点引用哪个 group 是两个方向，先看 provider 支持什么，再看 consumer 选了什么。

源码摘录 `kernel-6.1/drivers/pinctrl/core.c:2172–2177`

~~~c
int pinctrl_register_and_init(struct pinctrl_desc *pctldesc,
			      struct device *dev, void *driver_data,
			      struct pinctrl_dev **pctldev)
{
	struct pinctrl_dev *p;

~~~

## 沿 DTS 查到实际寄存器回调

~~~text
consumer 的 pinctrl-names[i] / pinctrl-i → 配置节点 phandle
 → pinctrl_dt_to_map → provider 的 dt_node_to_map
 → core 汇入命名 state 的 settings
 → pinctrl_select_state → pinctrl_commit_state
 → mux: pinmux_enable_setting → provider set_mux
 → config: pinconf_apply_setting → provider pinconf 回调
~~~

源码摘录 `kernel-6.1/drivers/pinctrl/devicetree.c:200–205`

~~~c
int pinctrl_dt_to_map(struct pinctrl *p, struct pinctrl_dev *pctldev)
{
	struct device_node *np = p->dev->of_node;
	int state, ret;
	char *propname;
	struct property *prop;
~~~

DT 解析生成映射。选择具名 state 后，commit 路径才逐项提交。

源码摘录 `kernel-6.1/drivers/pinctrl/core.c:1247–1252`

~~~c
static int pinctrl_commit_state(struct pinctrl *p, struct pinctrl_state *state)
{
	struct pinctrl_setting *setting, *setting2;
	struct pinctrl_state *old_state = READ_ONCE(p->state);
	int ret;

~~~

遇到复用设置时走 pinmux 分支，其他电气配置由 pinconf 处理。

`drivers/pinctrl/pinmux.c:464`

~~~c
ret = ops->set_mux(pctldev, setting->data.mux.func,
				   setting->data.mux.group);
~~~

核心里的 func 和 group 是 provider 的查找索引，表示选哪种功能与哪组 pin。rockchip,pins 中的 6 或 3 是 pad 的复用值。两个层级的编号来自不同对象。

通用层传递组和功能编号。具体厂商回调负责写入 SoC 所需设置。

`drivers/pinctrl/pinctrl-rockchip.c:4447`

~~~c
for (cnt = 0; cnt < info->groups[group].npins; cnt++) {
	bank = pin_to_bank(info, pins[cnt]);
	ret = rockchip_set_mux(bank, pins[cnt] - bank->pin_base,
				       data[cnt].func);
	if (ret)
		break;
}
~~~

厂商驱动把组中的全局 pin 编号换成 bank 内偏移，再按每个 pad 的值写对应配置。任一项失败会结束当前循环，后续本地回退和核心状态恢复要分别核对。pinconf 在另一条分派路径上配置电气行为，例如输入施密特和上下拉。

脚位交给两个设备时，要回读 GPIO 或 mux 申请路径与 provider 的约束，解释冲突发生在哪一步。

## default 为什么经常没有显式 select？

device core 在 probe 前绑定 pinctrl，通常先选 init（若提供），否则选 default。成功 probe 后可在完成阶段切换 init 到 default。其他命名状态通常由框架的 PM 路径或驱动按需要使用，定义了 sleep 并不代表每个驱动都会在某个时刻自动应用它。先查是谁调用，再查选的是哪个名字。

`drivers/base/pinctrl.c:53`

~~~c
ret = pinctrl_select_state(dev->pins->p,
				   dev->pins->default_state);
} else {
	ret = pinctrl_select_state(dev->pins->p, dev->pins->init_state);
}
~~~

上一个条件判断是否取得 init。缺 init 直接使用 default，成功 probe 后也有把 init 切回 default 的收尾。IMX415 自己查的 rockchip,camera_default 与 rockchip,camera_sleep 属于驱动私有名。历史日志显示两个私有状态没找到，随后同一路读到了 e0。它们在源码里是两套查找。

## 如何把“已经配置”验证到板上

先从候选 DTB 找到目标 group。运行时再确认对应活动节点，读取有权限的 pinmux-pins、pinconf-pins 和 owner。最后在正确上电窗口核对时钟框架状态及模组端波形。一个 pad 可被用途冲突所占用，或成功选成时钟功能但时钟尚未开启。目前只核对候选描述与历史日志，当前 pad 状态和频率留待实测。

## 本节复盘

- **为什么设备树要有 pinctrl-0 和 pinctrl-names？** 索引将状态名称与一组 phandle 对应。一个状态可以组合多项配置，供框架一起应用。
- **pinctrl、GPIO 与 clock 分工是什么？** 复用与电气参数由 pinctrl 管理，GPIO 控制方向和电平，时钟框架选择频率并使能输出。实际 pad 波形取决于资源是否都满足。
- **为什么状态查找失败后设备仍然能用？** 先区分私有名称和 core 的标准 default 查找。历史 IMX415 日志有私有名称提示，第一路随后成功读到 ID。可分别查看 pinmux owner、时钟框架状态和引脚测量。

在 WSL 把下列四个函数画成箭头。查看各段源码，为每条箭头写出实际传递的对象。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'pinctrl_dt_to_map\(|pinctrl_commit_state\(' "$k/drivers/pinctrl/"{devicetree,core}.c
rg -n 'pinmux_enable_setting\(|rockchip_pmx_set\(' "$k/drivers/pinctrl/"{pinmux,pinctrl-rockchip}.c
~~~

下一节看切到 GPIO 功能以后，消费者怎样取得线和控制逻辑电平。[4.7 GPIO/gpiolib 子系统](GPIO子系统.md)
