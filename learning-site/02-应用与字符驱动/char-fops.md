# 2.5 字符设备号与 file_operations

打开 /dev/null 得到 fd 3 时，系统里已经有另一个 3：它的次设备号也是 3。两者碰巧相同。下面用实际节点属性、内核对象和操作表解释，从路径到驱动究竟在哪一步用到哪一个编号。

## 先认清四种身份

在 WSL 查看两个已有节点，再给 /dev/null 增加一个临时的符号链接。跟随链接读属性，比较原名和新入口。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
ln -s /dev/null "$lab/other-name"
stat -c '未跟随 类型=%F inode=%i 名字=%n' "$lab/other-name"
stat -Lc '跟随 类型=%F st_dev=%d inode=%i st_rdev(hex)=%t:%T 名字=%n' \
    /dev/null "$lab/other-name" /dev/zero
cat /sys/class/mem/null/dev /sys/class/mem/zero/dev
)
~~~

| 名称 | 表示什么 | 在这里看到什么 |
| --- | --- | --- |
| 路径及 dentry | 如何找到 inode，以及目录中的名字 | 链接自己是一个 inode，跟随后才定位 /dev/null |
| st_dev 与 inode 号 | 节点存放在何处，以及该文件系统中的对象身份 | 原名与跟随后的别名引用同一节点 |
| st_rdev，即字符 inode 的 i_rdev | 节点要求访问的设备号，分为 major 与 minor | null 为 1:3，zero 为 1:5。stat 的 %t/%T 是十六进制，sysfs 的 dev 属性为十进制 |
| fd | 当前进程 fd 表的槽号 | 直到 open 成功才得到。同一个节点可被多次独立打开 |

设备号使用 dev_t 表示。内核通过 MKDEV 组合，通过 MAJOR、MINOR 拆解。主次编号共同参与匹配，注册可覆盖一段连续编号，因此读代码时要查实际范围。节点路径可以变化，权限和可见性也能随挂载视图变化。一旦抵达同一个字符设备号，框架才有依据查对应的 cdev。

## 在源码里标出操作表被换掉的时刻

~~~text
字符特殊 inode 初始化：i_rdev = 设备号，i_fop = def_chr_fops
 → VFS 创建 file，从 inode 取得当前操作表
 → def_chr_fops.open = chrdev_open
 → 用 i_rdev 取得 cdev，或取得已缓存的 i_cdev 引用
 → fops_get(cdev 的表) → replace_fops(file, 表)
 → 如果表提供 open，再调用它 → 成功后将 file 安装到 fd 槽
~~~

### 第一步，把设备号和公共入口存进 inode

`fs/inode.c:2353`

~~~c
if (S_ISCHR(mode)) {
	inode->i_fop = &def_chr_fops;
	inode->i_rdev = rdev;
~~~

判断节点是字符设备后，内核把创建节点时的设备号存为 i_rdev，并放入公共操作表。公共表把 open 指向 chrdev_open。到这里还没拿到具体驱动的回调。

`fs/char_dev.c:452`

~~~c
const struct file_operations def_chr_fops = {
	.open = chrdev_open,
	.llseek = noop_llseek,
};
~~~

### 第二步，按设备号查 cdev

cache 中没有 i_cdev 时，使用 i_rdev 查注册映射。以下几行就是“路径找到了，驱动仍可能打不开”的一个分支。

`fs/char_dev.c:386`

~~~c
kobj = kobj_lookup(cdev_map, inode->i_rdev, &idx);
if (!kobj)
	return -ENXIO;
new = container_of(kobj, struct cdev, kobj);
~~~

kobj_lookup 返回注册对象的引用，container_of 从内嵌的 kobject 得到外层 cdev。查找期间锁曾释放，随后重新持锁并读一次 i_cdev，以防其他打开者已先填入缓存。缓存命中时仍需取得有效引用。

### 第三步，换成本次打开的驱动操作表

`fs/char_dev.c:408`

~~~c
fops = fops_get(p->ops);
if (!fops)
	goto out_cdev_put;

replace_fops(filp, fops);
if (filp->f_op->open) {
	ret = filp->f_op->open(inode, filp);
~~~

先从 cdev 获取有效的操作表，再更新当前的 filp。驱动若提供 open 才调用。变化发生在 struct file，inode 上留着公共的入口供下一次打开使用。read 用的是这次打开最终留下的表。

如果驱动的 open 失败，chrdev_open 归还本次得到的 cdev 引用，再向上返回。上层失败路径也会收回预留 fd。若驱动的 open 在失败前创建了私有对象，应配套处理自己的中间状态。成功路径才把本次打开的私有状态交给后续 read 与 release。

## read 怎样拿到这个对象和用户缓冲

源码摘录 `kernel-6.1/include/linux/fs.h:2168–2173`

~~~c
struct file_operations {
	struct module *owner;
	loff_t (*llseek) (struct file *, loff_t, int);
	ssize_t (*read) (struct file *, char __user *, size_t, loff_t *);
	ssize_t (*write) (struct file *, const char __user *, size_t, loff_t *);
	ssize_t (*read_iter) (struct kiocb *, struct iov_iter *);
~~~

操作表定义回调的参数和返回类型。VFS 从本次 file 上取得它并根据访问方式分派。

源码摘录 `kernel-6.1/fs/read_write.c:450–455`

~~~c
ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
	ssize_t ret;

	if (!(file->f_mode & FMODE_READ))
		return -EBADF;
~~~

read 返回只结束一次读操作。文件引用最终释放时另走 release。

源码摘录 `kernel-6.1/fs/file_table.c:294–299`

~~~c
static void __fput(struct file *file)
{
	struct dentry *dentry = file->f_path.dentry;
	struct vfsmount *mnt = file->f_path.mnt;
	struct inode *inode = file->f_inode;
	fmode_t mode = file->f_mode;
~~~

对照已有的 read 回调签名，按参数逐个解释。

~~~c
ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
~~~

第一项指向这一次打开的 file，驱动可从 private_data 找会话对象。第二项是用户可访问地址，第三项给最大读取字节数。末项给本次操作所用的偏移指针，某些设备会采用不同的定位语义。VFS 检查访问方向与用户地址范围，再按实现选择 read 或 read_iter 等路径。驱动真正输出数据时使用适合用户内存的访问接口。copy_to_user 返回未复制的字节数，读回调需要按实际完成的工作决定返回字节数或错误。普通进程上下文可以处理用户页缺页，硬中断路径不能据此直接向用户指针写数据。

把下列三种东西画在不同框里。只读操作表可以由多个打开对象共享。每颗设备的寄存器、队列是设备状态。每次打开独有的游标与临时数据则可放在会话对象。dup 增加指向同一 file 的引用，因此这两个 fd 还会共享 private_data。close 只关闭一个槽位，最后一个 file 引用释放时才进入最终的 release 路径。模块实现常用 .owner 管理代码引用，设备或会话仍需各自的生命周期规则。

## 本节复盘

1. **把节点改名后为什么还能调到同一个驱动？** 路径解析后找到的 inode 仍带原 i_rdev，之后查 cdev 使用设备号。先检查改名是否跨了挂载视图或改变访问权限。
2. **节点明明存在，open 为什么可能得到 ENXIO？** 路径可能已找到字符 inode，但 cdev 映射缺失，也可能是驱动的 open 拒绝该 minor。结合驱动注册和返回分支取证。
3. **两次 open 同一个节点，read 为什么可以有两份游标？** 按 `inode → cdev → 操作表` 与 `fd → file → 私有状态` 两条链解释。也可以复跑[打开引用实验](first-lesson.md#vfs)。

下一节看同一主设备号之下，驱动怎样将两个次编号交给不同操作表。[2.6 传统 register_chrdev 注册法](register-chrdev.md)
