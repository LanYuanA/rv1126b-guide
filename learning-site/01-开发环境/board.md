# 接手 RV1126B 与 IMX415

拿到板子时，先解决三个可以独立验证的问题。手上的模组接在哪个接口？眼前的命令在哪台机器运行？程序说“打不开”时，究竟是哪一次操作失败了？以下从第一路 IMX415 开始。手边只有 SDK 时，也能完成源码核对和文件实验。

## 1.1 认识 RV1126B、摄像头模组与原理图 {#hardware}

### 先认清板、模组和芯片

同一颗 IMX415 可以装在不同模组上。模组厂商可能更换镜头、连接器、稳压器或参考时钟，主板改版也可能改变插座布线。记录主板型号与 PCB 修订、插座位号、模组料号与修订、镜头型号以及排线两端的触点方向。芯片丝印提供传感器身份，另外几项决定这块板具体如何接上它。

| 部件 | 负责什么 | 排错时问什么 |
| --- | --- | --- |
| SoC | CPU、总线控制器、时钟和 GPIO，以及接收与处理图像的硬件 | 哪个硬件块产生这个信号？哪个块消费？ |
| DDR | 存放系统运行时的代码、数据和帧缓冲 | 帧写到哪里，哪个消费者还持有缓冲？ |
| eMMC 等存储介质 | 保存启动物料、根文件系统和可能的录像文件 | 正在运行的镜像与本地候选产物是什么关系？ |
| 相机模组 | 镜头成像，传感器采样并发送像素，模组电路为芯片提供运行条件 | 插座两侧的电源、电平、参考时钟和数据线是否匹配？ |

把控制线和像素线分两遍画。第一次沿 CPU 到模组画 I2C。第二次反过来沿模组到接收端画 CSI，再往下画 SoC 向 DDR 写帧。最后在模组前补上电源、复位和参考时钟。某次 NV12 采集能证明后半段产生了结果，连接器脚位和电源幅值则要另外取证。

### 从板级节点找出第一根线

在 WSL 项目根目录执行。第一条检索限定板型和第一颗 sensor，第二条追到 SoC 的管脚复用定义。先猜一下，在 sensor 节点中找不到 SCL、SDA 两个属性，该往上找父节点还是往下找 endpoint？

~~~bash
tree=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/arch/arm64/boot/dts/rockchip
rg -n -A25 '^&i2c3 ' "$tree/rv1126b-alientek.dtsi"
rg -n -A7 'cam_clk0_pins:|i2c3m1_pins:' "$tree/rv1126b-pinctrl.dtsi"
~~~

父节点 `&i2c3` 选择 `i2c3m1_pins`。跟到 `rockchip,pins`，SCL 对应 `<4 RK_PA4 6 …>`，SDA 对应 `<4 RK_PA5 6 …>`。第一格是 GPIO bank，第二格是 bank 内的引脚，第三格选择复用功能，最后一格引用电气配置。两根线服务于整条控制总线。sensor 节点自己的 `pinctrl-0` 指向 `cam_clk0_pins`，这一组把 GPIO4_B1 复用为传感器输入时钟输出。两个同名属性处在不同节点，应沿各自的引用跟读。

<Sdk id="board-dts" />

板级节点选择管脚组。先沿父控制器的引用查看两根 I2C 线，再查 sensor 自己的时钟组。

<Sdk id="board-i2c-pins" />

这里把 A4/A5 交给 I2C3。XCLK 则有自己的一条输出路径，继续读 B1 的复用项。

<Sdk id="board-xclk-pin" />

~~~text
板上供电 → 模组电源轨
RV1126B → XCLK、复位及电源控制 → 模组
I2C3    ↔ SCL/SDA 控制总线     ↔ IMX415 寄存器
IMX415  → CSI-2 像素流 → SoC 接收端 → 采集/ISP → DDR 中的帧缓冲
存储介质 → 引导镜像与根文件系统             应用 → 编码后写入存储
~~~

DDR 存放正在处理的帧。应用可从内存中的缓冲取图，写录像文件才涉及持久存储。读到芯片 ID 只走控制总线，排线中传输 CSI 数据的差分对要单独核对。若 ID 正确而无帧，先留存 ID 证据，再检查出流和接收端。

### 把软件名字落到连接器上

先记录 PCB 丝印的板型与修订、相机连接器位号、模组丝印和排线触点朝向。打开**与板修订一致**的原理图，从连接器的一脚沿网络标签查到 SoC 或供电器件。若中间有电平转换、反相或跳线选择，在表里加上这一段。以下是本地 SDK 能预填的部分。

| 信号 | SoC 一侧与方向 | 到实物还要核对 |
| --- | --- | --- |
| SCL / SDA | 第一组分别为 GPIO4_A4 / A5。控制器产生时钟，数据线双向 | 原理图网络名、上拉电压、连接器脚号 |
| XCLK | GPIO4_B1 复用输出，接到模组时钟输入 | 连接器对应脚、模组允许频率 |
| RESET / POWER | GPIO4_A0 描述为低有效复位，GPIO4_A2 描述为高有效电源控制 | 有效电平经板上器件到模组后是否反转，实际电源轨与时序 |
| CSI 数据 lane | `data-lanes = <1 2 3 4>` 描述四条数据 lane，endpoint 引用接收端 | 模组与主板两端各对差分线的编号、极性、连接器脚号 |

`GPIO4_A4` 是 SoC 管脚名，无法直接推出排线第几脚。本工作区目前只有板卡资料入口，表中连接器脚号与 PCB 修订仍待实物和对应图纸确认。自己的接线记录要同时写“哪版原理图的哪一页”和“哪一个运行节点”，这样模组或板子换版后才知道要查哪里。[设备树属性及资源提供者](../04-设备模型与驱动子系统/devicetree.md)

### 从连接器倒查，先确定方向再抄编号

1. 在对应 PCB 修订的主板图里找到插座位号和 pin 1。再比对模组侧连接器图，区分对接面和焊接面，确认排线触点朝向。
2. 从模组的一个信号沿网络往回追。XCLK 在 SoC 侧是输出，在模组侧是输入。SDA 双向，I2C 中的 SCL 与传感器发像素的时钟差分对各有来源。
3. 如果跨电源域，记录上拉电压、连接器两侧的网络名和转换器。RESET 若经反相，SoC pad 的物理电平不能直接代入模组 XCLR。
4. 将找到的 SoC pad 与 DTS 属性配对。GPIO4_A4 是 bank 内的 pad 一侧编号，CSI 的 lane 索引来自接收端布线描述，连接器针脚另有自己的编号。

### 离线验证编译结果

在 WSL 项目根目录读取已有候选 DTB。候选文件不存在时，可先沿构建说明获得它。[构建说明](build.md)

~~~bash
base=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
dtb="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
test -f "$dtb"
"$base/scripts/dtc/dtc" -q -I dtb -O dts "$dtb" |
  rg -A15 '^[[:space:]]+(imx415_0@1a|gpio@21800000) [{]'
~~~

本次结果中 reg 为 0x1a，reset-gpios 为 <0xa1 0x00 0x01>，power-gpios 为 <0xa1 0x02 0x00>。两组的第一格指向同一个 provider。下看 gpio@21800000，核对其 phandle 同为 0xa1，#gpio-cells 为 2。按本版 GPIO 格式，后两格为偏移和标志。将两项与源码中的 gpio4、RK_PA0、RK_PA2 和有效电平常量核对。在这份编译结果中 0xa1 是引用编号，换一份 DTB 后编号可以改变。要确认开发板此刻采用同一描述，仍需对引导选择和活动树取证。

### 本节复盘

选 RESET，从模组端记录网络名、两端连接器脚号、中间电路、SoC pad、DTS 属性及实际电平测点。缺原理图或模组资料的项标成待确认，并写明缺哪一版资料。合上正文再回答两个问题。换成同芯片的新模组，哪些连接条件要重验？原厂能读到 0xe0 而无帧时，为什么还要看 CSI 接收而非把故障直接定在 I2C？

## 1.2 分清 WSL、串口、ADB 与目标机 {#terminals}

### 一扇终端可以经过三套执行环境

终端负责输入输出，shell 解释命令，实际进程运行在自己的内核上。Windows Terminal 可以托管 WSL Bash，也可以托管 PowerShell。在 WSL 里启动 adb.exe 会通过互操作启动 Windows 客户端。若客户端发的是 shell 请求，最终的 uname 由板端程序执行。

内核的 newuname 从当前 UTS 命名空间取得字段，再复制到用户空间。观察 machine 与 release 能识别一次查询发生在哪个环境。同名 release 可能来自不同构建，进一步识别还要看版本与来源。

<Sdk id="board-uts-query" />

### 给每份输出标记执行位置

~~~text
WSL shell → uname                         → WSL 内核
WSL shell → ADB client → server → adbd → 板端 shell → 板端内核
串口终端  ↔ USB 转串口 ↔ 板上 UART        → 当前阶段的引导日志或 Linux 控制台
~~~

在 WSL 运行 `uname -m`，本工作区得到 `x86_64`。历史板端的 `adb shell uname -m` 为 `aarch64`。两次都可以在同一扇终端输入，区别在于谁执行 `uname`。串口程序只负责收发字符。看到 Linux 登录提示并登录后，输入的命令才由目标 shell 执行。只看到引导器提示符时，应先辨认所在启动阶段。

在 WSL 先用下面几条查看命令路径与宿主信息。本轮 WSL 是 x86_64，内核为 6.18.33.1-microsoft-standard-WSL2。历史板端为 aarch64，原厂内核为 6.1.141。

~~~bash
command -v adb
command -v adb.exe || :
uname -mr
adb version
~~~

已连接设备时，在 WSL 先运行 `adb devices -l`。从输出选定状态为 `device` 的序列号，再执行下面的只读查询。用同一个 client 配置列设备和进 shell。输入时只选状态为 device 的目标。

~~~bash
client=(adb)
# 若已确认使用 Windows 的 5038 server，改为 client=(adb.exe -P 5038)
"${client[@]}" devices -l
read -r -p '目标板序列号：' serial
"${client[@]}" -s "$serial" shell 'uname -mr; cat /proc/sys/kernel/random/boot_id'
"${client[@]}" -s "$serial" shell 'tr -d "\000" < /proc/device-tree/model; echo; cat /proc/cmdline'
"${client[@]}" -s "$serial" shell 'cat /proc/mounts | head -12; ls /dev/media*'
~~~

`boot_id` 是本次启动的标识。同一台板先后取两段日志时，把它和板型、内核版本一起记下来。若两次 boot ID 不同，就不能直接用两份中断计数求这段时间内的增量。若想核对具体相机链，再保存同一次启动的活动树、运行配置和 media 拓扑。

### ADB 列表为空时，先判断查的是哪个服务

本项目遇到过 Windows 已识别 USB 接口，而默认查询没有设备的情形。第一种解释是设备未出现在 USB 传输层，第二种是终端连到了另一个 ADB server。已保存的排查记录显示 Windows server 监听 5038。在当时的 WSL 终端用 `adb.exe -P 5038 devices -l` 查到设备，这一对照解释了为什么改端口就能继续。复现查询时，后续的 `-s` 和 `shell` 同样要发给已选定的 server。换环境应以当地端口和设备列表为准。[ADB 的 client、server 与 daemon](https://developer.android.com/tools/adb)

串口是另一条观察通道。先核对接口电压域，共地后将转换器 TX 接板端 RX、转换器 RX 接板端 TX。端口号、波特率、数据位、校验和停止位按对应板卡资料设置。它们与 ADB 服务端口属于不同层次。现场若只有乱码，优先查串口参数和电平。若串口已有完整启动日志而 ADB 列表为空，继续查 USB、server 和板上的 adbd。这里尚无本次串口实测参数。

### 用症状决定下一笔证据

| 观察 | 已有证据 | 接着查什么 |
| --- | --- | --- |
| Windows 和 WSL 的设备列表不同 | 两端给出不同的 server 或 USB 传输视图 | 先比较 adb 与 adb.exe 的实际程序路径、server 端口，再确保 devices 和 shell 用同一客户端配置 |
| 列表只有标题 | 这次查询未列出可用的设备条目 | 查当前端口下的 server 是否拥有 USB transport。用串口交叉验证系统是否启动 |
| offline 或 unauthorized | server 已出现条目，shell 尚不可用 | 分别查握手和认证，保留状态和值班窗口里的日志 |
| 串口有 U-Boot 文本，ADB 不通 | 一个早期引导阶段已运行 | 沿 UART 追到 Linux 和用户空间后再查 adbd |
| 串口输出正确，发送输入无效 | 板端 TX 到宿主 RX 通了 | 查回程、共地、流控及当前是否到了交互提示符 |
| 串口乱码或静默 | 尚无可靠可读日志 | 验证端口、串口参数和电平，记录是否从上电前开始采集 |

执行过 adb shell 时，单引号内的脚本在远端解析。管道与重定向写在引号外时由 WSL shell 处理。例如 adb shell 'cat /proc/uptime' > capture.log 中，cat 读板端，文件写在宿主。复盘日志时，相对路径要和执行环境一起写。

boot_id 标识内核启动会话。即便序列号相同，拿不同 boot_id 的 IRQ 计数相减也会失去意义。镜像标识、活动树 model 与 cmdline 可用来解释这次启动发生了什么。记录身份卡时，加上取样时刻和连接通道。公开日志前检查序列号及启动参数。可沿内核 sysctl 表看到 boot_id 与处理器的对应关系。

<Sdk id="board-boot-id" />

### 本节复盘

画出 WSL Bash → Windows adb.exe → Windows ADB server → 板端 adbd → 目标 shell，并标注每个进程运行在哪台机器。指出 5038 位于哪一跳，为什么串口的波特率与它无关。再用已有启动日志判断 U-Boot、Linux 内核与用户空间的观察边界。这次的板端查询只做语法检查。下一节将在已经确认的执行位置复现路径和权限错误。

## 1.3 Linux 命令、文件权限、进程与日志 {#files}

如果同事只说“设备打不开”，先追问三个事实。程序在哪台机器运行？失败的是哪条调用？当时用的是哪个账户？下面用同一个路径制造“目标不存在”和“目标存在但无权读取”，再让已打开的描述符继续工作，观察错误出现在哪一道边界。

### 路径如何变成一次打开

绝对路径从进程的根目录起步，相对路径从进程的当前目录起步。Linux 按分量逐级查找；跨挂载点时，后续分量由挂在那里的文件系统解释。符号链接保存目标路径。如果目标是相对路径，则从**符号链接所在的目录**解析目标。进程可以先找到链接，继续跟随时才发现目标缺失。相同路径拼写在 WSL、板端和容器中可能对应不同对象。

权限也要按路径分开查。对普通文件，`r/w/x` 表示读、写、执行。对目录，`r` 允许列出目录项，`x` 允许按名称查找并穿过该目录，`w` 参与新建、删除等目录项操作。每一层目录都要允许查找，末端文件才有机会检查本身的读权限。UID、GID 和补充组应从实际运行进程取证，登录账户与服务进程可能不同。下面只演示基本模式位，实际现场还可能受 ACL、能力和其他安全机制约束。

### 让同一条 cat 在两个位置失败

在 WSL **普通账户**的 Bash 里复制整段。临时目录中只有自己创建的文件。实验先构造一个悬空链接，再修复目标，最后只改变其模式位。运行前先预测，链接本身一直存在，哪一次读取会失败？

~~~bash
(
set -eu
export LC_ALL=C
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
cd "$lab"
pwd -P
findmnt -no TARGET,FSTYPE -T .
id
ln -s sample current
readlink current
if cat current; then exit 1; else echo "missing status=$?"; fi
printf 'frame\n' > sample
chmod 600 sample
stat -c '%A %u:%g %n' sample current
namei -l current
stat -Lc "%A %u:%g %n" current
cat current
exec 3<current
readlink "/proc/$BASHPID/fd/3"
chmod 000 sample
if cat current; then exit 1; else echo "denied status=$?"; fi
cat <&3
exec 3<&-
chmod 600 sample
cat current
)
~~~

| 现象 | 为什么会发生 | 如何区分和复测 |
| --- | --- | --- |
| `No such file or directory`，`missing status=1` | `current` 保存了目标名 `sample`，此时目录里还没有这个目标 | `readlink current` 仍打印 `sample`。创建目标后同一条 `cat current` 成功 |
| `Permission denied`，`denied status=1` | 目标已存在，模式 `000` 使普通进程新打开它时缺少读权限 | `stat` 查看模式和属主，`id` 查看调用者身份。恢复 `600` 后再次读取成功 |
| 仍能用 `cat <&3` 读到 `frame` | fd 3 在权限改变前已成功打开。shell 把该打开文件作为 cat 的标准输入 | `/proc/$BASHPID/fd/3` 属于当前 shell，能看到它指向的目标。关闭后再次按路径打开要重新检查权限 |

这里两个失败的 **shell 退出码都为 1**，错误原因却不同。stderr 是 `cat` 对系统调用错误的解释。把 stderr 和退出码一起保留，再核对失败发生在路径解析、权限检查还是设备操作。`stat` 中权限分为属主、组、其他用户三组。目录的执行位影响能否穿过该目录查找子项；排查真实路径时可用 `namei -l 路径` 逐级看。挂载位置可用 `findmnt -T 路径` 核对，同一个路径字符串在 WSL 与板端可能落到不同文件系统。

<Sdk id="board-open-check" />

访问检查在资源打开前发生。打开成功以后，可以从 proc 的 fd 条目反查这一引用指向哪里。

<Sdk id="board-proc-fd" />

换成 `/dev/video23`，先记执行账户、设备节点和完整报错。若 `open` 成功而随后 `VIDIOC_DQBUF` 失败，此时已走过了节点打开阶段，应该记录 ioctl 名称、errno 和队列状态。把应用 stderr 附在同一启动的内核日志旁，按发生时间查对应驱动消息。节点编号会随固件变化，先用 `v4l2-ctl --list-devices` 对照本次枚举结果。[从应用 fd 追到驱动](../02-应用与字符驱动/first-lesson.md)

### 把证据按采集阶段留下

若实验中的 `sample` 已经存在，`namei -l current` 可以同时展示链接与目标的路径分量。若只在某一层目录拿不到搜索权限，继续给叶子文件加读权限也无法通过该层。先确认所在机器和挂载，再逐级找失败边界，最后查实际调用者。

| 想确认什么 | 先看哪条证据 | 能回答到哪里 |
| --- | --- | --- |
| 解析的是哪棵目录树 | `pwd -P`、`findmnt -T .` | 确认工作目录和文件系统；相对路径还要看目标进程的 cwd |
| 链接指向哪里、谁能查到 | `namei -l 路径`、`readlink 路径`、`stat -L 路径` | 分开核对目录、链接及目标；权限看实际账户 |
| 进程是否还持有文件 | `/proc/<PID>/fd`、进程 UID/GID | 找到已打开对象的引用，需要相应权限。检查当前 Bash 时用它的 PID |
| 失败属于应用还是内核 | 记录 stderr、退出码、调用名与同一时段的内核日志 | 日志可用于对齐证据；缺一条内核打印不足以断定驱动没执行 |

`$?` 保存最近一条命令或管道的退出状态。因此要在失败后马上记录，后续一条 `echo` 成功就会覆盖它。内核的负 errno、用户态函数返回值与程序退出状态是不同层次。两次 cat 都退出 1，也能分别对应 ENOENT 和 EACCES；前者查名称解析，后者查进程凭据、目录搜索权限和目标访问权限。以后用 `strace` 时，可以按 `openat`、`ioctl` 过滤，但仍要用失败参数和返回值确认是哪一次调用。

控制台常同时看到应用输出和内核打印，记录时要分开来源。应用 stderr 跟随进程重定向，内核日志保存在内核日志缓冲区，读取权限和格式由环境决定。若应用记录的是墙上钟而 dmesg 的数字以启动为参考，先记录启动身份和可对齐的事件，再比较先后。同一个名称 `/dev/video23` 跨启动也可能对应另一实例。

**本节复盘。** 为什么改成模式 000 后，已经打开的 fd 仍能读？打开时已有文件引用，这次读取沿该引用进行。为什么 `ls -l` 看见符号链接仍可能打开失败？它能看见链接本身，跟随到目标时还要继续查找。再自己写一份最小记录，包含执行环境、账号、路径、失败边界和修改后的复测结果。

## 1.4 Git、SDK 目录与源码检索 {#source-search}

原厂固件采帧时记录过 `vblank need >= 1000us ... cur 859 us`。假设只知道这几个字，要把问题交给负责相机的同事，应该附 sensor 的寄存器表、ISP 配置，还是采集端的判断条件？先找出这句话是谁打印的。

### 先定位保存修改的仓库

从 WSL 工作区根目录执行。SDK 用多个 Git 项目组成一份工作树。设备配置在 `device/rockchip`，内核在 `kernel-6.1`，用户态程序还要去 `app` 或 `external` 找；生成的镜像和编译配置在输出目录。先确定工作树，后续给别人行号时才能说明依据哪个版本。

~~~bash
sdk=atk_dlrv1126b_linux6.1_sdk
k="$sdk/kernel-6.1"
git rev-parse --show-toplevel
readlink "$sdk/kernel"
git -C "$k" rev-parse --show-toplevel HEAD
git -C "$k" status --short -- drivers/media/platform/rockchip
git -C "$k" diff HEAD --stat -- drivers/media/platform/rockchip
~~~

第一条指向笔记仓库，链接 `kernel` 指向 `kernel-6.1`。第三条先打印内核工作树路径，再给出完整提交号，本次短号为 `a04e4b3c9`。提交号标识已提交的快照。第四条还会报告未跟踪的文件，第五条概括已跟踪文件相对 HEAD 的改动。即使两个人记录了相同的 HEAD，本地补丁仍可能使代码不同。

### 从字符串查到条件，再找谁调用它

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
media="$k/drivers/media/platform/rockchip"
rg -n -C 8 -F 'vblank need' "$media"
rg -n -C 2 'rkcif_check_vblank_value\(' "$media/cif/capture.c"
rg -n -A6 "^config VIDEO_ROCKCHIP_CIF$" "$media/cif/Kconfig"
rg -n 'VIDEO_ROCKCHIP_CIF|capture\.o' "$media/cif/Makefile"
rg '^CONFIG_VIDEO_ROCKCHIP_CIF=' atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal/.config
~~~

在本版源码中命中 CIF 的 `capture.c:13689`。搜固定字串时保留稳定的英文片段，去掉驱动运行时才填入的数字。往上读，函数取第 0 路的行时间和传感器垂直消隐行数，相乘再除以 1000 得到微秒。只有计算值小于 1000 才进入警告分支。按日志代入 859，确实满足条件。它描述的是一帧中垂直消隐的时长，无法据此算出丢了几帧。

<Sdk id="vblank" />

第二次检索会找到定义和两处调用。读第 14184、14465 行前的条件，都有限制早期帧序号的判断，后者还检查 `sditf[0]`。这解释了为何日志可能只在开流初期出现。两次打印也可能来自同一调用点的不同帧，单靠行数无法选择分支。Makefile 把 `capture.o` 归入 `video_rkcif.o`，保存的基线配置给出 `CONFIG_VIDEO_ROCKCHIP_CIF=y`。它们一起说明本地构建如何纳入这个实现。

### 同一目录有几代 ISP，怎样选对版本？

~~~bash
isp=atk_dlrv1126b_linux6.1_sdk/kernel-6.1/drivers/media/platform/rockchip/isp
ls "$isp"/isp_params_v*.c
rg -n -A4 'rv1126b_isp_match_data =|compatible = "rockchip,rv1126b-rkisp"' "$isp/hw.c"
rg -n 'hw_dev->isp_ver = match_data->isp_ver' "$isp/hw.c"
~~~

文件名提供候选范围。OF 匹配表将 RV1126B 的 compatible 连到 `rv1126b_isp_match_data`，该结构指定 `ISP_V35`，驱动再将版本复制给硬件实例。因而沿版本分支阅读之前，应先核对活动设备树里的 compatible 和实际绑定的驱动。把这里的 ISP 版本选择与前面的 CIF 告警打印点分别记在定位卡上，两者位于成像链的不同模块。

<Sdk id="board-isp-match" />

### 用四个层次限定源码结论

| 层次 | 本例要保留的证据 | 下一步检查 |
| --- | --- | --- |
| 源码身份 | SDK 子仓库路径、完整 HEAD、局部差异 | 用同一文件和函数复核打印位置 |
| 编译选择 | Kconfig 类型、Makefile 对象选择、对应输出目录的 .config | 产物中查符号或模块，进一步确认当前构建确实包含它 |
| 部署身份 | 引导选择、运行版本、板型和已加载对象 | 将运行对象与候选产物的记录关联 |
| 触发路径 | 同一次采集启动的日志、相关帧号、在线路径及模式 | 对照调用条件，缺运行分支证据时列出待验证项 |

这里 Kconfig 定义 `VIDEO_ROCKCHIP_CIF` 为 tristate。Kbuild 中 `obj-$(CONFIG_VIDEO_ROCKCHIP_CIF)` 会按配置展开。值为 y 时对应对象进入内建构建，为 m 时进入模块构建。只读 Kconfig 停在“存在这个选项”，看了头文件或 Makefile 也只知道“如何选择”。使用实际构建目录的 .config 才能知道这次选项取值。即便短版本字符串相同，部署身份仍需要独立证据。

**本节复盘。** 提交号相同却复现不了同一条日志，按源码局部差异、构建选择和实际部署逐项讲怎么查。再说明 `git diff HEAD --stat` 为何仍需和 `git status --short` 一起看。前者汇总相对 HEAD 的已跟踪变动，后者还能提示未跟踪文件。要把差异交给同事时，先注明它属于笔记根仓库还是厂商内核项目。

**定位卡练习。** 合上页面，试着用一行话给同事定位：运行现象是什么、用哪个稳定字符串、在哪个提交找到哪个条件、哪些现场信息还缺。对本例，下一条有判别力的证据是同一开流窗口的传感器模式、行时间与消隐行数，以及采集端的帧序号间隔。原有记录已能证明短时取得图像，目前还不能把告警归因为某个寄存器配置错误。[1.5 用 C 读懂数据与回调](function-pointers.md)

<a id="boot"></a>

启动流程见独立页面。[1.7 从上电读到 PID 1](boot.md)
