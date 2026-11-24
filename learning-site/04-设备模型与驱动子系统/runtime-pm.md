# 4.11 runtime PM 与系统休眠

<script setup>
import exampleFile from '../examples/runtime-pm-refs.awk?url'
</script>

应用只是打开视频节点，sensor 可能仍在休眠。应用停流后，sensor 也可能因另一个持有者仍然上电。先数引用，再分别判断可访问、正在出流和系统休眠。

## 跑一遍引用记账

在 WSL 仓库根目录执行。程序模拟普通路径的引用分支，把另一位使用者单独记一栏。<a :href="exampleFile" download="runtime-pm-refs.awk">下载引用模型</a>。

~~~bash
awk -f learning-site/examples/runtime-pm-refs.awk
~~~

第一次开流保留 1 份，重复开流仍为 1，停流归零。恢复失败和写寄存器失败各用不同方式回到 0。第二次成功开流时加入另一使用者，合计为 2，停流后仍剩 1。脚本为每步核对计数。这里假设打开 fd 的动作自身未取得 sensor 引用。实际媒体管线的 open、s_power 等需要独立查调用关系。

## 三种状态应该各记一行

| 状态 | 谁改变它 | 能说明什么 |
| --- | --- | --- |
| runtime usage_count | 各持有者 get/put | 还有多少运行电源引用。归零提供了尝试闲置的条件 |
| runtime_status | PM 核心和实际回调 | 设备在运行、挂起或转换中，另受策略、依赖和回调结果约束 |
| streaming | sensor 的 s_stream 及管线 | 软件记录的开停状态。真实像素仍要看接收端事件和缓冲 |

probe 普通路径为上电读 ID 做准备，注册成功后先告诉框架设备现在已 active，再启用运行时 PM，然后请求检查闲置。

`drivers/media/i2c/imx415.c:3325`

~~~c
pm_runtime_set_active(dev);
pm_runtime_enable(dev);
pm_runtime_idle(dev);
~~~

runtime_resume 调用 sensor 的 power_on，runtime_suspend 调用 power_off。上电只让硬件具备后续操作条件，开流还涉及模式表、控制值与退出 standby。usage_count 降到 0 后，是立即尝试、延后尝试还是因条件不具备而保持运行，要看调用和框架状态。autosuspend 需要额外策略与配对接口，普通 pm_runtime_put 本身不能确定某个固定延时。

<Sdk id="sensor-runtime-pm" />

## 为何 get_sync 返回错误也要减计数？

`drivers/base/power/runtime.c:1166`

~~~c
if (rpmflags & RPM_GET_PUT)
	atomic_inc(&dev->power.usage_count);

spin_lock_irqsave(&dev->power.lock, flags);
retval = rpm_resume(dev, rpmflags);
spin_unlock_irqrestore(&dev->power.lock, flags);
~~~

get_sync 传 RPM_GET_PUT，恢复前就增加计数。如果恢复失败，调用侧使用 put_noidle 配平，不发起新的闲置请求。这个版本还提供 pm_runtime_resume_and_get，将失败配平封装在 helper 内。这节跟读现有实现。

`drivers/media/i2c/imx415.c:2550`

~~~c
ret = pm_runtime_get_sync(&client->dev);
if (ret < 0) {
	pm_runtime_put_noidle(&client->dev);
	goto unlock_and_return;
}
~~~

成功后继续配置寄存器。这里失败时，取得的是有效运行引用，因此用普通 put 释放并让 PM 核心按策略处理之后的闲置。

`drivers/media/i2c/imx415.c:2556`

~~~c
ret = __imx415_start_stream(imx415);
if (ret) {
	v4l2_err(sd, "start stream failed while write regs\n");
	pm_runtime_put(&client->dev);
	goto unlock_and_return;
}
~~~

成功才更新 streaming。重复请求通过 mutex 内的状态比较直接退出。停流调用内部 stop 后释放引用，本版没有把 stop 的返回值传给上层。只有软件标志变化时，仍需验证器件是否停止发数据。

~~~text
开流请求 → 当前已开？是：直接返回
  → get_sync → 恢复失败：put_noidle
  → 写模式和启动 → 启动失败：put
  → 成功：保留引用并标记 streaming
停流请求 → 检查器件与采集管线停流 → 释放这一份引用 → PM 决定何时闲置
~~~

## 设备闲置与整机睡眠怎么区分？

设备闲置可能发生在系统仍正常运行时。整机 suspend/resume 由系统电源管理统一排序，设备绑定的系统回调与 runtime 回调有各自上下文。本地候选构建关闭了 CONFIG_VIDEO_CAM_SLEEP_WAKEUP。源码中相关条件满足时，IMX415 才有 late system sleep 回调，它可准备睡眠并在恢复后重写寄存器和控制值。板端运行配置需要核对对应启动镜像。

~~~bash
sensor=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/drivers/media/i2c/imx415.c
rg -n 'SET_RUNTIME_PM_OPS|SET_LATE_SYSTEM_SLEEP_PM_OPS|pm_runtime_(set_active|enable|idle|put_noidle)\(' "$sensor"
rg '^CONFIG_PM=|^# CONFIG_VIDEO_CAM_SLEEP_WAKEUP is not set' \
  atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal/.config
~~~

| 回归用例 | 观察证据 | 失败后先查 |
| --- | --- | --- |
| 同次启动反复开流、停流、再开 | 每轮返回值、runtime_status、首帧时间与序号 | 恢复是否成功，开流引用是否归还，寄存器是否重新配置 |
| 系统唤醒后重取首帧 | 记录休眠前后媒体拓扑、配置、生效回调与首帧 | 确认恢复路径是否存在及哪一步丢失资源或模式 |
| 有另一分支保活时停主流 | 核对持有者与每次归还的时间 | 分清剩余正常引用、策略延时与漏 put |

若能找到活动 client，可在有权限时读取其 power/runtime_status 等属性。单个采样无法证明何时执行了回调，要与开停事件在同一时间轴关联。本轮只验证模型与源码，未切换板端运行策略或执行系统休眠。

## 本节复盘

1. runtime_status 为 active，是否能推出正在产生像素？补哪两层证据？
2. get_sync 失败与写寄存器失败，谁来归还哪一份计数？
3. 最后一个应用 fd 关闭后，为什么 s_power 或另一管线仍可能保活？
4. 同一启动停开通过，为什么仍需单独验证整机唤醒后的首帧？

下一节沿 adapter、client 到线上两条消息，核对第一次 I2C 组合读。[4.12 I2C 核心、控制器与 IMX415 client](i2c.md)
