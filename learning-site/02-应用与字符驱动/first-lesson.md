# 2.3 VFS 中的路径、设备号与一次打开

<a id="io"></a>

从字节数与错误码开始，请读[2.1 应用文件 I/O 与 errno](file-io.md)。

<a id="svc"></a>

从异常入口和寄存器传参开始，请读[2.2 ARM64 同步异常与系统调用](arm64-syscall.md)。

## 2.3 同一路径打开两次，究竟共享什么？ {#vfs}

若只观察 fd 的整数值，很难知道哪两个读者会抢同一段数据。下面让 A、B 各打开一次普通文件，C 复制 A 的 fd。先在纸上写下 A、C、B 各读一个字节的预测，再对照已记录的实验结果。

| 操作后 | 读出 | A 与 C 的共同偏移 | B 的偏移 |
| --- | --- | --- | --- |
| A.read(1) | f | 1 | 0 |
| C.read(1) | r | 2 | 0 |
| B.read(1) | f | 2 | 1 |
| 关闭 A，再从 C 读 | a | 3，此时由 C 引用 | 1 |

这份对照采用无用户态缓冲的逐字节读取。进程的 fdtable 中 A 和 C 占两个槽位，指向同一份打开文件描述（内核中的 struct file）；B 有自己那份。三者通过路径引用同一个 inode。fork 后，子进程继承的 fd 也可引用父进程已经打开的 file。关闭一个槽位只丢掉相应引用，最后引用释放时才进入最终的文件释放路径。

### 把路径换成 /dev/null

~~~bash
stat -c '类型=%F 设备号(十六进制)=%t:%T inode=%i' /dev/null
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'path_openat\(|link_path_walk\(' "$k/fs/namei.c"
rg -n 'get_unused_fd_flags|do_filp_open|fd_install' "$k/fs/open.c"
~~~

本机显示字符特殊文件，设备号为 1:3。先从进程的挂载视图和起始目录解析路径。dentry 把名字与对应 inode 联系起来；若跨越挂载点还需要切换到对应挂载。最终字符设备 inode 的 i_rdev 保存主次设备号。打开期间 VFS 创建 file，字符设备核心根据设备号找到 cdev，再替换本次 file 的操作表，最后调用设备提供的 open。这里区分三个对象就够用：名字用于找到 inode，设备号用于定位驱动，fd 用于找到**本次打开**。

<Sdk id="vfs-path-open" />

路径打开的最后阶段已有候选 inode。下面根据字符节点中的设备号进入具体驱动。

<Sdk id="char-open" />

驱动 open 成功以后，上层才发布这次打开的 file。注意后面的 fd 槽位和设备号是两个编号空间。

<Sdk id="open-install-fd" />

在 `do_sys_openat2` 里找到三行：`get_unused_fd_flags` 预留编号，`do_filp_open` 尝试打开，成功才 `fd_install`。失败时看它怎样归还预留的编号。于是 ENOENT 可以发生在查找路径期间，字符设备存在却没有对应 cdev 时还可能在 `chrdev_open` 得到 ENXIO。相同报错文本要结合实际系统调用和内核分支解释。

**复盘。** 同一主次设备号只能说明两次打开访问同一设备入口。驱动可在 open 中分配单次会话数据，也可让多个会话访问共享硬件。普通文件的偏移实验无法推出摄像头允许两个应用并行启动队列。

## 用真实 fd 验证上面的偏移图

在 WSL 的 Bash 执行，`dd` 每次正好读一个字节。fd 3 与 4 来自同一次打开，fd 5 来自第二次打开。实验记录当前 shell 的 fdinfo，读取时仍用继承来的文件引用。先在纸上画出三条箭头，再运行。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
printf frame > "$lab/sample"
exec 3< "$lab/sample"
exec 4<&3
exec 5< "$lab/sample"
fdinfo="/proc/$BASHPID/fdinfo"
printf 'A: '; dd bs=1 count=1 status=none <&3; printf '\n'
printf 'C: '; dd bs=1 count=1 status=none <&4; printf '\n'
printf 'B: '; dd bs=1 count=1 status=none <&5; printf '\n'
rg '^pos:' "$fdinfo/"{3,4,5}
exec 3<&-
printf '关闭 A 后，C: '; dd bs=1 count=1 status=none <&4; printf '\n'
)
~~~

预期读回 f、r、f，前三次读完的位置为 2、2、1，关闭 A 后 C 还读到 a。用 `exec 4< "$lab/sample"` 替换复制那行再复跑，观察 C 的偏移随哪一份 file 变化。两次打开都指向同一个 inode，内容仍相同，所以需要同时看数据与偏移。

## 查路径和执行打开是两个环节

`do_filp_open` 使用 dfd 和 name 建立路径解析状态。绝对路径从进程所见的根开始，相对路径从 cwd 或传入的目录 fd 开始。沿挂载点切换文件系统视图，逐分量查找 dentry 并执行必要的权限检查。最后一个路径分量还有自己的打开语义，例如创建或跟随符号链接。可把 `/dev/null` 画成“进程的根 → /dev 的挂载 → null 的 dentry → inode → 待建立的 file”。

<Sdk id="vfs-walk-origin" />

起点得到后，内核从这个视图逐段前进。遇到挂载或符号链接要继续按相应规则走。

<Sdk id="vfs-walk-components" />

路径查到对象后，下一步才是为这次打开准备 file 和操作表。

<Sdk id="vfs-file-initialize" />

跟 `do_dentry_open` 时标记 file 取得 inode 和初始 f_op 的位置。字符设备的初始操作表会把流程交给 chrdev_open。它用 inode 的设备号查 cdev，再替换本次打开的 file 上的操作表。后续 read 才按这个新表分派。路径权限失败与字符设备驱动 open 返回错误，可以导致相同的“打开失败”表象，需要 errno、节点属性和驱动日志进一步区分。

## 提前拿到的 fd 编号什么时候才生效？

在 do_sys_openat2 读下列两条路径。

~~~text
预留编号 → do_filp_open → 成功 → fd_install，进程 fd 槽指向 file
                       → 失败 → put_unused_fd，归还预留编号并返回负错误码
~~~

预留编号为本次打开留位置。真正发布引用是在 fd_install。dup 则借已有的打开对象，将它安装到另一个槽位。普通 fork 会复制 fd 表中的条目并增加引用，两个表仍可指向同一份 file，所以父子可能互相影响文件偏移。close 清掉调用者那一槽，编号之后可以复用。最后一份 file 引用消失时，才进入最终的释放流程并调用相应 release。

<Sdk id="open-install-fd" />

发布的是 fd 槽位指向 file 的引用。随后其他系统调用可以用这个编号取得它。

<Sdk id="vfs-dup-slot" />

dup 新增了一个槽位引用。关闭其中一个时，只摘掉该槽位。

<Sdk id="vfs-close-slot" />

摘掉编号和释放打开对象是两步。最后一次引用结束时才进入最终清理。

<Sdk id="vfs-final-put" />

**本节复盘。** 如果 fd 3 已关闭而 release 尚未执行，先找 dup、fork、进程间传递和映射等仍可能持有的引用。再问“同一设备节点打开两次就能并发取帧吗？”这只能证明两次打开成功，队列是共享还是每次打开独立，要看设备实现和当前占用。下一节核对这些回调怎样进入内核或模块产物。[2.4 模块、内建驱动与 Kbuild](kbuild.md)
