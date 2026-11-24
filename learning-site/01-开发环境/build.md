# 1.6 编译、链接、ELF、符号与交叉工具链

应用编译结束后，板端还需要哪些文件才能执行它？用后续查询视频节点能力的同一个 C 文件做对照。它调用 `open` 和 `ioctl`。这一节先在 WSL 看它们何时出现为符号，跟到板上运行的部分留给采集实验。

## 拆开一条 gcc 命令 {#elf}

在 WSL 项目根目录运行。从上到下执行，后续命令会读取前面生成的文件。产物放入 Git 忽略目录。

~~~bash
src=learning-site/examples/querycap.c
lab=output/textbook-check/querycap-elf
tool="$PWD/atk_dlrv1126b_linux6.1_sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
mkdir -p "$lab"
cc -E "$src" -o "$lab/host.i"
cc -S "$lab/host.i" -o "$lab/host.s"
cc -c "$lab/host.s" -o "$lab/host.o"
cc "$lab/host.o" -o "$lab/host"
"${tool}gcc" -Wall -Wextra -Werror "$src" -o "$lab/target"
file "$lab"/{host.o,host,target}
nm -u "$lab/host.o"
readelf -h "$lab/target" | rg 'Machine:|Entry point'
readelf -l "$lab/target" | rg 'interpreter'
readelf -d "$lab/target" | rg 'NEEDED'
"${tool}gcc" -print-sysroot
~~~

| 停在哪一步 | 看哪个文件 | 如果失败，从哪里查 |
| --- | --- | --- |
| 预处理 | `host.i` 展开头文件和宏，已经包含结构体声明 | 找不到 `linux/videodev2.h` 时检查**该编译器**的头文件搜索路径 |
| 编译 | `host.s` 是给主机 CPU 的汇编 | 类型或参数错误要回到报错的 C 表达式 |
| 汇编 | `host.o` 已有机器指令。符号表里 `U ioctl` 表示该对象引用了外部实现 | `readelf -h` 查看机器架构。链接输入必须能用于同一目标 |
| 链接 | `host` 有可执行入口；动态依赖由加载器在运行时解析 | 链接错误先核对参与链接的对象和库，运行时报缺库则查看目标根文件系统 |

这里的宿主产物为 x86-64，目标产物为 AArch64。目标程序请求解释器 `/lib/ld-linux-aarch64.so.1`，并声明对 `libc.so.6` 的依赖。先记录这三个结果，下面分别用区表、程序头和动态节解释它们。

### ELF 的区和段分别给谁用

用同一个对象和两个可执行文件继续检查。区表描述给链接器和分析工具看的内容，例如指令所在的 .text、重定位记录和符号表。段表描述装载时要怎样处理整个文件，例如哪一段内容映到什么虚拟地址、权限是什么。同一个 LOAD 段可以容纳多个区。这里的“段”按 ELF 程序头理解。通常听到的代码段 .text 在 ELF 区表里实际是一项区。可重定位对象通常没有装载段，链接器先把区组织成最终产物，内核再按程序头来映射。宿主实验中，.o 为 REL。AArch64 动态版为 EXEC，入口为 0x4006c0，程序头分别列出包含 .text 的可执行映射和读写映射。不同发行版及链接选项可能得到 PIE，Type 也会变化。

~~~bash
lab=output/textbook-check/querycap-elf
readelf -h "$lab/host.o" | rg 'Type:|Machine:'
readelf -SW "$lab/host.o" | rg '\.text|\.rela\.text|\.symtab'
readelf -rW "$lab/host.o" | rg 'open|ioctl'
readelf -h "$lab/target" | rg 'Type:|Machine:|Entry point'
readelf -lW "$lab/target" | rg 'INTERP|LOAD|Section to Segment|\.text'
nm -D "$lab/target" | rg 'open|ioctl'
~~~

- 在宿主对象中，`U ioctl` 与调用点的重定位记录同时存在。编译器已经生成调用指令，链接所需的目标信息仍由符号和重定位提供。未定义符号出现在 .o 中是正常的。
- 链接采用共享 libc 后，最终可执行文件仍可能保留动态未定义符号。链接器已为这些符号安排动态解析，并在动态节记录 NEEDED。装载器加载所需库，再按 ABI 和符号版本完成解析。查这些动态依赖用 `readelf -d` 或 `nm -D`。
- 进程入口由 ELF 头中的入口地址表示。通常先进入启动代码，完成 C 运行时初始化才调用 main。ELF 的 INTERP 段要求内核先装入另一个 ELF，动态情况下控制权会先交给解释器。

在本版 Linux 找 `load_elf_binary`，沿程序头寻找 PT_INTERP。函数读出其中的路径并调用 `open_exec`，错误指针通过 PTR_ERR 转回负错误码。解释器路径没有找到时，外层 exec 可能返回 ENOENT，即使原程序本身确实存在。

源码摘录 `kernel-6.1/fs/binfmt_elf.c:900–905`

~~~c
if (elf_ppnt->p_type != PT_INTERP)
	continue;

/*
 * This is the program interpreter used for shared libraries -
 * for now assume that this is an a.out format binary.
~~~

### sysroot、动态链接与静态链接

查看前面 `-print-sysroot` 的输出。交叉编译器运行在 WSL，解析目标 C 库头文件以及链接所需目标库时使用自己的目标搜索路径。sysroot 将这类路径扎根在一套目标文件目录中，编译器仍有自己的内建头与库搜索规则。构建完成后，板端装载器从它实际所在的根文件系统查依赖。宿主 sysroot 的目录前缀不会被复制到 PT_INTERP。

~~~bash
lab=output/textbook-check/querycap-elf
src=learning-site/examples/querycap.c
tool="$PWD/atk_dlrv1126b_linux6.1_sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
"${tool}gcc" -Wall -Wextra -Werror -static "$src" -o "$lab/target-static"
file "$lab"/{target,target-static}
stat -c '%n %s 字节' "$lab"/{target,target-static}
if readelf -lW "$lab/target-static" | rg 'INTERP'; then
    echo '这个静态示例意外包含解释器段'
    exit 1
fi
readelf -d "$lab/target-static"
~~~

这条 `-static` 命令要求 SDK 存在目标静态库。示例静态产物不含 INTERP 和动态节。它仍依赖目标内核支持所用系统调用，打开视频节点也仍取决于权限、驱动和能力。本次动态版和静态版分别为 15,744 和 3,724,224 字节，都未去除符号。两份文件的体积比较只对这套工具、源码和构建选项有效。动态程序部署到另一套根文件系统时还要核对加载器路径、库 SONAME 和版本，AArch64 架构相同只能排除一类失败。

### 用宿主实验区分链接失败与装载失败

保留相同的 C 源码、宿主架构和执行权限，仅给另一个可执行文件指定一个不存在的解释器。再对比去掉默认库后的链接错误。以下命令在 Bash 里运行，临时文件会清理。

~~~bash
(
set -eu
export LC_ALL=C
src=learning-site/examples/querycap.c
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT

if cc -nodefaultlibs "$src" -o "$lab/link-failed" >"$lab/link.log" 2>&1; then
    echo '本例预期去掉默认库后链接失败'
    exit 1
fi
rg -m3 'undefined reference' "$lab/link.log"

cc "$src" "-Wl,--dynamic-linker,$lab/missing-loader" -o "$lab/no-loader"
test -x "$lab/no-loader"
test ! -e "$lab/missing-loader"
readelf -lW "$lab/no-loader" | rg 'Requesting program interpreter'
status=0
"$lab/no-loader" /dev/null || status=$?
printf '退出码=%s\n' "$status"
test "$status" -eq 127
)
~~~

第一条失败发生在链接阶段，可看到 libc 相关未定义引用。第二次链接成功，目标文件具有执行权限，Bash 仍报告无法执行并退出 127。原因可以从 INTERP 中直接找到。下一段运行解释器正常的宿主版，此时程序能进入 main，并走到调用具体设备的路径。两种故障的定位点不同。

### 用 /dev/null 区分构建与运行错误

~~~bash
status=0
output/textbook-check/querycap-elf/host /dev/null || status=$?
echo "退出码=$status"
test "$status" -eq 1
~~~

本次得到 `VIDIOC_QUERYCAP: Inappropriate ioctl for device` 和退出码 1。程序成功启动并打开字符节点，失败发生在能力查询。将参数换成不存在的路径，程序会停在 `open` 并给出该阶段的报错。若改用目标文件交给主机执行，行为还取决于主机有无模拟器；直接读 ELF 头即可验证架构。复盘时能解释三种失败就达到了本节目标：编译找不到头文件、加载器找不到依赖、设备拒绝 ioctl。

接下来可直接[跟一次上电到 PID 1](boot.md)。以下命令留给需要构建内核基线时查阅。

## 用已有工具链生成独立输出

WSL 从工作区根目录执行。依赖是本工作区上一轮解包的 host 工具和 SDK 自带的 AArch64 GCC。步骤在 `output/kernel-baseline/textbook` 中生成候选产物，基线保存在 `normal`。先用 `df -h .` 估算空间，保留编译首条错误。候选屏幕 DTS 是否就是板上启动的那份，仍需核对。

~~~bash
(
set -eu -o pipefail
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
base="$sdk/output/kernel-baseline"
out="$base/textbook"
cross="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
export PATH="$base/host/usr/bin:$PATH" BISON_PKGDATADIR="$base/host/usr/share/bison" M4="$base/host/usr/bin/m4"
test -x "$M4"
test -f "$base/host/usr/include/x86_64-linux-gnu/openssl/opensslconf.h"
mkdir -p "$out"
cd "$sdk/kernel-6.1"
args=(O="$out" ARCH=arm64 CROSS_COMPILE="$cross"
      HOSTCFLAGS="-I$base/host/usr/include -I$base/host/usr/include/x86_64-linux-gnu"
      HOSTLDFLAGS="-L$base/host/usr/lib/x86_64-linux-gnu")
make "${args[@]}" alientek_rv1126b_defconfig
make "${args[@]}" -j4 Image modules rockchip/rv1126b-alientek-mipi720x1280.dtb 2>&1 | tee "$out/build.log"
file "$out/vmlinux" "$out/arch/arm64/boot/Image" "$out/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
)
~~~

## 沿 Kconfig、Makefile 和内建清单读一次 IMX415

~~~bash
cd atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'config VIDEO_IMX415' drivers/media/i2c/Kconfig
rg -n 'CONFIG_VIDEO_IMX415' drivers/media/i2c/Makefile ../output/kernel-baseline/normal/.config
~~~

Kconfig 声明选项、类型和依赖。defconfig 给出板型建议，生成的 `.config` 才是本次求解后的选择。Kbuild 的 `obj-$(CONFIG_VIDEO_IMX415)` 把选择映射为内建对象、可加载模块或忽略。`y` 时要在内核对象/符号中找驱动，`m` 时要考虑根文件系统中的模块、依赖和加载时机。主机还会编译并运行 dtc 等工具，设置 `CROSS_COMPILE` 无法解决 host 缺少头文件。

源码摘录 `kernel-6.1/scripts/kconfig/Makefile:93–98`

~~~make
%_defconfig: $(obj)/conf
	$(Q)$< $(silent) --defconfig=arch/$(SRCARCH)/configs/$@ $(Kconfig)

configfiles=$(wildcard $(srctree)/kernel/configs/$@ $(srctree)/arch/$(SRCARCH)/configs/$@)

%.config: $(obj)/conf
~~~

默认配置目标提供输入。选项是否可选及依赖什么，要看驱动自己的 Kconfig。

源码摘录 `kernel-6.1/drivers/media/i2c/Kconfig:810–815`

~~~text
config VIDEO_IMX415
	tristate "Sony IMX415 sensor support"
	depends on I2C && VIDEO_DEV
	depends on MEDIA_CAMERA_SUPPORT
	select MEDIA_CONTROLLER
	select VIDEO_V4L2_SUBDEV_API
~~~

实际构建选择由输出目录的 .config 给出。Makefile 再把这个选择转换成对象是否参与构建。

源码摘录 `kernel-6.1/drivers/media/i2c/Makefile:106–111`

~~~make
obj-$(CONFIG_VIDEO_IMX415) += imx415.o
obj-$(CONFIG_VIDEO_IMX464) += imx464.o
obj-$(CONFIG_VIDEO_IMX492) += imx492.o
obj-$(CONFIG_VIDEO_IMX498) += imx498.o
obj-$(CONFIG_VIDEO_IMX577) += imx577.o
obj-$(CONFIG_VIDEO_IMX582) += imx582.o
~~~

如果要确认当前源码仍能生成同样的默认配置，从 WSL 仓库根目录运行下面这段。`O=` 指向单独的目录，只生成配置所需的宿主工具和 `.config`。完整内核构建可沿用上一节。

~~~bash
(
set -euo pipefail
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
base="$sdk/output/kernel-baseline"
out="$PWD/output/textbook-check/rv1126b-config"
cross="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
export PATH="$base/host/usr/bin:$PATH"
export BISON_PKGDATADIR="$base/host/usr/share/bison" M4="$base/host/usr/bin/m4"
make -s -C "$sdk/kernel-6.1" O="$out" ARCH=arm64 CROSS_COMPILE="$cross" alientek_rv1126b_defconfig
rg '^CONFIG_VIDEO_IMX415=' "$out/.config"
"$sdk/kernel-6.1/scripts/diffconfig" "$base/normal/.config" "$out/.config"
)
~~~

本次生成结果为 `CONFIG_VIDEO_IMX415=y`，`diffconfig` 没有输出，表示两份配置的选项相同。有输出时先读具体选项及其依赖。`diffconfig` 会打印差异内容，不能把进程退出码 0 当成两份配置相同的证据。

回到 WSL 的仓库根目录，逐项检查已有 `normal` 产物。看到 `modules.builtin` 中的 `imx415.ko` 路径时，核对同一次构建的 `.config` 和符号表再判断驱动放在哪里。清单以模块形式命名其条目，供工具识别哪些驱动已在内核内部。

~~~bash
base=atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal
rg '^CONFIG_VIDEO_IMX415=' "$base/.config"
rg '(^|/)imx415\.ko$' "$base/modules.builtin"
rg '[[:space:]]imx415_probe$' "$base/System.map"
file "$base/scripts/kconfig/conf" "$base/scripts/dtc/dtc"
file "$base/vmlinux" "$base/arch/arm64/boot/Image" \
  "$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"
~~~

预期 `CONFIG_VIDEO_IMX415=y`，清单里出现 `kernel/drivers/media/i2c/imx415.ko`，`System.map` 列出 `imx415_probe`。三条对应内建选择、内建索引和最终符号。同一构建目录的 conf 和 dtc 是 x86-64，vmlinux 是 AArch64。用这三份文件可以直接复核两套编译器各自产出了什么。若查看的是 `m` 配置，应进一步核对 `modules.order`、实际生成的 `.ko` 及该次内核的发布版本。外部字符模块的构建与匹配实验可沿用同一个输出目录。[编译便笺字符模块](../02-应用与字符驱动/char-driver.md)

## 从第一次失败读构建日志

先从对象的**使用地点**判断参与构建的是哪套编译器。Kconfig 的 conf 和设备树编译器 dtc 在构建期间由 WSL 执行，必须能在 WSL 上运行。Image、vmlinux 和内核模块由目标处理器运行，编译与链接面向 AArch64。Kbuild 的 ARCH 决定内核架构与配置路径，CROSS_COMPILE 提供目标工具前缀，二者不会给宿主工具改架构。

在 `scripts/Makefile.host` 看 cmd_host-csingle。命令从 HOSTCC 起步，拿 hostc_flags 和 KBUILD_HOSTLDFLAGS 生成宿主可执行文件。命令边上的 HOSTCC 标签是在简洁日志里识别这一路的入口，V=1 可查看实际命令行。错误发生时先定位正在生成哪个文件、它由谁执行，再分别检查头文件和库。

源码摘录 `kernel-6.1/scripts/Makefile.host:109–114`

~~~make
# host-csingle -> Executable
quiet_cmd_host-csingle 	= HOSTCC  $@
      cmd_host-csingle	= $(HOSTCC) $(hostc_flags) $(KBUILD_HOSTLDFLAGS) -o $@ $< \
		$(KBUILD_HOSTLDLIBS) $(HOSTLDLIBS_$(target-stem))
$(host-csingle): $(obj)/%: $(src)/%.c FORCE
	$(call if_changed_dep,host-csingle)
~~~

| 简洁日志的线索 | 查什么 | 哪条证据能改变判断 |
| --- | --- | --- |
| `HOSTCC` 后缺头 | 宿主编译器、宿主头文件搜索路径 | 完整命令中缺包含目录，或本地宿主头文件确实不存在 |
| `HOSTLD` 后缺库 | 宿主链接选项、库架构 | file 检查候选库对应对象的架构，核对 -L 指向的目录 |
| 目标 `CC` 后报错 | ARCH、目标编译器、Kconfig 与目标源码 | 完整编译命令和实际选择的 .config |
| 找不到 flex、bison 或 m4 | 这些构建期工具的可执行路径或其调用配置 | shell 能找到工具，但日志显示其子程序从另一条路径启动时继续查子程序 |


本项目曾因 host 缺 flex、bison、m4 及 OpenSSL 架构头文件而阻塞。遇到 `openssl/opensslconf.h` 时，先读失败命令开头究竟是 `HOSTCC` 还是目标 `CC`，再看缺失头在哪个架构目录。历史构建在 `HOSTCFLAGS` 中加入本地宿主头文件的路径，再用完整构建的退出码、Image、模块结果及目标 DTB 复核。`tee` 会引入管道，`pipefail` 保留 make 的失败状态。上一轮基线已编译完成，新内核的启动行为仍需部署验证。

## 从内核产物回查 SDK 打包入口

~~~bash
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
rg -n 'RK_KERNEL_DTS_NAME|RK_KERNEL_MULTI_DTS' "$sdk/device/rockchip/.chips/rv1126b" | sed -n '1,20p'
rg -n 'RK_KERNEL_DTS_NAME|boot.img|mkbootimg|mk-fitimage' "$sdk/device/rockchip/common/scripts/mk-kernel.sh" | sed -n '1,25p'
ls "$sdk/device/rockchip/common/scripts"/{mk-rootfs.sh,mk-firmware.sh}
~~~

第一个命令会看到 auto-MIPI 和固定屏幕版本。auto 配置还能列出多个 DTB，这解释了为什么 build 目录里有一份 DTB 不能证明 bootloader 选了它。`mk-kernel.sh` 描述厂商如何组织内核相关产物，`mk-rootfs.sh` 与 `mk-firmware.sh` 分别是用户空间和固件阶段的入口。真正部署前应记录引导日志里所选配置、运行活动树、现有可恢复镜像与校验值，并核对板修订。仅修改 GStreamer 或 IQ 文件通常属于 rootfs/运行配置；仅修改 sensor 驱动需判断它是内建还是模块；修改引脚接线描述则需更新引导器实际加载的 DTB。这样才知道该重建哪一层。

流程示例（自写），对照位置 `device/rockchip/common/scripts/mk-kernel.sh:88–93`

~~~bash
read -r -a candidates <<< "$RK_KERNEL_MULTI_DTS"
(( ${#candidates[@]} > 0 )) || exit 1
# 每个候选项后续分别用于生成对应 DTB。
~~~

## 本节复盘

- 给两份 ELF 各写一行 `Machine → Type → Entry → INTERP → NEEDED`，再用宿主 .o 的符号和重定位解释一处 `U ioctl`。说明区表供哪一环处理、哪个程序头决定动态解释器。
- 程序路径存在，为什么启动仍可能返回 ENOENT？先对照 INTERP 的完整路径，再区分解释器缺失与应用进入 main 后 open 失败。给一个证据能判断自己在哪个阶段。
- 换 CROSS_COMPILE 为什么不能解决 HOSTCC 缺头？把 WSL 要执行的 conf 和板端要运行的 Image 分别写在两列，再根据日志标签选择修复位置。记录第一处失败、修改的变量和复验结果。
- 两个 defconfig 的名字都含 RV1126B，怎样选？用运行板配置和隔离配置做 diffconfig，并结合设备树与硬件。配置相同后继续验证编译器、补丁、引导器选件及活动树。

下一节用这几个可执行物和启动配置解释从复位到第一个用户进程的过程。[从上电读到 PID 1](boot.md)
