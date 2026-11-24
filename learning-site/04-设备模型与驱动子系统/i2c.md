# 4.12 I2C 核心、控制器与 IMX415 client

<script setup>
import exampleFile from '../examples/i2c_register_read.c?url'
</script>

sensor 驱动想读 0x311a，CPU 不会直接访问传感器的寄存器。它提交两条 I2C 消息。控制器按字节把请求送到线上，驱动等待完成，再判断返回值是否可用。

## 先预测一条短传输

在 WSL 仓库根目录运行。这个 C 实验使用 Linux I2C UAPI 的消息结构，用内存模拟返回字节和消息数。<a :href="exampleFile" download="i2c_register_read.c">下载完整读寄存器实验</a>。

~~~bash
mkdir -p output
cc -std=c11 -Wall -Wextra -Wpedantic -Werror \
  learning-site/examples/i2c_register_read.c -o output/i2c-register-read
./output/i2c-register-read
~~~

本轮两条消息均完成时，单字节回复得到 0xe0，两字节回复得到 0x1234。仅完成 1 条和底层返回 −ETIMEDOUT 都变为 −EIO，输出仍是哨兵 0xdeadbeef。长度 0 在传输前就返回 −EINVAL。模型未打开 /dev/i2c-*，可在没有板子的环境复现。

## 从节点、消息走到 SCL 和 SDA

~~~text
I2C3 控制器 → 注册 adapter → 按板文件或活动树枚举 client
  → I2C core 匹配 sensor driver → probe → imx415_read_reg
  → 两个 i2c_msg → i2c_transfer → adapter 的 master_xfer
  → 控制器配置 FIFO 和寄存器 → SCL/SDA 上传输
  → IRQ 推进状态机，完成或超时通知等待者 → 返回消息条数或错误
~~~

| 数值 | 属于哪一层 |
| --- | --- |
| 0x1a | 传感器的七位总线地址。普通七位线上首字节为地址左移再加 R/W 位，写为 0x34、读为 0x35 |
| 0x311a | 传感器内部寄存器索引。第一条消息发送高字节 0x31，再发 0x1a |
| 0xe0 | 期望从数据读取阶段回来的字节 |

逻辑上的顺序是 START、地址写、寄存器两字节、重复 START、地址读、数据、主机 NACK、STOP。前面各寻址和写字节阶段另有应答位。最后读一字节后由主机发 NACK 表示结束。与地址阶段没有收到从机 ACK 的故障应区别。若上层由应用触发曝光或模式操作，也是先通过 V4L2 到 sensor 回调。上电读 ID 来自内核的 probe。

## 跟住三段关键代码

`drivers/media/i2c/imx415.c:1428`

~~~c
msgs[1].addr = client->addr;
msgs[1].flags = I2C_M_RD;
msgs[1].len = len;
msgs[1].buf = &data_be_p[4 - len];
~~~

client 提供地址和 adapter。第二条消息现场接收 len 字节，存到清零的四字节区域末端，方便最终按大端解释。

`drivers/i2c/i2c-core-base.c:2310`

~~~c
if (i2c_in_atomic_xfer_mode() && adap->algo->master_xfer_atomic)
	ret = adap->algo->master_xfer_atomic(adap, msgs, num);
else
	ret = adap->algo->master_xfer(adap, msgs, num);
~~~

通用层把传输发给这条 adapter 的 algorithm。在正常可睡眠路径上，Rockchip 控制器启动传输并等待 busy 清除，由中断更新状态。超时与传输错误另有退出路径。

`drivers/media/i2c/imx415.c:1433`

~~~c
ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
if (ret != ARRAY_SIZE(msgs))
	return -EIO;

*val = be32_to_cpu(data_be);
~~~

两条消息都完成才填调用者的输出。这里成功所需的 2 是消息数，和读取一个数据字节不矛盾。

## 九步源码跟读

| 顺序 | 观察内容 | 练习 |
| --- | --- | --- |
| [1–3 总线波形、地址和内核对象](i2c-wire.md) | SCL/SDA、重复起始、adapter/client/driver | 给 0x1a、0x311a 和 0xe0 各标状态与方向 |
| [4–6 枚举、匹配和双消息缓冲](i2c-probe.md) | board_info 与 DT、probe、消息长度和端序 | 画两条消息，比较完成 2 条、1 条以及返回负值 |
| [7–9 控制器、中断和分层定位](i2c-irq.md) | master_xfer、IRQ、等待条件和现场证据 | 分别给第一路与第二路写出判断及缺失证据 |

## 用本板两路历史日志验证推断

在仓库根目录执行，读取原厂启动历史。

~~~bash
rg -n 'imx415 [34]-001a:.*(Detected imx415 id|Unexpected sensor id)' output/camera-check/dmesg-before.log
~~~

第一路为 Detected imx415 id 0000e0。第二路为 Unexpected sensor id(000000), ret(-5)。第二路的 id 初值是零，helper 提前退出时未更新。现有行能说明 helper 没接受传输结果。要判断控制器超时、短传输、NACK 或未装第二颗，应补当次的底层返回值、装配与波形。第一路另有原厂帧文件作为数据链证据。

## 本节复盘

1. adapter 已注册、client 已出现、读到 ID、首帧出队，分别验证到哪一层？
2. 画出两条消息，给地址字节、内部寄存器与返回字节标出方向。哪一个 NACK 属于正常结束？
3. 规定两条消息只完成一条，为什么输出值可能保持原样？打印零时怎样判断是否实际读到了零？
4. 分别指出控制器传输成功和 ISP 给应用返回图像所需的证据。

下一卷从一块未适配的新板开始，把控制链、像素链和应用缓冲列进同一张移植清单。[5.1 接手未适配模组，先写移植清单](../05-相机驱动实践/module-checklist.md)
