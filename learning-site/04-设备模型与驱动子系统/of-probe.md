# 4.5 OF 匹配、probe、remove 与延迟探测

<script setup>
import exampleFile from '../examples/probe-paths.c?url'
</script>

有一个 IMX415 client，却没有稳定的 driver 链接。是驱动没选中、供应者没就绪、还是已经读设备但失败了？这三种情况要从不同入口找证据。

## 先预测错误在哪里变了

在 WSL 仓库根目录编译并运行。代码只模拟本版实现的几个分支，用来跟踪错误如何传递。<a :href="exampleFile" download="probe-paths.c">下载分支演算程序</a>。

~~~bash
mkdir -p output
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/probe-paths.c -o output/probe-paths
./output/probe-paths
~~~

| 输入 | 输出 | 对应边界 |
| --- | --- | --- |
| 总线没有匹配到这个驱动 | 无匹配 | 该候选的 probe 未执行 |
| 核心发现供应者没就绪 | EPROBE_DEFER | 可在 sensor 回调前返回 |
| 进回调后，时钟 getter 给出 EPROBE_DEFER | EINVAL | 本版 sensor 分支改写了错误 |
| regulator getter 给出 EPROBE_DEFER | EPROBE_DEFER | 本版 sensor 分支保留返回值 |
| 普通读 ID 不符 | ENODEV | 已进入硬件检查 |

它没有运行内核探测或制造硬件错误。以下逐步对照 SDK 源码和历史原厂日志。

## 两种注册顺序怎样走到同一入口？

~~~text
设备先注册 → 驱动进入总线 → driver_attach 遍历设备 ┐
                                                  ├→ 总线 match
驱动先注册 → 设备进入总线 → device_initial_probe ─┘
  → 核心依赖检查 → 总线 probe 包装 → imx415_probe
  → 消费资源、上电、普通路径读 ID → 注册 subdev → 运行 PM → 成功返回
~~~

上一节的 status 决定活动节点可否用于正常枚举。上一批确认的 I2C client 一旦创建，仍需与已注册驱动匹配。本地 IMX415 的 OF 表声明 sony,imx415。I2C 总线先走 OF 匹配，也可按 ACPI 和传统 ID 表规则寻找候选。

`drivers/i2c/i2c-core-base.c:146`

~~~c
if (i2c_of_match_device(drv->of_match_table, client))
	return 1;
~~~

返回 1 说明这个已登记驱动可尝试初始化当前 client。这个条件不发 I2C 消息。若运行环境没有设备或驱动，或绑定表不匹配，要先在固件、创建与注册的证据里定位。

<Sdk id="imx415-driver" />

## 谁决定等待供应者，谁能丢失错误码？

核心检查电源、时钟等设备链接时，可在进入驱动前就延迟。如果核心已放行，资源 getter 仍可能报告依赖暂缺。

`drivers/base/dd.c:600`

~~~c
link_ret = device_links_check_suppliers(dev);
if (link_ret == -EPROBE_DEFER)
	return link_ret;
~~~

这里的返回值是探测路径中的延迟信号。驱动探测入口的包装还会检查最终探测结果。检查正负两种形式与核心内部探测错误的包装约定有关。进入挂起列表后，供应者绑定事件等条件可触发重试。

`drivers/base/dd.c:815`

~~~c
ret = __driver_probe_device(drv, dev);
if (ret == -EPROBE_DEFER || ret == EPROBE_DEFER) {
	driver_deferred_probe_add(dev);
~~~

本版 IMX415 拿时钟失败时将错误指针统一转换为 EINVAL。如果底层给的是 EPROBE_DEFER，调用已经进入这个分支时，核心不能从这次返回得知原始原因。

`drivers/media/i2c/imx415.c:3238`

~~~c
imx415->xvclk = devm_clk_get(dev, "xvclk");
if (IS_ERR(imx415->xvclk)) {
	dev_err(dev, "Failed to get xvclk\n");
	return -EINVAL;
}
~~~

同一驱动获取 regulator 的失败分支原样返回 ret。还可遇到 GPIO 的警告后继续等路径。分析时先查看失败分支究竟退出、继续，还是跳到回退标签。本轮只核对行为，未修改 SDK。

<Sdk id="sensor-probe-resources" />

## 读 ID、失败回退与 remove 各在哪一层？

以下两条命令都在 WSL 根目录读现有文件。第一条从候选源码找关键阶段，第二条读同次原厂启动历史。若缺原始日志，参见卷四 4.1 的历史证据表。

~~~bash
sensor=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/drivers/media/i2c/imx415.c
rg -n 'devm_clk_get|imx415_configure_regulators\(imx415\)|imx415_check_sensor_id\(imx415|v4l2_async_register_subdev_sensor|err_clean_entity|imx415_remove' "$sensor"
rg -n 'imx415 [34]-001a:.*(Detected imx415 id|Unexpected sensor id)' output/camera-check/dmesg-before.log
~~~

历史第一路读到 e0，第二路记录 ret(-5) 与 id=0。因为 id 是先置零、传输成功时才填值，错误行不能证明 I2C 线上收到零。thunderboot 模式还存在跳过读 ID 的分支，判定本次是否实读时应看对应日志。

`drivers/media/i2c/imx415.c:3139`

~~~c
ret = imx415_read_reg(client, IMX415_REG_CHIP_ID,
			      IMX415_REG_VALUE_08BIT, &id);
if (id != CHIP_ID) {
	dev_err(dev, "Unexpected sensor id(%06x), ret(%d)\n", id, ret);
	return -ENODEV;
}
~~~

后续异步子设备注册还可能失败。错误的清理从已经完成的初始化阶段逆序执行。比如注册失败从 err_clean_entity 开始，随后关闭电源、释放控制项并销毁互斥锁。返回成功的实例在解绑时走 remove，它先撤销已经发布的子设备，然后走实体、控制和运行 PM 等清理。

<Sdk id="sensor-probe-cleanup" />

## 只凭现场现象，下一步分别查什么？

| 现象 | 下一条可区分的证据 | 结论边界 |
| --- | --- | --- |
| 有 client，没有 driver 链接 | 检查 /sys/bus/i2c/drivers、活动 compatible 和同次启动日志 | 缺链接可见于无匹配、初始化中、延迟或失败等场景 |
| 核心报告等待供应者 | 核对供应者的 sysfs 关系及绑定，有权限时查 debugfs 的 devices_deferred | 区分回调前等待及回调返回延迟 |
| 出现 Failed to get xvclk | 对照 clocks、clock-names、提供者及原始失败值 | 本版回调的 EINVAL 已丢失底层具体原因 |
| 读到正确 ID，尚无帧 | 核对后续注册、媒体拓扑、STREAMON 和缓冲完成 | 控制链已应答，像素链另取证 |

应用 open 针对已发布的文件节点及操作表，设备可能随后按运行 PM 恢复供电。它通常不重复进行总线匹配，也不调用整套 probe。此节未进行板端解绑或错误注入。

## 本节复盘

1. “匹配成功”“probe 返回成功”“首帧出队”分别需要什么证据？
2. 底层都给 EPROBE_DEFER，时钟和 regulator 分支为什么会有不同结果？
3. 读 ID 后子设备注册失败，哪些资源已取得？为什么不能直接照搬 remove？
4. 多次 open 都成功，从哪一层可以观察设备是否又上电？为什么 sysfs 链接无法回答每次打开的动作？

下一节跟读引脚功能和 pad 配置。[4.6 pinctrl 子系统](pinctrl子系统.md)
