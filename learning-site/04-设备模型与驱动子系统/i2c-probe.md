# I2C 中篇　从设备树走到 probe，再装出两条消息

上篇已经画出了读 ID 的总线事务。本篇把时间拨回开机。假设你刚接手板子，内核源码里同时有 `rk3x_i2c_probe` 和 `imx415_probe`，它们的第一个参数类型还不一样。该在谁那里找时钟和中断，该在谁那里找 `0x311a`？先亲眼看到候选 DTB 里写了什么，再追一份 `client` 从何而来。[回看上篇的对象表](i2c-wire.md)

## 4. 板级描述怎样变成一个 client

### 先读已经编译好的 DTB

在 WSL 项目根目录运行。命令复用工作区基线产物，把反编译结果留在 `output/textbook-check`，便于反复搜索。这一份是我们的**本地候选 DTB**。要确认板子实际用了哪些属性，还需要读活动树。

~~~bash
out=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
dtb="$out/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
mkdir -p output/textbook-check
"$out/scripts/dtc/dtc" -q -I dtb -O dts -o output/textbook-check/i2c-candidate.dts "$dtb"
rg -n -m1 -A5 '^\s*imx415_0@1a \{' output/textbook-check/i2c-candidate.dts
~~~

实测片段中有 `compatible = "sony,imx415"`、`reg = <0x1a>`、`clock-names = "xvclk"`。第一个字符串用来找驱动，第二个数用来给器件寻址，第三个名字供驱动请求输入时钟。若第一条命令报找不到 `dtc` 或 DTB，先回第 02 章核对内核输出目录。没有构建产物时仍能用下面的入口跟读 DTS。[交叉编译与启动产物](../01-开发环境/build.md)

<Sdk id="board-dts" />

### 顺着 reg 找到它落入的 C 字段

`rv1126b.dtsi` 描述 SoC 有一个 `i2c@21120000` 控制器，板级 `&i2c3` 打开它，并在它下面写了 `imx415_0@1a`。注意两个节点都可以叫自己的地址属性 `reg`。父总线决定解释方法。SoC 控制器的 `reg` 表示 MMIO 地址区间，I2C 子节点的 `reg` 在本例中只有一格，存七位 I2C 地址。节点名里的 `@1a` 方便人定位，core 真正读取的属性是 `reg`。[DTS 字段、GPIO 和时钟消费者](devicetree.md)

~~~text
rk3x_i2c_probe 注册 adapter
    ↓ I2C core 在 adapter 注册路径上枚举可用子节点
of_i2c_register_devices → of_i2c_register_device
    ↓ of_i2c_get_board_info 读取 reg，将地址放入 info.addr，保留固件节点
i2c_new_client_device(adap, &info)
    ↓ client->adapter = adap，client->addr = info->addr
device_register(&client->dev) → 这个实例可以参与驱动匹配
~~~

先看第一段的 `of_property_read_u32(node, "reg", &addr)`。字符串 `"reg"` 只在第一处出现，后面的 C 代码传递的是已经解析的地址。`for_each_available_child_of_node` 会筛选可用子节点，读取 `reg` 失败时这一条创建路径会提前返回。此时去传感器里给 `imx415_read_reg` 加打印，观察不到这次失败。

<Sdk id="i2c-of-enum" :start="35" :lines="6" />

解析成功后，地址继续经 board_info 传递。创建 client 时将解析值复制到 `client->addr`。后续驱动组装消息时会读取这一字段。

<Sdk id="i2c-new-client" :start="979" :lines="6" />

**老板级文件怎样表达同一个地址？** 在使用 C 板级文件的系统中，可以事先用 `i2c_register_board_info` 声明适配器编号、设备类型和地址。下面是只用来对照“总线 3 的 0x1a”这一信息的板级写法。第一行的宏填入 `type` 和 `addr`，总线编号则由注册调用传入。

~~~c
static struct i2c_board_info camera[] = {
	{ I2C_BOARD_INFO("sony,imx415", 0x1a) },
};
/* 板级初始化函数中调用 */
/* i2c_register_board_info(3, camera, ARRAY_SIZE(camera)); */
~~~

现代设备树把板上连接数据放进 DTB，内核可从固件节点同时取得时钟、GPIO、模组字段和 endpoint。这份厂商 IMX415 驱动的 `probe` 会直接读取 `dev->of_node`。只建一个带地址的旧式 `board_info` 能演示 I2C 实例的来源，要满足本驱动的完整资源契约还需要那些固件描述。已经由 DTS 枚举的同一器件无需再登记一遍。[Linux 6.1 的 I2C 设备实例化方法](https://docs.kernel.org/6.1/i2c/instantiating-devices.html)

<Sdk id="i2c-board-info" />

**一个本版 SDK 才看得到的细节。** 公共板级文件里有多种同地址的候选模组。本版 `i2c_new_client_device` 检查同地址已注册实例的数量，把它传给 `i2c_dev_set_name`。普通名字形如 `3-001a`，计数非零的分支会追加后缀。因此调试时请把目录名和它的 `of_node/compatible` 对起来。三个候选的软件名字并不能举证插座上装了三颗芯片。

<Sdk id="i2c-client-name" />

**从地址追到代码。** 对 `&i2c3 { … imx415_0@1a { reg = <0x1a>; … }; };` 画三列，分别填“谁决定总线”“谁填写器件地址”“谁决定寄存器号”。最后一列应该空到读驱动代码时才填 `0x311a`。这样就能解释为什么改变寄存器选择通常不需要重新编译 DTB。

## 5. 先看到 match，再走进两次不同的 probe

### 找到真实的间接调用

在 WSL 根目录运行。第一次查找表中登记了哪些函数，第二次找 core 在哪里取表并加括号调用，第三次按代码顺序排列 sensor 初始化的几个门槛。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
s="$k/drivers/media/i2c/imx415.c"
rg -n 'imx415_of_match|\.probe\s*=|i2c_add_driver\(' "$s"
rg -n 'i2c_of_match_device\(drv->of_match_table|status = driver->probe\(client' "$k/drivers/i2c/i2c-core-base.c"
rg -n 'could not get module information|Failed to get endpoint|devm_clk_get|ret = __imx415_power_on|ret = imx415_check_sensor_id|ret = v4l2_async_register_subdev_sensor' "$s"
~~~

`rk3x_i2c_probe(struct platform_device *pdev)` 为主控注册 adapter。`imx415_probe(struct i2c_client *client, …)` 才是为这颗传感器初始化状态。`sensor_mod_init` 调用 `i2c_add_driver` 登记了 `imx415_i2c_driver`。在本板 DT 路径，`i2c_device_match` 优先用 OF 匹配表对照 `"sony,imx415"`，I2C core 的 `i2c_device_probe` 最终取 `driver->probe` 调用。回想温度计示例，把“操作表”和“传入实例”分别换成 `imx415_i2c_driver` 和 `client`。设备和驱动谁先注册都可能，设备模型在双方可用时才安排绑定。

<Sdk id="i2c-match" />

总线比对固件描述和 ID 后，最终使用实际驱动登记的探测函数。

<Sdk id="i2c-probe-call" />

I2C core 负责调用已匹配的函数；IMX415 的驱动表提供具体回调。

<Sdk id="imx415-driver" />

### 按第一次会失败的位置读 probe

| 停在哪一段 | 实际执行的事 | 这时最值得查什么 |
| --- | --- | --- |
| 读取模组信息 | 读 index、facing、module-name、lens-name。必需字段读取失败会打印 `could not get module information!` 并返回 `-EINVAL` | 查活动树中对应节点的四项属性与编码 |
| 读取 endpoint | 找图端点，解析 `data-lanes`，以 lane 数和 HDR 模式选模式表 | 回到活动树的 `port/endpoint`。打印 lane 数表示已解析配置 |
| 准备物理条件 | 取得 `xvclk`、GPIO 描述符、regulator 等资源，再在 `__imx415_power_on` 中按本版分支选择引脚、处理 GPIO、准备时钟和电源 | 核对返回分支、资源提供者、板级连接。某些 GPIO 获取失败只记警告，`devm_clk_get` 失败却会返回 |
| 校验身份 | 普通启动调用 `imx415_read_reg`。`is_thunderboot` 分支会打印跳过 ID 校验并直接返回 0 | 查这一次究竟出现 `Detected …`、`Unexpected …`，还是 `skip sensor id check` |
| 向媒体框架发布 | 设置媒体实体与 pad，调用 `v4l2_async_register_subdev_sensor` | 即使已读对 ID，注册失败仍需清理资源。媒体设备和帧到达需另找证据 |

<Sdk id="probe" />

实例先从匹配与属性解析得到配置，随后准备时钟和电源。

<Sdk id="power" />

软件完成这条上电路径后，普通 probe 才尝试读寄存器并比较返回的 ID。

<Sdk id="imx415-publish" />

这里只表示框架发布动作。第一次读 ID 是前面的控制链判断，可以单独回看。

<Sdk id="imx415-check-id" />

**用三张故障卡检验顺序。** A 卡只有 client 目录，没有 driver 链接。B 卡能看到 `Failed to get xvclk`。C 卡看到 `Unexpected sensor id`。先不看答案，按“已到达的最深阶段”排序，为每张卡写下一个值得观察的字段。

<details>
<summary>核对判断</summary>

A 卡只有枚举证据。可能尚未匹配，也可能进过 probe 后失败，要再看运行的 compatible 和日志。B 卡已经执行 sensor 的资源获取，先查该节点 `clock-names` 有没有 `xvclk`、`clocks` 是否引用正确的提供者。C 卡已进入普通 ID 检查，可以把本次 `ret` 与 `id` 一起分析。此时尚不能推断异步媒体注册成功。这三张卡能定位到不同的代码区间，其中 A 的信息尤其不足。

</details>

## 6. 把 0x311a 装进两个 i2c_msg，再读懂返回值

### 在 WSL 先跑一个保留失败现场的小实验

在项目根目录用 WSL 自带的 C 编译器。示例使用 Linux 用户空间头文件里的 `struct i2c_msg`。它按调用者给定的返回值和字节填内存，不打开设备文件。预测第三次用例报告完成 1 条消息时，`value` 会改变吗？完整示例可从[本节入口](i2c.md)下载。

~~~bash
mkdir -p output/textbook-check
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O0 -g \
  learning-site/examples/i2c_register_read.c -o output/textbook-check/i2c_register_read
./output/textbook-check/i2c_register_read
~~~

`examples/i2c_register_read.c:26`

~~~c
if (transfer_ret != 2)
    return -EIO;

/* 只有两条消息都完成才交付结果。按大端字节顺序复原数值，与宿主端序无关。 */
memcpy(msgs[1].buf, reply, msgs[1].len);
*value = 0;
for (size_t i = 0; i < sizeof(data); ++i)
    *value = (*value << 8) | data[i];
return 0;
~~~

模型先检查完成消息数，再组合缓冲并交付结果。用下一张表验证失败分支保留 value 的初始值。

| 输入用例 | WSL 实际输出中的 helper 与 value | 为什么这样选输入 |
| --- | --- | --- |
| 两条都完成，给 `e0` | `helper=0 value=000000e0` | 对照驱动期望的单字节 ID |
| 两条都完成，给 `12 34` | `helper=0 value=00001234` | 用不对称字节检测高低位颠倒。回包由示例程序给定 |
| 仅完成 1 条消息 | `helper=-5 value=deadbeef` | 程序在交付 `value` 前返回，`deadbeef` 是调用者设置的初值 |
| 底层返回 `-ETIMEDOUT`，本环境为 `-110` | `helper=-5 value=deadbeef` | 两种原因不同，传感器包装后的错误相同 |
| 请求长度 0 | `helper=-22 value=deadbeef` | 长度检查先于构造消息和传输，也不会出现本轮的 `W@…` 打印 |

### 同一段代码，沿发送缓冲和接收缓冲各读一次

对照下面的 `imx415_read_reg`。`msgs[0]` 和 `msgs[1]` 都使用 `client->addr`。`flags=0` 表示写，`I2C_M_RD` 表示读。`len` 的单位在每条消息里都是字节。`buf` 的归属和方向却不同。把同一只 `client`、同一个 `reg` 和同一个 `len=1` 代入源码，按下表检查。

<Sdk id="i2c-msg" />

消息结构定义地址、方向、长度和缓冲。驱动按这套约定分别准备写地址和收数据。

<Sdk id="i2c-read" />

| 现在看哪一行 | 缓冲里的实际字节 | 谁生产、谁消费 |
| --- | --- | --- |
| `reg_addr_be = cpu_to_be16(reg)` | `31 1a` | sensor 驱动准备内部地址。第一条消息携带这两个字节，控制器发送 |
| `data_be = 0` | `00 00 00 00` | 建一块四字节暂存区。读长度可以为 1～4 字节 |
| `msgs[1].buf = &data_be_p[4 - len]` | `len=1` 时指向最后一格 | 控制器接收路径向该格交付 `e0`，内存就成为 `00 00 00 e0` |
| `*val = be32_to_cpu(data_be)` | 转成宿主整数 `0x000000e0` | 只有确认两条消息都完成后才执行，交给 `imx415_check_sensor_id` |

为什么要偏移 `4 - len`？若把仅收到的一个 `e0` 放在最左一格，按大端四字节转换会得到 `0xe0000000`。若收到 `12 34`，正确内存布局是 `00 00 12 34`。这里讲的是厂商辅助函数规定的组包方式。某项传感器功能若跨多个独立寄存器，还要另外核对该器件对各寄存器的高低位定义。

### 谁会把错误变成另一种错误

下面是 `imx415_read_reg` 真正交付结果的几行。读到 `return -EIO` 就用纸挡住它后面所有行。这条路径能否改写调用者的 `id`，现在不用猜了。

~~~c
	ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret != ARRAY_SIZE(msgs))
		return -EIO;

	*val = be32_to_cpu(data_be);
~~~

在 SDK 中对照这三处判断。`i2c_transfer(..., ARRAY_SIZE(msgs))` 的成功返回值单位是**消息条数**。即使读一字节，这里也期望返回 2。`imx415_write_reg` 调用 `i2c_master_send` 时却检查 **`len + 2` 个字节**，因为一次写缓冲由两个地址字节和若干数据字节组成。最后，`imx415_check_sensor_id` 将局部变量 `id` 初始化为 0，取得 helper 的 `ret` 后对 `id != CHIP_ID` 做判断，打印 `id` 与 `ret`，并返回 `-ENODEV`。

<Sdk id="imx415-write" />

寄存器写是另一种事务。读 ID 则要组合地址写与数据读，再核对返回值。

<Sdk id="imx415-check-id" />

这就能解释一个很容易误判的现场。若传输失败，helper 在给 `*val` 赋值前已经返回 `-EIO`。调用者的 `id` 仍可能是初值 0，所以日志里的 `000000` 并不足以当作总线上真的收到了 `00`。若传输完整却读到 `00`，上层也会报 ID 异常，但这次日志里的 `ret` 应是 0。**把数字和它来自哪一层一起记下来。**

## 本节复盘

**追踪三种返回值。** 写出“传输返回 `-ETIMEDOUT`”“传输成功，读回 `0x42`”“传输成功，读回 `0xe0`”三行，各填 `transfer`、helper、`check_sensor_id` 三列。底层失败那一行应是 `负值 → -EIO → -ENODEV`。接下来去控制器侧找最早能保留错误区别的位置。[继续读下篇](i2c-irq.md)
