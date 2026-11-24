# 2.4 模块、内建驱动与 Kbuild

从 WSL 项目根目录执行。先问“这次构建选了哪一项”，再去找文件。tristate 配置取 y 时对象进入内建链接，取 m 时由模块链接产生 .ko，未选择时相应对象不会由这条规则加入。

~~~bash
sdk=atk_dlrv1126b_linux6.1_sdk
base="$sdk/output/kernel-baseline/normal"
rg 'CONFIG_VIDEO_IMX415=' "$base/.config"
rg 'CONFIG_VIDEO_IMX415' "$sdk/kernel-6.1/drivers/media/i2c/Makefile"
rg '/imx415\.ko$' "$base/modules.builtin"
rg -w 'imx415_probe' "$base/System.map"
cat learning-site/examples/char/Kbuild
~~~

本地基线选择 y。Makefile 的 obj-$(CONFIG_VIDEO_IMX415) 在本次展开为 obj-y。内建索引里的 .ko 后缀是模块名称的索引形式，看到这一行就知道为什么文件系统里可以找不到独立 imx415.ko。System.map 再提供最终链接有 probe 符号的证据。反过来，lsmod 只列已加载模块，无法枚举内建驱动。

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

### 用同一份配置编译独立模块

先完成基线内核构建，确认 `normal/Module.symvers` 存在。在仓库根目录执行。`M=` 告诉 Kbuild 外部模块所在目录，`Kbuild` 中唯一一行是 `obj-m := rvnote.o`。

~~~bash
(
set -eu
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
lab="$PWD/output/textbook-check/char"
cross="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
mkdir -p "$lab"
cp learning-site/examples/char/{rvnote.c,Kbuild} "$lab/"
test -f "$sdk/output/kernel-baseline/normal/Module.symvers"
make -C "$sdk/kernel-6.1" O="$sdk/output/kernel-baseline/normal" M="$lab" ARCH=arm64 CROSS_COMPILE="$cross" modules
file "$lab/rvnote.ko"
)
~~~

在 WSL 仓库根目录执行。交叉工具链中的 `readelf` 可以直接读取上一节生成的 `.ko`，包括模块元数据和需要内核提供的符号。

~~~bash
(
set -euo pipefail
sdk="$PWD/atk_dlrv1126b_linux6.1_sdk"
base="$sdk/output/kernel-baseline/normal"
tool="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-readelf"
mod=output/textbook-check/char/rvnote.ko
cat "$base/include/config/kernel.release"
"$tool" -p .modinfo "$mod" | rg 'vermagic=|name='
"$tool" -Ws "$mod" | rg 'UND.*misc_(register|deregister)'
rg '[[:space:]]misc_(register|deregister)[[:space:]]' "$base/Module.symvers"
)
~~~

`kernel.release` 给出构建树的发布字符串。`scripts/mod/modpost.c` 生成的模块元数据引用 `VERMAGIC_STRING`，其中包含发布字符串和若干构建特征。`misc_register`、`misc_deregister` 在模块的符号表中是 `UND`，表示由内核解析。`Module.symvers` 中可查到相应导出记录。当启用 `CONFIG_MODVERSIONS` 时，还要核对符号版本。即使实际板端的 `uname -r` 与构建树相同，也只完成了发布字符串这一项核对。

源码摘录 `kernel-6.1/include/linux/vermagic.h:42–47`

~~~c
#define VERMAGIC_STRING 						\
	UTS_RELEASE " "							\
	MODULE_VERMAGIC_SMP MODULE_VERMAGIC_PREEMPT 			\
	MODULE_VERMAGIC_MODULE_UNLOAD MODULE_VERMAGIC_MODVERSIONS	\
	MODULE_ARCH_VERMAGIC						\
	MODULE_RANDSTRUCT
~~~

这里定义版本信息由哪些标志组成。modpost 再把该定义写进模块的生成文件。

源码摘录 `kernel-6.1/scripts/mod/modpost.c:1951–1956`

~~~c
buf_printf(b, "MODULE_INFO(vermagic, VERMAGIC_STRING);\n");
buf_printf(b, "MODULE_INFO(name, KBUILD_MODNAME);\n");
buf_printf(b, "\n");
buf_printf(b, "__visible struct module __this_module\n");
buf_printf(b, "__section(\".gnu.linkonce.this_module\") = {\n");
buf_printf(b, "\t.name = KBUILD_MODNAME,\n");
~~~

本次交叉构建得到 `vermagic=6.1.141 SMP mod_unload aarch64`，两条 `misc_*` 符号都能在 `Module.symvers` 中找到。目标板能否加载仍待在匹配的实验内核上验证。

**复盘。** 一个 .ko 成功生成、能解析到符号、能在当前机器加载，是三个阶段。用文件类型判断 CPU 架构，用 vermagic、导出符号及配置检查 ABI，再由目标内核验证实际加载策略。在卷一看到的 HOSTCC 错误则发生在构建主机阶段。

## 从 Kconfig 到运行中的驱动，分四次取证

| 阶段 | 看什么 | 对本板意味着什么 |
| --- | --- | --- |
| 选项求解 | Kconfig 的类型、depends on 和实际输出目录的 .config | defconfig 是输入，只有最终 .config 表示本次选择。若上游目录没进入构建，局部规则也不会产生对象 |
| 对象组织 | Makefile 中的 obj-y 和 obj-m | 内建对象参与构造内核，模块对象经过独立的模块处理和链接。CONFIG 项缺失时，条件规则不选该对象 |
| 产物核查 | modules.builtin、System.map、modules.order、实际 .ko | 按同一次构建交叉核对。内建索引中出现 imx415.ko，配合 y 和内核符号才形成完整证据链 |
| 目标运行 | 运行内核版本、驱动注册、总线匹配、绑定链接与 probe 日志 | 构建产物里有代码，不证明板子已经运行该产物或 sensor 已绑定 |

内建和模块的初始化入口都能写成 module_init。查看头文件的两边分支。内建时展开为 initcall，由内核启动过程调用。作为模块时则导出模块初始化入口，加载器完成加载准备后调用它。初始化成功通常只是把驱动登记给框架。匹配的设备是否出现，probe 是否成功，是另一组事件。退出函数用于模块卸载时反向撤销，能否卸载还受构建配置、模块引用与系统策略影响。

源码摘录 `kernel-6.1/include/linux/module.h:87–92`

~~~c
#define module_init(x)	__initcall(x);

/**
 * module_exit() - driver exit entry point
 * @x: function to be run when driver is removed
 *
~~~

宏决定初始化入口如何导出。模块加载准备完成后，运行内核才会调用它。

源码摘录 `kernel-6.1/kernel/module/main.c:2454–2459`

~~~c
static noinline int do_init_module(struct module *mod)
{
	int ret = 0;
	struct mod_initfree *freeinit;

	freeinit = kmalloc(sizeof(*freeinit), GFP_KERNEL);
~~~

## 外部模块为什么要借用同一构建树？

上面的命令中，`-C` 选择内核源码入口，`O=` 指向该内核已生成的配置、头文件和符号信息，`M=` 选择要构建的外部模块目录，`ARCH` 与 `CROSS_COMPILE` 决定目标架构和工具链。只改 M 就能切换外部模块，但改变 O 可能让它按另一份配置生成。如果只拿到一份源码和 defconfig，不应假定已经有真实的导出符号及版本表。尤其启用 CONFIG_MODVERSIONS 时，modules_prepare 也不会替代完整构建生成 Module.symvers。

复跑后从实验目录检查这些中间结果。第一条给出模块顺序文件，第二条查看 modpost 生成的 C 元数据，第三条确认引用了哪些外部符号。

~~~bash
lab=output/textbook-check/char
cat "$lab/modules.order"
rg -n 'VERMAGIC_STRING|MODULE_INFO|[.]init' "$lab/rvnote.mod.c"
readelf -Ws "$lab/rvnote.ko" | rg 'UND.*misc_(register|deregister)'
~~~

把 `UND misc_register` 解释清楚。符号由运行内核或相应模块提供。构建时 modpost 用导出表核对，加载时仍由目标内核检查和解析。普通内核符号存在于 System.map 并不保证对模块导出。模块是否采用正确的 GPL 声明、符号命名空间或版本，也要看对应接口。

### 模块加载失败时如何区分

| 症状或证据 | 首先核对 | 如何验证 |
| --- | --- | --- |
| 文件不存在 | 是内建选项、模块未生成，还是没安装到目标 | 先查配置、同一目录的内建清单或 .ko，再查目标文件路径 |
| Invalid module format | 架构、版本元数据和其他格式条件 | 在宿主读 ELF 和 .modinfo，现场错误以目标内核日志为准 |
| Unknown symbol 或版本不一致 | 模块依赖、导出资格和符号版本 | 对照模块的 UND、对应构建的 Module.symvers 以及已加载对象 |
| 加载完成却没有预期节点 | 初始化是否登记、是否匹配、probe 是否成功 | 核对初始化返回、框架登记以及 sysfs 的设备和 driver 链接 |

内核加载路径会比较版本信息。模块签名以及模块加载策略也可能在其他阶段阻止加载。不要为了定位一次失败去关闭这些检查。文中执行的是本地交叉编译和离线取证。

源码摘录 `kernel-6.1/kernel/module/main.c:1959–1964`

~~~c
static int check_modinfo(struct module *mod, struct load_info *info, int flags)
{
	const char *modmagic = get_modinfo(info, "vermagic");
	int err;

	if (flags & MODULE_INIT_IGNORE_VERMAGIC)
~~~

**本节复盘。** 如果对方说“lsmod 没有 imx415，说明没编进去”，先指出 lsmod 显示的对象集合，再给出内建索引和内核符号的对照。然后区分 `rvnote.ko` 成功生成、目标加载成功、设备节点可用和实际 read 回调运行这四件事。接下来从设备号和操作表解释节点怎么进入驱动。[2.5 字符设备号与 file_operations](char-fops.md)
