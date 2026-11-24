# I2C 下篇　谁唤醒读取线程，怎样用两路日志定位故障

中篇把两个 `i2c_msg` 交给了 `i2c_transfer`。这时传感器驱动需要等到什么时候？它手上的四字节暂存区在栈上，何时才能相信数据已经填好，安全地返回调用者？本篇沿本机 SDK 的普通、中断驱动的寄存器读路径走一遍，再用本板的两路启动日志做诊断。[回看消息和返回值](i2c-probe.md)

## 7. 一次函数调用怎样跨过硬件和中断

### 从函数名走到控制器的 MMIO 寄存器

在 WSL 项目根目录执行下面三次查找，分别定位 I2C core 通过操作表调用的那一行、Rockchip 填进表的函数，以及控制器处理一短写加一读的分支。返回的路径和行号都是 SDK 源码位置。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rk="$k/drivers/i2c/busses/i2c-rk3x.c"
rg -n 'ret = adap->algo->master_xfer\(|ret = __i2c_transfer\(' "$k/drivers/i2c/i2c-core-base.c"
rg -n '\.master_xfer\s*=|return rk3x_i2c_xfer_common\(adap, msgs, num, false\)' "$rk"
rg -n 'static int rk3x_i2c_setup|reg_addr \|= msgs\[0\].buf|reg_addr, REG_MRXRADDR|i2c->msg = &msgs\[1\]' "$rk"
~~~

`i2c_transfer` 取得总线段的锁，再交给 `__i2c_transfer`。提交两条消息为一组，内核其他使用同段锁的传输者就不会在这两条消息中间插入自己的事务。core 在普通上下文调用 `adap->algo->master_xfer(adap, msgs, num)`。本板操作表指向 `rk3x_i2c_xfer`，它传 `false` 进入 `rk3x_i2c_xfer_common` 的非轮询分支。core 还能在仲裁丢失等返回 `-EAGAIN` 时作有限重试。要判断一次逻辑读取对应几次总线尝试，需要更靠近硬件的证据。

源码摘录 `kernel-6.1/drivers/i2c/i2c-core-base.c:2313–2318`

~~~c
	ret = adap->algo->master_xfer(adap, msgs, num);

if (ret != -EAGAIN)
	break;
if (time_after(jiffies, orig_jiffies + adap->timeout))
	break;
~~~

核心管理调用和重试等公共行为。adapter 的算法表把事务交到 Rockchip 实现。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:1813–1818`

~~~c
	.master_xfer		= rk3x_i2c_xfer,
	.master_xfer_atomic	= rk3x_i2c_xfer_polling,
	.functionality		= rk3x_i2c_func,
};

static const struct rk3x_i2c_soc_data rv1108_soc_data = {
~~~

`rk3x_i2c_setup` 能识别本例的“两条消息、首条为小于四字节的写、次条为读”。寄存器号的两个字节已在 `msgs[0].buf` 中。驱动按 `buf[i] << (i * 8)` 把它们放进控制器的 `REG_MRXRADDR` 字段，各字节另带有效位。`REG_MRXADDR` 放器件地址及有效位。`i2c->msg = &msgs[1]` 保留读缓冲，控制器负责前面的短写。`rk3x_i2c_setup` 此时返回 2，意思是已经为**这两条**做了准备。对上层正式报告成功还要等硬件完成。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:1426–1431`

~~~c
static int rk3x_i2c_setup(struct rk3x_i2c *i2c, struct i2c_msg *msgs, int num)
{
	u32 addr = (msgs[0].addr & 0x7f) << 1;
	int ret = 0;

	/*
~~~

**看似颠倒的一道读码题。** 假设 `buf[0]=0x31`、`buf[1]=0x1a`，忽略有效位，`MRXRADDR` 的低 16 位是多少？只取表达式的数值，是 `0x1a31`。但第一个要发送的字节装在最低八位，仍然先发 `31`。MMIO 寄存器的**字段布局**和导线上的**字节顺序**各有各的定义。控制器的 `i2c_writel` 最终使用 `writel(value, i2c->regs + offset)` 写本 SoC 的寄存器。传感器内部的 `0x311a` 则随 I2C 消息传到芯片，两者处在不同地址空间。

### 画出等待的线程与响应的硬件

`rk3x_i2c_probe` 映射控制器的寄存器区，经 `platform_get_irq` 取得 Linux IRQ，再用 `devm_request_irq` 登记 `rk3x_i2c_irq`。准备一笔事务时，`setup` 设置 `busy=true`，初始化进度与错误字段。读 ID 只有一字节，本版用于读的 DMA 缓冲选择设有 65 字节门槛，这一短读可按 FIFO 路径阅读。FIFO 是控制器里临时收发字节的小缓冲。下图按普通成功路径归纳时序，具体中断次数及是否由硬件自动停止随控制器能力而变。

~~~text
执行这次读的线程           控制器寄存器 / 导线          IRQ 处理
setup 置 busy=true
写启动配置并发 START ──→ 控制器完成寻址、发送 31 1a
                        重复起始、读回数据
等待条件 !busy          完成或错误状态置位 ─────────→ 读取 REG_IPD 和当前状态
                                                   处理接收 / STOP
                                                   向 msgs[1].buf 交付数据
                         等待条件成立  ←──────────── busy=false，唤醒等待者
继续执行，检查超时与 error
正常返回消息数 2 ──→ sensor helper 转成整数 ID，返回 0
~~~

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:1965–1970`

~~~c
i2c->regs = devm_platform_ioremap_resource(pdev, 0);
if (IS_ERR(i2c->regs))
	return PTR_ERR(i2c->regs);

/*
 * Switch to new interface if the SoC also offers the old one.
~~~

控制器初始化阶段准备资源；真正遇到传输时才执行 start。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:626–631`

~~~c
static void rk3x_i2c_start_fifo(struct rk3x_i2c *i2c)
{
	u32 val = i2c_readl(i2c, REG_CON) & REG_CON_TUNING_MASK;
	bool auto_stop = rk3x_i2c_auto_stop(i2c);
	unsigned long flags;
	unsigned int offset;
~~~

启动总线动作后，调用线程按条件等待控制器结束。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:1585–1590`

~~~c
	timeout = wait_event_timeout(i2c->wait, !i2c->busy,
				     msecs_to_jiffies(xfer_time));
} else {
	disable_irq(i2c->irq);
	rk3x_i2c_start(i2c, polling);

~~~

等待方只检查驱动状态。结束路径服务 IRQ 并发布完成条件。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:880–885`

~~~c
static void rk3x_i2c_handle_stop(struct rk3x_i2c *i2c, unsigned int ipd)
{
	unsigned int con;

	if (!(ipd & REG_INT_STOP)) {
		rk3x_i2c_stop(i2c, -EIO);
~~~

把 `rk3x_i2c_xfer_common` 普通路径的三行放在一起看。若把最后两行简单替换成固定延时，快速设备白等，慢设备又可能没完成。源码中的 `timeout` 是等待宏的结果。成功、错误还要读控制器状态才能区分。

~~~c
			rk3x_i2c_start(i2c, polling);

			timeout = wait_event_timeout(i2c->wait, !i2c->busy,
						     msecs_to_jiffies(xfer_time));
~~~

沿图观察三点，就已经在学内核底层。

1. **锁保护谁。** 传输路径用 `spin_lock_irqsave` 保护被线程和 ISR 同时访问的控制器状态，启动和等待前有对应的解锁。总线段锁解决不同事务之间的排序，控制器自旋锁解决线程与中断之间共享字段的并发，两者保护的对象不同。
2. **怎样睡，怎样醒。** `wait_event_timeout(i2c->wait, !i2c->busy, …)` 等一个可复查的条件。硬件快到在线程真正睡下前已完成，也能由条件直接通过。正常收尾会先更新 `busy`，再通过 `rk3x_i2c_wake_up` 唤醒。普通线程可以在这里睡眠，硬中断处理代码需要及时处理状态并返回。唤醒只是让等待者可继续调度，不保证它立刻占到 CPU。[复习中断与并发锁](../03-Linux内核/interrupts.md)
3. **怎样交付结果。** 在完成/失败之后，线程检查 `timeout` 和 `i2c->error`。等待超时的路径打印 `ipd` 和 `state`，报告 `-ETIMEDOUT`。ISR 对未被忽略的接收 NACK 可设置 `-ENXIO`。正常仅在传输完成后把消息数返回给 sensor。同步接口给调用者的保证解释了为何本例可以使用调用期间有效的栈缓冲。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:918–923`

~~~c
static irqreturn_t rk3x_i2c_irq(int irqno, void *dev_id)
{
	struct rk3x_i2c *i2c = dev_id;
	unsigned int ipd;

	spin_lock(&i2c->lock);
~~~

**对照完成时刻。** 请在图上分别标出寄存器准备完毕、等待条件满足、调用者已得到有效 `id`。如果只抓到了 `setup` 的返回值 2，能证明哪一个？只能证明在此路径上备好了两个消息，还缺硬件完成以及 helper 对结果的交付。

## 8. 按最早缺失的证据排错

先想象你打开了一份“相机没图”的工单。直接调整 MIPI 时序，很难知道改动是否碰对了问题。下面每行只前进一道门槛。到第一道缺证据的地方停下来，记录一条能区分两种解释的观察。

| 当前现象 | 两种可能的解释 | 下一项最小观测 | 能把问题缩到哪里 |
| --- | --- | --- | --- |
| 看不到预期的 adapter | 控制器节点未启用，或运行系统给了不同总线号 | 看活动树中控制器 `status`、各 adapter 的 `name` 和 `device/of_node` 或父设备路径，对应到 `i2c@21120000` | 是否已走过控制器注册，及所查对象是否正确 |
| 能看到 client，未找到 driver 链接 | 没有合适驱动匹配，或已经进 probe 后失败 | 核对该实例的 `of_node/compatible`、驱动目录和带总线前缀的早期日志 | 区分匹配之前、资源获取、ID 检查等阶段 |
| 打印 `Unexpected sensor id` | 传输未完整，或传输完整但读到不同值 | 同时记录 `id` 与 `ret`，保留控制器的超时/中断状态、首次错误时间 | 若 `ret=-5`，上层已折叠原因。若 `ret=0`，这两条消息已完成，回查地址、寄存器和实际模组 |
| ID 已正确但应用没有帧 | 传感器未开始输出，或接收端/媒体链接/缓冲没有完成 | 先看 media graph、启用的 link、两端格式和已有应用的队列或帧序号记录 | 转到 CSI、CIF/ISP、VB2。控制总线的 ACK 无法证明接收端已有像素 |

以下是**下一次板端复核时**的只读命令，供已经选定目标且普通 `adb` 能通的 WSL 终端使用。先用 `adb devices -l` 确认一台目标。若沿用本工作区既有 Windows ADB 服务，将命令开头换成 `adb.exe -P 5038`。下面的分析使用之前保存的启动日志。

~~~bash
adb devices -l
adb shell 'ls -d /sys/bus/i2c/devices/i2c-*'
adb shell 'p=/sys/bus/i2c/devices/3-001a; ls -ld "$p" "$p/driver"; readlink -f "$p/of_node"; tr "\000" "\n" < "$p/of_node/compatible"; od -An -tx1 "$p/of_node/reg"'
adb shell 'dmesg | grep -E "imx415 (3|4)-001a:|timeout, ipd:" | tail -40'
~~~

读 `reg` 时可能看到 `00 00 00 1a`。这是 DT 属性的一格 32 位大端编码，交给 core 后解释为器件地址 `0x1a`。它与芯片内部寄存器号的两字节编码是两套规则。若读不到日志，先记录是权限错误、日志缓冲已覆盖，还是过滤词未命中，分别处理。这里的命令只读系统已经暴露的证据。

**若手上有逻辑分析仪。** 先从原理图找到目标连接器的 SCL、SDA、地和相应 I/O 电压域，再按仪器输入范围接地、选阈值和采样率。应在被测设备正常执行这笔事务时触发起始，不额外争用地址。观察顺序是空闲电平、START、寻址后第九拍、寄存器字节、重复起始、最后数据字节。若控制器报超时，记录两根线哪根一直低以及同时的控制器状态。引脚复用、上拉/供电、复位状态、连接与时钟都可能影响观测。记录到“寻址后 SDA 没被拉低”比推测“排线坏了”多保留了一层可验证信息。[Linux 6.1 I2C 错误码语义](https://docs.kernel.org/6.1/i2c/fault-codes.html)

<details>
<summary>节点存在，读 ID 得到 -5，为何第一步不重刷设备树？</summary>

先确认当前活动树里的总线、地址和模组与装配是否一致。节点存在已经缩小了枚举范围。`-5` 说明这份 sensor helper 没有接受底层传输结果。此时重刷会改变基线，还没有把错地址、未供电、控制器超时、传输不完整区分开。合理的下一步是保留原始日志、验证活动配置，若仍有两个电气假设无法区分，再决定测哪一根线。

</details>

## 9. 用本板两路记录做一次答辩

### 先取历史记录，不要把两个接口混在一起

这段命令在本项目 WSL 根目录离线运行。它只读先前使用原厂内核采集时保存的启动日志。只克隆学习站的读者，可以用下面摘出的两条原文做相同练习。可重复生成的学习材料和板上原始记录各有自己的用途。

~~~bash
rg -n 'imx415 [34]-001a: (Detected imx415 id|Unexpected sensor id)' \
  output/camera-check/dmesg-before.log
~~~

~~~text
549:[    3.005832] imx415 3-001a: Detected imx415 id 0000e0
567:[    3.077805] imx415 4-001a: Unexpected sensor id(000000), ret(-5)
~~~

先盖住第二行右边的 `ret`，只看 `000000`。你会如何区分“器件回了 0”和“驱动从未拿到有效数据”？再露出 `ret(-5)`，对照中篇的 C 实验。出错时实验的哨兵仍为 `deadbeef`，实际驱动却打印 `000000`，两者完全可以由同一条提前返回路径解释。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:3127–3132`

~~~c
static int imx415_check_sensor_id(struct imx415 *imx415,
				  struct i2c_client *client)
{
	struct device *dev = &imx415->client->dev;
	u32 id = 0;
	int ret;
~~~

读到 ID 只验证控制链。向媒体框架发布子设备还有独立的成功和错误分支。

源码摘录 `kernel-6.1/drivers/media/i2c/imx415.c:1408–1413`

~~~c
static int imx415_read_reg(struct i2c_client *client, u16 reg, unsigned int len,
			   u32 *val)
{
	struct i2c_msg msgs[2];
	u8 *data_be_p;
	__be32 data_be = 0;
~~~

| 原始观测 | 在这次开机中可以说明什么 | 要继续推断还需要的证据 |
| --- | --- | --- |
| `3-001a … Detected … e0` | 与这版正常 `check_sensor_id` 的成功路径一致，读到的 ID 与期望相符 | 帧是否到达要看媒体拓扑和采集完成记录 |
| `4-001a … 000000, ret(-5)` | 已经走到 ID 检查，helper 报 `-EIO`。在本版源码里，失败时 `id` 保持初始值 0，就会打印这行 | 它无法区分短传输、NACK、超时。还需同次控制器证据、第二接口的实际装配和电气状态 |
| 第一路另有历史采集产物 | 该次曾获得 3840×2160 的 NV12 图像，属于数据链的独立证据 | 不能把第一路帧、第二路错误或其他启动模式的结论互相套用 |

有本工作区采集产物时，可额外核对第三行。下面读保存的结果并计算**本尺寸下紧密排列的 NV12 单帧**应占多少字节。4:2:0 的 Y 平面每像素一字节，交错 UV 平面合计为 Y 的一半。其他格式或带 stride 填充的缓冲要按实际协商结果计算。

原始文件大小可用 `wc -c output/camera-check/frame.nv12` 查看。预计与 3840 × 2160 × 3 ÷ 2 的 12,441,600 字节相等。这是用已有产物复算尺寸，单凭文件大小不能辨认传感器型号。识别型号看控制链，证明取到图像还需对应的视频节点、完成的缓冲和图像内容。[采集端怎样取得一帧](../05-相机驱动实践/capture-client.md)

### 本节复盘

试着把下面的四问连成一段。讲到没有实测的部分，就说明自己用的是源码推导或下一步取证方案。

1. **硬件怎样在 Linux 里有名字？** 从 `&i2c3` 与 `reg=<0x1a>` 讲到 adapter、client、OF 匹配与 sensor probe。给出可以查看的 `of_node` 或 `driver` 证据。
2. **CPU 怎样取得一个 ID 字节？** 画出短写 `31 1a` 加重复起始读，把两个消息对应到控制器回调、FIFO、中断和等待条件。
3. **哪层丢失了最有用的错误？** 列出底层 `-ETIMEDOUT`、传输包装 `-EIO`、身份检查 `-ENODEV` 这一种可能路径，再说明第二路现有日志只看得见其中哪一层。
4. **下一次调试做什么才有信息增益？** 第一路有正确 ID 但无帧时转查媒体链。第二路先确认是否有实际模组，核对活动树和控制器记录，再决定是否测 SCL/SDA。写清预期和使你改变判断的观测。

**复盘这次读取。** 画一张两条消息的时序图，旁边标注消息数、缓冲长度和地址宽度。再为两路历史日志各写一句“已证实”和一句“还要查”。当你能解释为什么 `3-001a` 成功与 `4-001a` 失败可以同时成立，就可以沿第一路继续追像素从 sensor 如何走向 DPHY、CIF、ISP 和视频队列。[下一节　新板与模组移植清单](../05-相机驱动实践/module-checklist.md)
