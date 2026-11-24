# 2.8 miscdevice 与每次打开的私有状态

需求是一台便笺设备，但每次 open 都获得一本空白便笺。设备只有一个，为什么状态不能只存一份？先沿框架的注册和二次分派，找到打开时真正拥有数据的对象。

## 一次登记有哪个名字、编号与入口？

完整驱动在 `learning-site/examples/char/rvnote.c`。跟读以下登记字段。

`examples/char/rvnote.c:74`

~~~c
static struct miscdevice note_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "rvnote",
	.fops = &note_ops,
	.mode = 0600,
};
~~~

misc 把各个小设备组织到共享主设备号下。MISC_DYNAMIC_MINOR 让核心申请可用次设备号。name 用于发布设备，fops 指向真正处理 open、read、write 的回调表。0600 请求节点权限，实际可见性和访问权限仍要看目标。misc_register 会在登记失败时撤销它已经取得的动态编号。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'MISC_DYNAMIC_MINOR|misc->minor =|device_create_with_groups|misc_list' "$k/drivers/char/misc.c"
sed -n '1,8p' /proc/misc
~~~

宿主 /proc/misc 仅展示该内核现有 misc 设备，第一列为次号。它不会展示本地仅编译完成的 rvnote。编号须以当前内核的注册结果为准。

## 打开时为什么会写两次 private_data？

`drivers/char/misc.c:138`

~~~c
file->private_data = c;

err = 0;
replace_fops(file, new_fops);
if (file->f_op->open)
	err = file->f_op->open(inode, file);
~~~

框架根据 minor 选中 miscdevice，把它暂放 private_data，换成具体操作表，再调用该表的 open。若一个驱动省略自己的 open，后续路径仍可按框架约定取这个设备对象。本例另有每次打开独立的数据，所以 note_open 有下面的动作。

`examples/char/rvnote.c:17`

~~~c
struct note_file *note = kzalloc(sizeof(*note), GFP_KERNEL);

if (!note)
	return -ENOMEM;
mutex_init(&note->lock);
file->private_data = note;
return nonseekable_open(inode, file);
~~~

kzalloc 成功后才建立互斥锁，并用 note 指针替换框架放入的设备指针。这次打开的文本、长度和游标随 note 一起存在。第二次独立 open 会分配新 note。用 dup 则只得到一个指向原 file 的新引用，因而看到同一 note。

## 写入、读取与释放分别碰哪份状态？

`examples/char/rvnote.c:34`

~~~c
if (count > sizeof(tmp))
	return -EMSGSIZE;
/* 先复制到临时区，错误时保留上一条完整消息。 */
if (copy_from_user(tmp, src, count))
	return -EFAULT;
~~~

先检查大小，再把数据复制到临时区。只要这一步出错，就不会改动已有消息或游标。复制成功后才用锁更新 text、len 和 cursor，保证共用一个 file 的读者看到一致的消息。

`examples/char/rvnote.c:53`

~~~c
mutex_lock(&note->lock);
n = simple_read_from_buffer(dst, count, &note->cursor, note->text, note->len);
mutex_unlock(&note->lock);
return n;
~~~

锁保护缓冲和游标。simple_read_from_buffer 在读取有进展时推进 cursor。关闭所有引用后才运行 release，kfree 释放的是这一次打开分配的 note，而设备还可接受下一次打开。

## 本节复盘

| 在匹配且已加载模块的实验系统中做什么 | 推导的结果 |
| --- | --- |
| 独立打开 A、B，通过 A 写 frame，然后 A 读两字节 | 得到 fr，A 游标停在 2 |
| 向 A 尝试写 129 字节，随后用 dup(A) 的 C 读 | 写返回 EMSGSIZE，C 读到 ame，说明原有内容和游标保留 |
| 再读 A 和 B | 都得到 0。A 已读完，B 在独立的空会话上 |
| 关 A 后继续使用 C | C 仍持有同一份 file，最后一位持有者关闭后才清理会话 |

试着解释为什么用两个不同 shell 命令分别 echo 和 cat，通常读不到刚写的文字。两次 open 各自产生一份便笺。这里的输出是源码推导，[2.4 已验证外部模块可以交叉编译](kbuild.md)，板端行为仍待单独验证。下一节在这份接口契约上比较 read、write、ioctl、poll 与 mmap。[2.9 设计 read、write、ioctl、poll 和 mmap](io-contract.md)
