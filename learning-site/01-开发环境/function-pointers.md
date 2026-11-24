# 1.5 用 C 表达驱动里的数据和回调

<script setup>
import exampleFile from '../examples/byte_order.c?url'
</script>

打开 RV1126B 的摄像头驱动，搜 `imx415_s_stream(`，很容易找到函数定义，却不容易找到谁调用了它。字符设备驱动也有这个现象。应用写的是 `open("/dev/rvnote", O_RDWR)`，驱动实现的函数却叫 `note_open`。应用没有包含驱动的头文件，两个名字也对不上。内核究竟靠什么把它们接起来？

先单步执行一行 C，再用同样的方法读懂本地 SDK 中的 `filp->f_op->open(inode, filp)`。读代码时反复问自己，**谁决定执行哪段代码？谁保存这次操作的数据？** 先把字节、结构体与回调三项的结果算出来，再到 Linux 中追对象和调用。实验用 WSL 和 `cc`，源码跟读另需工作区中的厂商 SDK。板子可以断开。

## 从两个字节读懂一个字段 {#bytes}

在第一次读驱动前，先画出内存里的字节。`u8` 可以装一个八位字节，`u16` 可以装一个 16 位寄存器地址。同一个数 0x1234 要分两次送上总线，双方须约定哪个字节先到。IMX415 的读函数先做 `cpu_to_be16(reg)`，再把这两个字节交给第一条 I2C 消息。这里用位图手工重建读两个字节的场景。

手算得到 `12 34 | 00 00 01 23 | 291 | 0x23`。地址和返回值是两段独立的数据。驱动先把四字节接收槽清零，`len=2` 时让控制器从偏移 `4-len` 写入，再用 `be32_to_cpu` 转为主机整数。掩码 `& 0xff` 留下低八位，不改变原缓冲的字节顺序。动手把两字节改成 `23 01`，先预测哪个结果受影响。寄存器地址保持原值。

<Sdk id="i2c-read" />

跟到参数 `u32 *val`。这是调用者提供的结果地址。函数返回的 `int` 单独报告成功或失败，成功才写 `*val`。长度为零或大于四会直接返回 `-EINVAL`，防止缓冲范围失效。数组 `msgs[2]` 在本次同步调用期间有效；若异步保存它的首地址，函数退出后便没有可供继续使用的数组。对照下一段温度计，逐次指出“哪个变量保存数据，谁只是指向它”。对任何指针还要问两件事：调用约定是否允许 NULL，以及它指向的对象能活多久。

### 先决定宽度，再决定字节顺序

主机算出一个整数后，接口通常还要决定怎样把它放进缓冲。读字段时先问四件事：有多少位、按有符号还是无符号解释、字节顺序由谁规定、长度或范围无效时谁拒绝。

| 使用场景 | 适合从什么类型起步 | 要额外核对什么 |
| --- | --- | --- |
| Linux 驱动的固定宽度字段 | `u8`、`u16`、`u32` 等内核类型 | 总线或寄存器文档的端序与有效位 |
| 宿主 C 示例的固定宽度字段 | `stdint.h` 中的 `uint8_t`、`uint16_t`、`uint32_t` | 转换与移位前后的类型，尤其是窄类型的整数提升 |
| 缓冲和对象长度 | `size_t` | 元素数乘元素宽度是否溢出，是否超过实际容量 |
| 内核中明确携带端序的对象 | 如 `__be16`、`__be32` | 与主机整数相互转换的时机 |

端序描述多字节对象怎样排在内存或线上。掩码把一个**整数中的固定位**取出，两者属于不同层。以寄存器地址 `0x1234` 为例，按大端约定发送高字节 `12`，再发送低字节 `34`。接收端将大端字节 `01 23` 合成 `0x0123` 后，掩码 `& 0xff` 取低八位；内存中第零字节是什么仍取决于具体缓冲。驱动一般用端序辅助函数或按字节组装。直接把字节缓冲强转成宽指针读取，还需满足对齐和对象类型等条件。

下面在 WSL 项目根目录运行。先预测本机对象和协议缓冲的前两个字节，再核对十六进制与十进制输出。

<a :href="exampleFile" download="byte_order.c">完整端序实验</a>，仓库路径为 `learning-site/examples/byte_order.c`。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
cc -std=c11 -Wall -Wextra -Werror learning-site/examples/byte_order.c -o "$lab/bytes"
"$lab/bytes"
)
~~~

窄整数参与算术时会先做整数提升。比如 `uint8_t x = 255`，计算 `x + 1` 得到整数 256；再显式转换为 `uint8_t` 才得到 0。驱动里将接收字节扩到足够宽的无符号类型再移位，可以把想要的宽度直接写进表达式。判断第 n 位时先核对 n 小于该操作数的位数，再写 `(value & (UINT32_C(1) << n)) != 0`。

当前 WSL 实测 `host=34 12 wire=12 34 array=2 bytes` 和 `value=291 low=0x23`。换成大端主机时，第一组可能变成 `12 34`，显式生成的协议缓冲仍是 `12 34`。修改 `reply` 的两个字节位置后重跑，合成值应为 8961，低八位为 `0x01`。这里的字节合成是宿主实验；IMX415 驱动将读取内容送进四字节槽位再用 `be32_to_cpu` 得到同一类数值。

### 数组、指针和结构体分别持有什么

`unsigned char wire[2]` 对应两个连续元素，`sizeof(wire)` 在定义它的作用域为 2。把它传给参数形如 `const unsigned char *buf` 的函数时，传的是首元素地址。函数中的 `sizeof(buf)` 是指针本身的大小，调用者要另外传有效长度。结构体可以同时放长度、缓冲和其他状态。结构体内的数组属于该实例；结构体内的指针只记录地址，所指对象可能在另一处。复制结构体时数组内容随值复制，指针成员复制的是地址，两份结构体仍可能引用同一对象。

回到 I2C 源码，`msgs[2]` 拥有两条消息实体，`msgs[1].buf = &data_be_p[4 - len]` 只保存接收缓冲的一个地址。控制器按 `msgs[1].len` 写入。驱动先把 `len` 限定在 1～4，才能保证起点与末端都落在四字节对象内。因为 `i2c_transfer` 在返回前完成同步传输，本次调用可以使用自动存储期的数组和接收槽。把同样的地址交给可能在函数返回后执行的工作，就需要由更长寿的对象持有缓冲，并约定谁在完成或取消时释放。

## 1. 从一个可以复现的现象开始

在 WSL 的项目根目录打开终端。下列命令把程序编译给当前 WSL，产物放在 Git 忽略的 `output/` 中。`-O0 -g` 保留便于调试的代码和符号，`-Werror` 让类型不匹配之类的警告阻止本次编译。

~~~bash
mkdir -p output/textbook-check
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O0 -g \
  learning-site/examples/function_pointers.c -o output/textbook-check/function_pointers
./output/textbook-check/function_pointers
~~~

先看代码中的 `main`。A 采到 20 °C，需要加 2 °C 的校正量。B 采到 27 °C，需要加 1 °C。两支温度计最初都报告原始值。运行前先预测。切换 A 的算法后，B 会怎样？通过 `alias` 把采样值改为 24 后，读 A 会输出什么？这几次读数有没有修改 `show_reading` 的实现？

`examples/function_pointers.c:25`

~~~c
static const struct thermometer_ops raw_ops = {
    .read_c = read_sample,
};

static const struct thermometer_ops calibrated_ops = {
    .read_c = read_calibrated,
};
~~~

先看两张表各登记了谁。调用处拿到实例后，沿实例的 ops 取表；传给回调的 meter 则决定读取哪个实例。

<details>
<summary>查看在本工作区 WSL 的实测输出，逐行对照自己的预测</summary>

~~~text
A direct = 20 °C
A raw = 20 °C
B raw = 27 °C
A calibrated = 22 °C
A after alias = 26 °C
B unchanged = 27 °C
~~~

前两行用同一输入走两种调用写法。第三行只换了实例。第四行相对第二行只换了 A 的操作表。第五行相对第四行只改了 A 的数据。最后再读 B，是为了检验改 A 是否连带改了同用过 `raw_ops` 的 B。

</details>

## 2. 把一行间接调用拆成三个动作

直接写 `read_sample(&a)` 时，函数名写在调用处，`&a` 取 A 的地址。在 `show_reading` 里我们只知道有一支温度计，怎么读它由传入的对象决定。要看懂这个约定，先分别读下面三个表达式。

| C 写法 | 怎样读 | 在例子中起什么作用 |
| --- | --- | --- |
| `int (*read_c)(const struct thermometer *meter)` | 从名字向外读，`*read_c` 表示指针，右边括号写它所指函数的参数，最左侧是返回类型 | 定义结构体的一个成员。可填入“接收温度计地址、返回整数”的函数 |
| `.read_c = read_sample` | `.read_c` 指定要初始化的成员。右侧函数名在这里转换成函数指针 | 创建原始操作表时保存地址。此时没有读取任何温度 |
| `meter->ops->read_c(meter)` | `meter->ops` 取表指针，从表取出 `read_c`，最后一对括号发起调用 | 把原来的 `meter` 作为参数送给选中的函数，整数返回给 `printf` |

为什么 `(*read_c)` 外有括号？C 的函数声明里，`int *read_c(...)` 会声明一个返回整数指针的函数。我们要放进结构体的是一个指针成员，必须先让 `*` 与 `read_c` 结合。开头的 `struct thermometer;` 提前声明类型名，让操作表能用它的指针做参数，后面再给出温度计的字段。参数里的 `const` 约束了函数通过这个指针能做的修改。

在纸上把一次 `show_reading("A calibrated", &a)` 展开，箭头分上下两路。函数指针本身只保存函数地址，C 不会替你记住这是 A 或 B，这就是为什么调用处还要显式传 `meter`。

~~~text
选函数    meter → a.ops → calibrated_ops.read_c → read_calibrated
传数据    meter → a     → sample_c = 20，correction_c = 2
合在一起  read_calibrated(&a) → 22 → printf
~~~

`raw_ops` 和 `calibrated_ops` 是两张只读表，在整个程序运行期间都有效。`a.ops = &calibrated_ops` 改动了 A 里面保存的地址。B 仍然使用原来的表。`alias = &a` 则给同一份 A 的数据增加了另一个访问入口。读驱动时也可以问，两个打开者共享的究竟是回调代码、设备对象，还是某一次打开的状态？

**读完停一下。** 遮住 `main`，试着只改一条初始化语句，让 B 第一次经表读取就输出 28，A 的全部结果照旧。能指出要改 `b.ops` 以及为什么只影响 B，就可以进入第 3 节。

## 3. 亲手制造一次最常见的编译错误

假设把 `.read_c = read_sample` 写成 `.read_c = read_sample()`。两个括号很小，语义发生在哪里？下面的命令把这个改动写入临时副本，再让编译器检查它。

~~~bash
mkdir -p output/textbook-check
sed 's/\.read_c = read_sample,/\.read_c = read_sample(),/' \
  learning-site/examples/function_pointers.c > output/textbook-check/bad_callback.c
LC_ALL=C cc -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  output/textbook-check/bad_callback.c
~~~

**实测定位。** GCC 在 `.read_c = read_sample(),` 这一行报告 `too few arguments to function 'read_sample'`，随后指出 `read_sample` 的声明位置。先读第一条错误，再去核对声明。编译器把 `()` 解释成“现在就调用”，于是查这个调用有没有传入温度计指针。即使补足参数，得到的读数也是 `int`，表项要求的却是一个函数地址。修正方式是登记函数名，把调用和参数留给 `show_reading`。可以对原文件再做下方语法检查，成功时没有输出。

~~~bash
cc -std=c11 -Wall -Wextra -Werror -fsyntax-only learning-site/examples/function_pointers.c
~~~

以后读到 `.open = note_open`，就可以把它认作登记回调的地方。要找真正打开设备的时刻，去搜“取出成员再加括号”的表达式。下一步要找到那个表达式的第一个对象 `file` 从哪来。

## 4. 让 Linux 显示「两个编号」和「两份状态」的区别

应用每次成功 `open` 得到一个小整数，叫文件描述符（fd）。进程用这个整数索引自己的描述符表。内核中的 `struct file` 代表一次打开形成的文件描述（open file description），保存当前操作表等状态。`inode` 描述文件系统里的对象。对字符设备节点，它还记录文件类型和设备号。下面分两次观察，第一次看身份，第二次看状态是否共享。

**先看两个 fd 对应的设备号。** 保持两次打开同时存在，依次向 `/dev/null` 请求一个字节。用 `st_rdev` 取字符设备号，`st_dev` 表示承载节点的文件系统所在设备，含义不同。

~~~bash
(
set -eu
exec 3< /dev/null
exec 4< /dev/null
for fd in 3 4; do
    stat -Lc "fd=$fd dev=%t:%T" "/proc/self/fd/$fd"
    printf 'read bytes: '
    dd bs=1 count=1 status=none <&"$fd" | wc -c
done
)
~~~

本次得到 fd 3 和 fd 4，每次 major:minor 均为十六进制的 1:3，实际读回 0 字节。这里的 fd 由重定向指定，应用用 open 取得的 fd 由进程描述符表分配。零字节表示这次读到 EOF。`/dev/null` 总是读到 EOF，只看返回值很难识别两次打开背后有什么状态，所以换一种能显露读取位置的对象。

**再用已知字节串区分第二次 open 和 dup。** 下面临时创建内容为 `frame` 的普通文件。A、B 各自打开一次，再复制 A 的 fd。每次让 dd 只读两个字节，避免为观察两字节却推进更长的偏移。先猜第二次会读到 `fr` 还是 `am`。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
printf 'frame' > "$lab/sample"
exec 3< "$lab/sample"
exec 4<&3
exec 5< "$lab/sample"
printf 'A: '; dd bs=1 count=2 status=none <&3; printf '\n'
printf 'dup(A): '; dd bs=1 count=2 status=none <&4; printf '\n'
printf 'B: '; dd bs=1 count=2 status=none <&5; printf '\n'
printf 'A: '; dd bs=1 count=2 status=none <&3; printf '\n'
)
~~~

| 本次 WSL 的实际顺序 | 返回值 | 这一读结束后的位置 |
| --- | --- | --- |
| A 读 2 | `b'fr'` | A 与它的副本共用的位置从 0 到 2 |
| dup(A) 读 2 | `b'am'` | 同一位置从 2 到 4 |
| B 读 2 | `b'fr'` | B 自己的位置从 0 到 2 |
| A 再读 2 | `b'e'` | A 从位置 4 读到最后一个字节 |

~~~text
进程 fd 表                     内核打开对象              文件系统
A 的 fd       ─┐
               ├────────────→ struct file A ───┐
dup(A) 的 fd  ─┘                               ├──→ 同一个 inode
B 的 fd       ──────────────→ struct file B ───┘
~~~

把一个 fd 整数赋给另一个变量，只复制了用户态的数字。`dup` 会申请新的 fd 槽位并增加对同一打开对象的引用。独立 `open` 才建立新的打开对象。因此先关闭 A 后，它的副本还能接着读。关掉所有引用后，原来的 fd 整数将来可以分配给完全不同的文件。用 fd 判断“是不是同一台相机”时，这正是容易漏掉的一层。[Linux open(2) 手册](https://man7.org/linux/man-pages/man2/open.2.html) · [Linux dup(2) 手册](https://man7.org/linux/man-pages/man2/dup.2.html)

## 5. 沿本地 SDK 跟一次 open，找出是谁调用 note_open

假设已经在匹配的实验内核上注册了 `rvnote` 杂项字符设备，应用有访问权限，并以 `O_RDWR` 打开它。内核怎样找到便笺驱动？以下跟读本地厂商 Linux 6.1 源码，版本为内核子仓库提交 `a04e4b3c9`。第 4 节实跑的是 WSL 的设备和普通文件。这里的图可以用来对照 SDK，板端函数调用轨迹仍待单独采集。

~~~text
注册时
  misc 核心为共享主设备号注册 misc_fops
  便笺模块注册 note_dev（名字 rvnote，动态次设备号，fops 指向 note_ops）

进程普通 open("/dev/rvnote", O_RDWR) 时
  用户态 → 系统调用入口 → VFS 路径查找 → 字符设备节点的 inode
                                              │ i_rdev 保存主、次设备号
  本次打开的 struct file ← 取 inode 的初始操作表 def_chr_fops
      │ 调用表里的 open
      ▼
  chrdev_open  → 找 cdev → 把本次 file 的 f_op 换成 misc_fops
      │ 调用新表里的 open
      ▼
  misc_open    → 按次设备号找 note_dev → 把 f_op 换成 note_ops
      │ 调用新表里的 open
      ▼
  note_open    → 分配 struct note_file → 放进 file->private_data
      │ 成功返回 0，逐层返回，内核把 file 安装进 fd 表
      ▼
  用户态拿到 fd → read(fd, ...) → VFS → note_read → 使用该份便笺
~~~

### 第一次读源码只找四个赋值和调用点

在工作区根目录运行。每条命令的作用分别是找初始表、找 VFS 的调用者、找字符设备分派、找 misc 的分派。用变量记录内核目录，后面几节在同一终端继续使用它。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'i_fop = &def_chr_fops' "$k/fs/inode.c"
rg -n 'fops_get\(inode->i_fop\)|open = f->f_op->open|error = open\(inode, f\)|fd_install\(fd, f\)' "$k/fs/open.c"
rg -n 'kobj_lookup\(cdev_map|fops_get\(p->ops\)|replace_fops|filp->f_op->open|\.open\s*=\s*chrdev_open' "$k/fs/char_dev.c"
rg -n 'iminor\(inode\)|fops_get\(iter->fops\)|file->private_data = c|replace_fops|err = file->f_op->open|register_chrdev\(MISC_MAJOR' "$k/drivers/char/misc.c"
~~~

1. **先找 VFS 手上的第一张表。** 文件系统初始化字符设备的特殊 inode 时，`init_special_inode` 把 `i_fop` 指向 `def_chr_fops`。VFS 是所有文件系统共用的接口层，在 `do_dentry_open` 中把节点的初始表放进本次打开对象的 `f_op`。普通路径上它取 `f->f_op->open`，调用 `open(inode, f)`。在 `def_chr_fops` 的定义里能读到 `.open = chrdev_open`。至此才找到了第一个真实函数名。如果想单独跟 ARM64 的系统调用入口，可接着跟读系统调用路径。[fd、系统调用与 VFS](../02-应用与字符驱动/first-lesson.md)
2. **设备号选中字符设备实现。** 在 `chrdev_open` 里，先看 `inode->i_cdev` 是否已有缓存。首次查找时用 `inode->i_rdev` 到 `cdev_map` 中查对应范围，拿到 `struct cdev *p`。顺着下面的 SDK 节选往下读。`fops_get(p->ops)` 获取可使用的表并按其 owner 处理模块引用，`replace_fops` 把表装到这次的 `filp` 上，随后通过新表的 `open` 回调继续。其他已经打开的 `struct file` 各有自己的 `f_op` 字段。

~~~c
fops = fops_get(p->ops);
if (!fops)
	goto out_cdev_put;

replace_fops(filp, fops);
if (filp->f_op->open) {
	ret = filp->f_op->open(inode, filp);
	if (ret)
		goto out_cdev_put;
}
~~~

<Sdk id="vfs-open" />

走过 VFS 的普通打开准备后，字符 inode 的初始 open 交给字符设备层。

<Sdk id="char-open" />

3. **共享一个主设备号，怎样再选中便笺？** `drivers/char/misc.c` 中的 `register_chrdev(MISC_MAJOR, "misc", &misc_fops)` 登记了共享入口。因此上一步新表的 `open` 在本例中是 `misc_open`。它取 `iminor(inode)` 得到次设备号，遍历已注册的 `misc_list`，匹配 `iter->minor` 后从 `iter->fops` 取得具体设备的表。`rvnote` 登记的正是 `&note_ops`。下面摘自它找到表之后的成功路径，注意 `file` 从头到尾是同一个参数。

~~~c
file->private_data = c;

err = 0;
replace_fops(file, new_fops);
if (file->f_op->open)
	err = file->f_op->open(inode, file);
~~~

<Sdk id="misc-open" />

4. **在表里读出调用目标和返回约定。** 打开 `rvnote.c`，`note_dev.fops` 指向 `note_ops`，其中 `.open = note_open`。所以刚才的 `file->f_op->open(inode, file)` 实际执行 `note_open(inode, file)`。`struct file_operations` 里 `open` 的返回类型是 `int`，驱动成功时返回 0，失败时返回负的错误码。应用得到的 fd 来自上层打开流程，只有成功打开的 `file` 才会安装到预留的 fd 槽位。**驱动回调返回 0** 和 **应用收到一个 fd** 属于两次不同的返回。[便笺字符驱动完整实现](../02-应用与字符驱动/char-driver.md#misc)

<Sdk id="file-ops" />

**怎么知道在哪里停下了？** 用户程序看见 `open` 返回 `-1` 后先记 `errno`。比如路径分量不存在会遇到 `ENOENT`，该次调用还没有到 `note_open`。在 `chrdev_open` 中找不到对应的 cdev 有一条明确的 `-ENXIO` 分支。`misc_open` 按 minor 查找并重试后仍找不到操作表可以返回 `-ENODEV`。`note_open` 分配便笺失败则返回 `-ENOMEM`。错误码可能有多个来源，定位时要结合节点类型、主次设备号、注册情况和具体返回点。这四处是可在源码中核对的例子。

## 6. 跟住同一个 file，看私有状态的整个寿命

先打开便笺驱动的源码 `rvnote.c`，按 `note_dev → note_ops → note_open → note_read → note_release` 的顺序读。对照本地文件可以用下面两条命令。第一条显示回调签名与引用点，第二条给出 VFS 对普通 `read` 和最终释放的调用点。[便笺驱动源码和交叉编译方法](../02-应用与字符驱动/char-driver.md)

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'note_dev|note_ops|note_open|note_read|note_release|private_data|note->cursor' learning-site/examples/char/rvnote.c
rg -n 'ret = file->f_op->read\(|file->f_op->release\(inode, file\)' "$k/fs/read_write.c" "$k/fs/file_table.c"
~~~

这是 `learning-site/examples/char/rvnote.c` 中完整的打开回调。找出函数结束后仍然存在的两样东西，再找出随函数返回而失效的那个局部变量。

~~~c
static int note_open(struct inode *inode, struct file *file)
{
	struct note_file *note = kzalloc(sizeof(*note), GFP_KERNEL);

	if (!note)
		return -ENOMEM;
	mutex_init(&note->lock);
	file->private_data = note;
	return nonseekable_open(inode, file);
}
~~~

`file` 指向 VFS 交进来的打开对象。`note` 本身是局部指针变量，`kzalloc` 分配的便笺却有独立的寿命。赋值 `file->private_data = note` 把地址留给下一次读写。回调返回后，局部变量结束，打开对象和成功分配的便笺仍在。若把一份函数栈上的临时便笺地址留下，后来的 `read` 就无法依赖那块存储。最后的 `nonseekable_open` 将这个打开对象标为不支持定位访问，普通顺序读仍能使用驱动自己的游标。

| 时刻 | 从哪里取得对象 | 对象里发生了什么 |
| --- | --- | --- |
| 注册 | `module_misc_device(note_dev)` 使用 `misc_register` 注册 `note_dev` | `note_dev` 保存设备身份和 `&note_ops`。这时尚无本次打开的便笺 |
| open | `misc_open` 先令 `file->private_data = c`，其中 `c` 指向选中的 `miscdevice` | 本例的 `note_open` 用 `kzalloc` 分配零初始化的 `struct note_file`，初始化锁，再把这个地址写入同一字段 |
| write | `note_write` 从该 `file->private_data` 取回便笺 | 写入 `frame` 后 `text` 保存 5 字节，`len = 5`，`cursor = 0` |
| read | `note_ops.read` 指向 `note_read`，通过同一 `file` 找到便笺 | `simple_read_from_buffer` 收到 `&note->cursor`。从位置 0 读两个字节得到 `fr`，游标变 2，再读才从 `a` 开始 |
| 最后释放 | 对应 `struct file` 的最后一个引用释放时，清理路径调用 `note_release` | `kfree(file->private_data)` 归还本次打开分配的内存。关闭一个经 `dup` 得来的 fd 时还可能有别的引用 |

`private_data` 的类型是 `void *`。框架提供一个能存地址的槽位，里面的对象类型和生命周期要由使用者约定。`note_read` 之所以可以把它当作 `struct note_file *`，依据是本驱动成功打开时写入了这种对象。若误以为槽位始终保存 `miscdevice`，下一次读就会用错误的类型解释内存。在陌生驱动里遇到 `private_data`，先找所有给它赋值的地方，再看取回处和释放处。

把这段代码与 `frame` 的普通文件实验联系起来。普通文件的读取位置由打开的文件描述共享。本例驱动自己在 `note_file` 里维护 `cursor`，`note_read` 显式使用它。两种实现都会使经 `dup` 的两个 fd 接着读，因为它们抵达同一个 `struct file`。反过来，第二次独立打开普通文件仍然能读到原来的文件内容，而独立打开 `rvnote` 将取得一张**内容也独立**的空便笺。要预测新设备的读写行为，必须找到驱动真正保存数据的字段。

**纸上验收，先给出返回值再展开。** 假设在已加载模块的实验系统中，A 和 B 分别打开 `/dev/rvnote`，C 是 `dup(A)`。向 A 写入 `frame`，接着 A 读 2、C 读 8、B 读 8、A 再读 1。每次读到什么？什么时候可以释放 A 的便笺？

<details>
<summary>核对源码推导</summary>

A 得 `fr`，C 接着得 `ame`。B 在它自己的空便笺上读到 0 字节。A 再读也得到 0 字节，这次原因是 A 的游标已到末尾。若只剩 A、C 两个引用，关闭最后一个后该便笺才进入释放流程。这个结论来自 `rvnote.c` 的分配、游标更新和释放路径。此前工作区做过 AArch64 模块交叉编译，这组设备读写留给匹配实验内核的独立验收。

</details>

<details>
<summary>以后在已加载 rvnote 的隔离实验内核上，怎样验证纸上的四个返回值？</summary>

将这段读写关系用于隔离实验系统的验收设计。保留两个独立的 `open`，另用 `dup` 建立第三个描述符。每项检查对应上文的一次预测。失败时先确认上一行实际返回了什么，再回到本驱动查 `len` 和 `cursor` 的变化。此处的返回值是静态推导，设备行为留待实验内核验证。

</details>

### 用返回约定找到所有权变化

同一个名字叫“失败”，C 接口仍可能用不同方式表达。以当前三处调用为例，先看声明和调用者，再判断该读哪个值。

| 接口 | 成功交给调用者 | 失败从哪里观察 |
| --- | --- | --- |
| `imx415_read_reg(..., &value)` | `int` 返回 0，调用者提供的结果对象才有新值 | 返回负错误码，保留原先的 `value` 不能当作这次成功读数 |
| `kzalloc` | 返回已分配对象的指针，需要有配对释放 | 返回 `NULL`，此时未取得对象 |
| VFS 到 `note_open` | 返回 0，便笺绑定到这次打开的 `file` | 本例分配失败返回 `-ENOMEM`，上层不安装一个可用 fd；用户态常由 libc 表示为 `-1` 并设置 `errno` |

内核里还有返回 `ERR_PTR(...)` 的指针接口。遇到它们要按对应约定用 `IS_ERR` 与 `PTR_ERR` 判断并取回错误。单做 `!ptr` 只能识别空指针。任何接口若允许未登记某个可选回调，还需确认调用前谁检查函数地址。前面 `chrdev_open` 中的 `if (filp->f_op->open)` 就是一处框架检查。

纸上考虑把 `note_open` 扩为先分配会话、再创建一个可能失败的子资源、最后把会话交给 `private_data`。当子资源构造失败时，会话仍由打开函数负责释放，因为此时没有交给成功打开对象。等回调返回 0 后，最后一份 `file` 引用消失才能通过 `note_release` 释放成功建立的会话。用这三个状态分别画出清理路径。清理顺序应反过来，先撤掉依赖会话的子资源，再释放会话。

<Sdk id="vfs-final-put" />

## 7. 带着同一套读法翻开 IMX415

在 SDK 里搜下面三个名字。先圈出 `video` 表的类型，再圈出 `s_stream` 成员和它右边的函数名，最后读函数定义的两个参数。这次仅练习识别回调，不需要改设备树或启动取流。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'static int imx415_s_stream|struct v4l2_subdev_video_ops imx415_video_ops|\.s_stream\s*=\s*imx415_s_stream|\.video\s*=\s*&imx415_video_ops' \
  "$k/drivers/media/i2c/imx415.c"
~~~

SDK 的 `imx415_video_ops` 中有 `.s_stream = imx415_s_stream`。外层 `imx415_subdev_ops.video` 指向它。以后当管线代码通过这个子设备的视频操作表发出开关流请求，目标便是 `imx415_s_stream(struct v4l2_subdev *sd, int on)`。`sd` 指明哪个子设备，`on` 表示开或关。这里用的是 V4L2 子设备框架定义的签名，和刚才的 `file_operations.open` 分属两张不同的表。

<Sdk id="sensor-video-ops" />

在驱动里找到 `.s_stream = imx415_s_stream`，足以指出它提供了哪个回调。若要说明“采集程序的哪一个动作、在什么条件下导致传感器开流”，还要找到管线的调用点并核对运行时行为。相机章节会沿 `VIDIOC_STREAMON`、缓冲队列与媒体管线接上这段路径。[从 open 到 VB2 取帧](../05-相机驱动实践/capture.md)

## 8. 合上代码，用自己的话复盘

1. **如果只能搜索 `note_open(`，为什么容易漏掉它的调用者？** 画出从 `note_dev.fops` 到 `note_ops.open` 的静态接线，再写出 `misc_open` 里实际调用这个成员的表达式。
2. **为什么只做一次 open，却遇到三个带 open 的函数？** 按 `chrdev_open → misc_open → note_open` 写出每层消除的一个未知量。能分别指出设备号、次设备号、每次打开的私有状态，就能解释这个例子为何需要三层。
3. **两次 read 都返回零，能说明两个 fd 共享游标吗？** 用第 6 节的 A、B 构造反例，再解释为何第 4 节选了有确定字节串的文件来观察位置。
4. **面试官追问驱动怎样处理多进程时，你准备先查哪里？** 先查状态分配在设备注册还是每次 `open`，再查哪些路径能共享它，以及实际用哪把锁。在 `rvnote` 里指出 `note_file.lock` 所保护的内容和游标，再考虑同一 fd 被多个线程使用的情形。

5. **为什么不能把指向局部数组的指针交给长期运行的异步回调？** 分别画出地址变量与数组实体的寿命，再说明同步传输与延后执行怎样改变可用对象的期限。

最后，请自己画一张图。先画出 A、dup(A)、B 的 fd 和打开对象，给每个对象标上 `f_op` 与 `private_data`，然后从一次 `read(A, …)` 连到具体的便笺。画完能用“哪一张表、哪一个对象、哪一处调用”解释每条箭头，就有了读下一个子系统的起点。追踪一笔 IMX415 寄存器读取时，同样可以从 I2C 控制器的传输表找到执行函数。先从两根导线和一个 ID 字节开始。[进入 I2C 上篇](../04-设备模型与驱动子系统/i2c-wire.md)

下一节沿当前编译命令往下追，核对编译器怎样把这段 C 变成目标架构的 ELF，也解释 WSL 实验的可执行文件为何不能直接拿到开发板运行。[1.6 编译、链接、ELF、符号与交叉工具链](build.md#elf)
