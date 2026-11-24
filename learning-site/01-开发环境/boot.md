# 1.7 从上电读到 PID 1

接通电源后，片内 BootROM 从启动介质寻找可运行的前级引导。前级完成包括 DDR 初始化在内的准备工作，引导器选择内核、设备树并传递命令行。内核建立页表、初始化驱动，找到根文件系统后尝试启动第一个用户进程。相机服务由用户态启动。想区分这些阶段，先按时间给日志分段。

~~~text
复位 → BootROM → 前级引导 → 引导器装载 Image、选择 DTB 并传递启动参数
     → ARM64 入口 → start_kernel → 挂根 → PID 1 → 服务 → 应用取帧
~~~

如果串口从头静默，先用已确认的 UART、接线、地线和波特率复查，再核对板上供电。静默本身无法区分 BootROM 失败与输出通道选错。若看到内核反复等待根设备，记录完整命令行中的 root=，寻找块设备枚举和分区信息。若已进入 shell 却没有相机服务，边界已推进到用户态，再查进程和服务日志。

在 WSL 项目根目录执行。下面读取工作区以前保存的板端内核日志，可以先用它练习定位，不需要连板。没有这份本地产物时，可用表中的实测摘录做同样的判断。

~~~bash
log=output/camera-check/dmesg-before.log
rg -n 'Linux version|Machine model|Kernel command line|VFS: Mounted root|Run .+ as init process' "$log"
~~~

| 实测标志 | 它把排查推进到哪一步 |
| --- | --- |
| `1.570848`，`Linux version 6.1.141` | 已进入内核，版本字符串描述这次运行的镜像 |
| `1.575822`，`Machine model: Alientek RV1126B Board` | 内核读到了固件传入的板型描述。多个 DTB 可以共用这个字符串 |
| `1.633560`，`Kernel command line: storagemedia=emmc …` | 可以继续核对传递给内核的 `root=`、`rootwait` 与 console 参数 |
| `3.303258`，`VFS: Mounted root (ext4 filesystem) on device 179:6.` | 本次内核已挂载根文件系统，设备号用于与块设备记录对照 |
| `3.309361`，`Run /sbin/init as init process` | 内核正尝试执行 init。要证明用户态服务起来了，还需查看 PID 1 或后续服务日志 |

先找到最后一个明确完成的步骤。例如已看到挂载成功，但紧跟着出现 init 执行失败，优先检查根文件系统里的 init 路径及 ELF 解释器。若串口已经显示启动，而 ADB 没有设备，先从串口确认系统和 adbd 的状态，同时确认 WSL 查询的是哪个 ADB 服务。上面的日志由内核保存，从它开头看不到 U-Boot 属于正常现象。要判断引导器到底选择了哪个配置，需要串口的前段记录。

### 在源码里对照三个启动标志

`head.S` 的 `primary_entry` 保存引导参数并建立早期执行环境，后续经 `__primary_switched` 进入 `start_kernel`。沿 `init/main.c` 读到 `kernel_init_freeable`，可找到等待初始化并在适用分支调用 `prepare_namespace` 的位置。最后回到 `kernel_init` 看怎样尝试执行 init。存在可用的 initramfs 入口时，根文件系统切换可以交给早期用户态处理。

<Sdk id="arm64-entry" />

早期汇编准备好 C 环境后，执行转到 start_kernel。这个入口启动内核初始化。

<Sdk id="start-kernel" />

基本初始化之后，还要决定启动早期用户空间或由内核准备根文件系统。下面找进入挂根路径的条件。

<Sdk id="prepare-root" />

挂根提供了可执行文件所在的目录。再跟到 kernel_init 中尝试执行用户 init 的位置。

<Sdk id="kernel-init" />

**复盘。** 只拿到 `Linux version` 和 `Machine model` 时，能确认当前板子使用的是你刚编译的 DTB 吗？这两条只给内核版本字符串与活动树中的板型。进一步应对照引导日志中的所选配置与活动树里的具体节点、属性，再结合构建产物记录。内核和设备树可以分别更新。[内核构建与产物](build.md)

### 谁选择启动物料，谁解释 root=

BootROM 固化在 SoC 内，按芯片启动机制尝试前级引导。早期加载器完成 DDR 初始化后，才能把较大的后续镜像放到内存。阅读 Rockchip SDK 时先分清厂商构建脚本实际打包了什么，以及板上的引导器实际选中了什么。构建目录里的 Image 是供启动使用的内核映像，带符号的 vmlinux 用于源码定位，DTB 描述硬件，根文件系统则包含 init、动态库、设备管理及服务所需文件。

| 环节 | 提供什么 | 下一阶段如何使用 |
| --- | --- | --- |
| 打包 | boot 镜像可能含 Image 与一份或多份 DTB | 由引导配置选择并装载 |
| 引导器 | 内核入口、DTB 以及传递的启动参数 | AArch64 约定经 x0 传递 DTB 地址，内核核对其格式并读取 |
| 内核 | 调度、内存与驱动初始化，根设备探测、挂载 | 提供执行 PID 1 的环境 |
| PID 1 | 启动和管理用户空间 | 固件的 init 体系决定如何启动 adbd、相机服务等进程 |

源码命令在 WSL 工作区根目录运行。先查候选构建的选择点，再从历史内核日志验证实际走到了哪里。

~~~bash
sdk=atk_dlrv1126b_linux6.1_sdk
rg -n 'RK_KERNEL_MULTI_DTS|RK_KERNEL_DTS_NAME|mk-fitimage|boot[.]img'   "$sdk/device/rockchip/common/scripts/mk-kernel.sh"
rg -n 'user_mode_thread[(]kernel_init|ramdisk_execute_command|prepare_namespace[(]'   "$sdk/kernel-6.1/init/main.c"
rg -n 'root_dev_setup|rootwait_setup|prepare_namespace[(]'   "$sdk/kernel-6.1/init/do_mounts.c"
rg -n 'mmcblk0:|EXT4-fs [(]mmcblk0p6[)]|VFS: Mounted root|Run /sbin/init as init process'   output/camera-check/dmesg-before.log
~~~

<Sdk id="sdk-multi-dtb" />

打包脚本准备候选物。启动时只有被传给内核的那份树会到 FDT 校验入口。

<Sdk id="board-boot-dt-verify" />

本次日志先枚举 mmcblk0 及 p1 到 p8，再看到 ext4 从 mmcblk0p6 恢复和挂载。随后 VFS 打印设备号 179:6。将分区枚举、文件系统类型和设备号连起来，能解释当次根文件系统来自哪一层。日志中的 root=PARTUUID 选择分区身份，rootfstype 指明文件系统类型，rootwait 则表示等待根设备出现。rootwait 可让内核等待较慢的存储枚举，不能解决错误的分区标识或节点始终未出现的问题。

### PID 1 是怎样出现的

跟读 rest_init。这里创建运行 kernel_init 的首个用户模式任务，再启动 kthreadd。进入 kernel_init 后，仍要等待初始化并决定走早期用户空间还是内核挂根路径。如果 ramdisk 的 init 可用，会优先尝试它，后续根切换可由早期用户空间完成。否则在相应分支调用 prepare_namespace 寻找并挂载根。读挂根代码时将“分区已出现”和“文件系统已成功挂载”标为两条证据，前者只证明块层已经识别设备。

<Sdk id="board-create-pid-one" />

创建首个用户模式任务只是开始。该任务还要在适用分支准备根文件系统。

<Sdk id="board-mount-namespace" />

挂根完成提供了路径查找环境。下一步才尝试执行 init。

<Sdk id="kernel-init" />

找到 do_mounts.c 里的 prepare_namespace，检查驱动初始化等待、根设备选择和挂载的先后。再读 kernel_init 中依次尝试执行 init 的分支。执行成功后，任务仍是 PID 1，但已运行用户程序。历史日志的 Run /sbin/init as init process 在执行尝试前打印。若看到此行之后出现错误，应核对该路径的可执行模式、目标架构、脚本解释器或 ELF 解释器。若日志已经到服务启动，再去找 PID 1 管理的相应进程和该服务自己的失败记录。

### 用最后一条可靠输出决定查哪一层

| 最后一条可靠证据 | 先做的核查 | 如何改变判断 |
| --- | --- | --- |
| 有前级引导日志，没看到跳转或内核日志 | 确认装载和选择结果，并核对早期串口配置 | 已见明确装载失败时查物料。看到跳转但无输出时，兼顾控制台和早期内核两种解释 |
| Linux 已开始，反复等待根设备 | 将 root= 对照块设备枚举与分区标识 | 设备未枚举先查控制器和驱动。设备已枚举却无法解析目标则继续核对分区标识 |
| 根挂载成功，init 执行失败 | 核对 init 与解释器、权限及架构 | 能看到文件名只证明路径的一部分，实际执行错误提供更细的线索 |
| 能进 shell，某服务未启动 | 检查 PID 1 所用配置和服务日志 | 若仅 ADB 不通，从串口确认 adbd 是否已就绪，再回到通信通道 |

**卷末验收。** 从历史材料挑出一条驱动开始探测、一条挂根成功和一条尝试执行 init 的证据，注明来源和观察边界。面试里再解释为什么两份内核配置无差异，仍需核对运行 DTB。构建配置、引导选择以及活动树处在不同环节，每一步都可以有不同证据。完成后进入[2.1 应用文件 I/O 与 errno](../02-应用与字符驱动/file-io.md)。
