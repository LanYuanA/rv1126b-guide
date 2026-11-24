# 2.2 ARM64 同步异常与系统调用

<script setup>
import exampleFile from '../examples/arm64_openat.S?url'
</script>

应用调用 openat 时，CPU 凭什么进入内核，又怎样把整数结果交还给应用？把同一个线程从用户态到内核态再回来的过程画出来。本节限定为 RV1126B SDK Linux 6.1 的 AArch64 原生 ABI。

## 先拆开 C 函数、系统调用与异常入口

应用通常调用 libc 的 open 或 openat。库包装负责按 Linux ABI 填寄存器并执行 SVC，也可处理返回错误。调用 libc 本身先是一次普通函数调用。执行 SVC 才产生同步异常，CPU 根据当前异常级及异常类型进入内核设置的异常向量。AArch64 用户程序通常运行在 EL0，这段内核处理在 EL1。用户态传入的路径仍只是用户地址，进入异常时尚未找到任何 inode。

| 寄存器 | openat 示例 | 谁消费 |
| --- | --- | --- |
| x8 | 56，即 __NR_openat | Linux 的系统调用分派器 |
| x0 | AT_FDCWD，即 −100 | 路径为相对路径时从当前目录查找 |
| x1 | 用户路径字符串地址 | openat 的内核路径接收用户地址并复制名称 |
| x2 | O_RDONLY，数值 0 | 内核按打开标志解释 |
| x3 | 0 | 没有要求创建时，不使用这个 mode |
| 返回时 x0 | fd 或负错误码 | 用户代码或 libc 读取 |

其他系统调用还可用 x4、x5。SVC 指令中的立即数为 0，请求号来自 x8。同步异常与引发该异常的指令有关，硬件 IRQ 则可以由外设异步发起。两者都可进入内核，但使用不同的异常分类和入口。

## 用最小 AArch64 程序核对指令

在 WSL 仓库根目录使用 SDK 的交叉工具链。程序无需 libc，尝试只读打开相对路径 sample，按返回值选择退出状态，成功打开的描述符由进程退出路径清理。实验只构建和反汇编。

<a :href="exampleFile" download="arm64_openat.S">完整 AArch64 汇编实验</a>，仓库路径为 `learning-site/examples/arm64_openat.S`。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
tool="$PWD/atk_dlrv1126b_linux6.1_sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
"${tool}gcc" -nostdlib -static learning-site/examples/arm64_openat.S -o "$lab/openat"
file "$lab/openat"
"${tool}objdump" -d "$lab/openat" |
  rg -A10 '<_start>:'
)
~~~

查看反汇编，应见 AArch64、给 x8 赋 0x38、第一次 svc、读 x0 比较，以及 x8=0x5d 后再执行一次 svc。0x38 是十进制 56，0x5d 是退出调用号 93。这里只有目标文件的静态证据。EL0/EL1 的运行时经过本节依据内核源码解释。

## 跟读内核的五个检查点

~~~text
用户设置寄存器并执行 SVC
 → EL0 64 位同步异常向量 → 汇编保存 pt_regs
 → el0t_64_sync_handler 读 ESR_EL1 → SVC64 分支
 → do_el0_svc 取保存的 x8 → invoke_syscall 选 sys_call_table 项
 → ARM64 参数包装 → openat → do_sys_openat2
 → 设置保存的返回 x0 → 处理返回用户态的工作 → 恢复现场
~~~

### 1. 异常向量和保存现场

在 entry.S 找 vectors 中 EL0 的 64 位 sync 项，跟到 entry_handler 与 kernel_entry。汇编保存通用寄存器及异常返回信息。入口把保存现场的栈地址送给 C 处理器，系统调用分派和参数包装之后读取的是这份保存的现场。原来的用户 x0 已保存，汇编把当前 x0 改成栈地址不会丢失原参数。

<Sdk id="arm64-el0-vector" />

向量先按异常来源进入对应入口。真正保存现场并把栈地址传给 C 处理器的是下面的入口宏。

<Sdk id="arm64-save-context" />

### 2. 从异常原因选到 SVC64

el0t_64_sync_handler 从 ESR_EL1 取异常类别。SVC64 与数据访问异常是两个分支。只看到“同步异常”尚不能推断请求了哪项系统服务。从 el0_svc 跟入 do_el0_svc，才能看到以保存的 x8 作为调用号。

<Sdk id="arm64-svc" />

识别到 SVC64 后才进入系统调用处理。下面一段从保存现场中取 x8。

<Sdk id="arm64-dispatch" />

### 3. 查调用表和参数包装

invoke_syscall 先检查编号是否落在表长度内，再读取表项。越界进入未实现路径，通常得到 −ENOSYS。即便编号合法，表项也可能是未实现入口。原生 sys_call_table 按系统调用头文件展开，ARM64 包装把 pt_regs 中的参数变成 C 函数的实参。这样内核的 openat 实现能收到目录 fd、用户指针、flags 和 mode。

<Sdk id="arm64-invoke-syscall" />

分派器按编号查表。该表在编译时由系统调用宏展开，下一段可看到声明与缺省项。

<Sdk id="arm64-native-table" />

### 4. 哪一行才开始处理用户路径

在 fs/open.c，从 __NR_openat 的表项追到 SYSCALL_DEFINE4(openat, ...)，再到 do_sys_open 和 do_sys_openat2。后者验证标志、取路径，预留 fd 并尝试打开文件。成功才安装 fd，若文件打开失败则归还预留的编号。此时才有 VFS 路径查找和设备回调可讨论。

<Sdk id="arm64-openat-handler" />

包装转换参数之后进入通用打开路径。fd 的预留、错误归还和成功安装在下一段。

<Sdk id="open-install-fd" />

### 5. 恢复现场并返回

invoke_syscall 将结果写回保存的寄存器。异常退出路径检查待处理的工作，例如信号或需要调度，然后恢复寄存器和异常返回状态。回到 EL0 后，原始调用看到 x0。标准 C 调用通常由 libc 将负错误码转换成 −1 并设置 errno。EL0 切到 EL1 时，内核可以继续替同一线程执行。如果打开过程需要睡眠，或退出时发现需要重新调度，才可能切换到另一任务。单凭 SVC 不足以数出调度次数。

<Sdk id="arm64-return-el0" />

## 本节复盘

- **什么时候知道用户传的是错误地址？** 向量与分派阶段只把寄存器带进来。实现读取用户路径时才可能因地址不可访问得到 EFAULT。用户地址有效但查无路径时则可能是 ENOENT。
- **非法系统调用号和系统调用参数无效，怎么分？** 前者从分派表的边界和缺省项查 ENOSYS。后者已进入某项实现，应记录原始参数和具体返回点。
- **如何确认有过调度切换？** 用同一个 TID 对照 sched_switch 等事件，标明时间窗口。SDK 的源码和宿主的静态反汇编只能说明预期的执行结构。[调度器的切换条件](../03-Linux内核/调度器实现.md)

下一节从 do_sys_openat2 继续追路径、设备号和一次打开的文件对象。[2.3 VFS 中的路径、设备号与一次打开](first-lesson.md#vfs)
