# 4.9 regulator 与供电时序

<script setup>
import exampleFile from '../examples/imx415-power-timing.awk?url'
</script>

驱动拿到 dvdd、dovdd、avdd 三个 regulator 句柄，模组就一定通电了吗？先对照真实的历史日志和代码里的延时，再区分供电提供者、使能信号和物理电源轨。

## 从代码参数和历史日志建立对照

在 WSL 仓库根目录运行。第一条定位供电名与本版上电分支，第二条读本地原厂启动记录。最后一条只加总普通路径上的睡眠请求。<a :href="exampleFile" download="imx415-power-timing.awk">下载时序演算</a>。

~~~bash
sensor=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/drivers/media/i2c/imx415.c
rg -n 'imx415_supply_names|regulator_bulk_enable|usleep_range\((10|20) *\* *1000' "$sensor"
rg 'imx415 3-001a:.*(supply|Detected imx415 id)' output/camera-check/dmesg-before.log
awk -f learning-site/examples/imx415-power-timing.awk
~~~

本轮对照到原厂第一路的三个 supply 都使用 dummy，之后同一路仍成功读 ID。三段睡眠参数加总按下限到请求上限为 **40～70 ms**。它没有计入操作本身的耗时、内核调度延迟或实际稳压器上升时间，也无法从历史 ID 日志推得各轨稳定时刻。

## provider、consumer、板级使能线各管什么？

| 对象或资源 | 它代表什么 | 实际要查 |
| --- | --- | --- |
| regulator provider | 物理电源的框架表示，可为固定式或可调式，也可能有 enable 资源 | 上游来源、额定电压约束、开关与稳定延时 |
| regulator consumer | 某设备取得的一份供电句柄以及本次使用引用 | 电源名称、对应 provider、使能配对 |
| power GPIO | 一条板级控制线，可能连到电源开关或其他控制电路 | 模组原理图上的目的位置、极性、受它控制的电源范围 |
| dummy regulator | 满足特定条件时给出的软件替代对象 | 日志、实际固定供电与缺失的板级描述 |

名字一般对应 `dvdd-supply`、`dovdd-supply` 和 `avdd-supply`。供电属性的 phandle 引用真实电源提供者。固定电压的电源也可能受 GPIO 使能。有些始终上电，有些要等开关或上游准备。本文未假设本板这三条电源的实际电压，需按模组资料与测点核对。

`drivers/media/i2c/imx415.c:3155`

~~~c
for (i = 0; i < IMX415_NUM_SUPPLIES; i++)
	imx415->supplies[i].supply = imx415_supply_names[i];

return devm_regulator_bulk_get(&imx415->client->dev,
				       IMX415_NUM_SUPPLIES,
				       imx415->supplies);
~~~

bulk get 给每项填 consumer 句柄。devm 管理对象引用的释放，上电和断电仍需要对应的 enable、disable 操作。对单路电源，如果第一次使用且还存在上游 supply，核心也会处理上游引用。共享电源仍有其他消费者时，一份 disable 不一定关闭输出。

## 为什么不能把 bulk 顺序直接当成三条轨的顺序？

`drivers/regulator/core.c:4971`

~~~c
for (i = 0; i < num_consumers; i++) {
	async_schedule_domain(regulator_bulk_enable_async,
				      &consumers[i], &async_domain);
}

async_synchronize_full_domain(&async_domain);
~~~

这里将每项使能提交到异步域，再等待该域完成。之后逐项检查返回值，有任何失败就尝试关闭本次已开启的项。数组顺序不能据此解释成物理轨的严格上升顺序。如硬件明确要求先后，驱动及供电依赖应据约束表达。正常的 bulk disable 从末项倒序处理，遇错误尝试恢复已关闭项。

源码摘录 `kernel-6.1/drivers/regulator/core.c:4964–4969`

~~~c
int regulator_bulk_enable(int num_consumers,
			  struct regulator_bulk_data *consumers)
{
	ASYNC_DOMAIN_EXCLUSIVE(async_domain);
	int i;
	int ret = 0;
~~~

dummy 分支在找不到供应者且符合条件时可提供替代对象。得到它不意味着软件操作真实稳压器。应区分模组使用板上固定电源、固件省略实际可控电源描述，以及查找曾因依赖未就绪返回错误。历史日志只能确认当时命中了 dummy 路径。

## 给普通上电标一条有测点的时间轴

~~~text
选择可用的私有 pinctrl
  → 请求 POWER 逻辑 1
  → 请求睡眠 10～20 ms → 请求 RESET 逻辑 0
  → 请求睡眠 10～20 ms → 请求 XVCLK 速率及使能
  → regulator_bulk_enable 成功
  → 请求睡眠 20～30 ms → 返回上层，普通 probe 才尝试读芯片 ID
~~~

`drivers/media/i2c/imx415.c:2644`

~~~c
ret = regulator_bulk_enable(IMX415_NUM_SUPPLIES, imx415->supplies);
if (ret < 0) {
	dev_err(dev, "Failed to enable regulators\n");
	goto err_pinctrl;
}
~~~

回退分支关已开启的时钟，然后请求复位和可用的 sleep 状态。这个标签链未显式把 power_gpio 设回逻辑 0，需要与正常 power_off 路径区分。诊断时按当时走过的分支核对各资源状态。上电函数还有 thunderboot 分支，跳过部分常规动作。注释写了 20 µs，实际末尾 `usleep_range(20*1000, 30*1000)` 用的是微秒参数，故代码请求是 20～30 ms。

| 需要核对 | 测点或证据 | 当前进度 |
| --- | --- | --- |
| 三条供电从哪来、何时稳定 | 对照板修订与模组手册，记录各轨测点、幅值、上升时间 | 历史日志只有 dummy 与后续响应 |
| POWER、XCLR、XCLK 的顺序 | 在同一采样窗口观察 SoC 和模组端相关信号 | 源码顺序已核对，硬件电平与波形待查 |
| 第一笔通信是否留足准备时间 | 将首次 SCL START 和各轨稳定时点放在同一时间轴，按手册限值比较 | 当前只有历史读 ID 结果 |

如果读 ID 失败，先保留明确的错误阶段和调用返回。硬件供电尚未验证时，不能拿示波器以外的框架计数判断实际电压。检查测点与电路依据之后再确定需要哪项板端验证。

## 本节复盘

1. dvdd-supply 指到固定电源，driver 仍调用 enable，这两者怎样配合？
2. dummy 和读 ID 成功同时出现，哪些解释都说得通？该从哪里找证据？
3. bulk enable 的数组与并发行为怎样影响时序判断？报错时谁回滚哪一层？
4. 代码请求的睡眠区间如何换算？为什么要把 XCLR、时钟、轨稳定与首个 START 画在同一时间轴上？

下一节从 XCLR 和 SoC 模块复位的不同资源开始。[4.10 reset controller 与复位 GPIO](reset.md)
