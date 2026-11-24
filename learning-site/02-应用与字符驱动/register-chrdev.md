# 2.6 传统 register_chrdev 注册法

/dev/null 和 /dev/zero 共用主设备号，读三字节时一个直接结束，一个得到三个零字节。沿本版 `register_chrdev → __register_chrdev → cdev_add` 跟读，再找 mem 驱动为什么还要按 minor 做第二次分派。

## 用相同请求大小验证读行为

在 WSL 执行。命令只访问已有的字符设备，并将每次读取限制在三字节。

~~~bash
(
set -eu -o pipefail
printf 'null 字节数: '
head -c 3 /dev/null | wc -c
printf 'zero 字节数: '
head -c 3 /dev/zero | wc -c
printf 'zero 字节值:'
head -c 3 /dev/zero | od -An -tx1
awk '/^Character devices:/{ in_char=1; next }
     /^Block devices:/{ in_char=0 }
     in_char && $1 == 1 { print "已登记的主设备号:", $0 }' /proc/devices
)
~~~

本次得到 0、3 和 `00 00 00`。/proc/devices 中字符主设备号 1 登记名为 mem。这个文件提供主设备号的注册视图，不能从其中枚举 minor，也不能据此断言每个节点都已存在。

## API 代办了编号、cdev 与失败回退

先看头文件的内联函数。register_chrdev 将调用改写为 __register_chrdev(major, 0, 256, name, fops)。现代内核仍有这个兼容入口。它管理从 minor 0 开始的 256 个编号，适合用来理解“同一段编号使用同一份入口表”的方式。

| 步骤 | 实现里的状态 | 失败如何撤销 |
| --- | --- | --- |
| __register_chrdev_region | 登记实际主编号、起点、数量与名称 | 登记失败立即返回负错误码 |
| cdev_alloc | 建立会被注册表引用的 cdev | 申请失败时移除已登记的编号范围 |
| 填 owner 与 ops 后 cdev_add | 将编号区间映射到已准备的回调表 | 发布失败时释放 cdev 的 kobject 引用，再撤回编号登记 |
| 保存 cd->cdev 并返回 | 可按同一范围找到关联的 cdev | 正常退出走 unregister_chrdev，内部取回登记、删除映射并释放登记项 |

按下面两段区分资源取得和发布。

`fs/char_dev.c:276`

~~~c
cd = __register_chrdev_region(major, baseminor, count, name);
if (IS_ERR(cd))
	return PTR_ERR(cd);

cdev = cdev_alloc();
if (!cdev)
	goto out2;
~~~

先保留范围。若连登记都失败，直接传播 PTR_ERR。登记成功但 cdev 分配失败，沿 out2 只撤销已取得的编号范围。

`fs/char_dev.c:284`

~~~c
cdev->owner = fops->owner;
cdev->ops = fops;
kobject_set_name(&cdev->kobj, "%s", name);

err = cdev_add(cdev, MKDEV(cd->major, baseminor), count);
if (err)
	goto out;
~~~

把驱动提供的操作表填入 cdev，cdev_add 才建立从编号到对象的映射。这里用的是 cd 保存的实际主号，动态申请时原参数 major 仍是 0。

`fs/char_dev.c:292`

~~~c
	cd->cdev = cdev;

	return major ? 0 : cd->major;
out:
	kobject_put(&cdev->kobj);
out2:
	kfree(__unregister_chrdev_region(cd->major, baseminor, count));
	return err;
~~~

成功路径保留映射和登记的关联。失败跳转到 out 时先释放 cdev，再落入 out2 归还编号范围。

新手容易写错返回判断。固定 major 成功返回 0。major 传 0 请求动态分配，**成功返回分到的正主设备号**。因此应先以 `ret < 0` 判断失败，再保存实际主设备号给发布节点与注销用。用 `if (ret)` 检查动态申请，会把一次成功错当成失败。mem 驱动传的是固定 MEM_MAJOR，成功值为 0。

## 从 mem 代码看两次分派和节点发布

~~~text
启动：register_chrdev(MEM_MAJOR, "mem", memory_fops)
    → 建 mem 类 → device_create 按 devlist 发布实例
打开：/dev/zero inode.i_rdev = 1:5 → chrdev_open
    → memory_fops.open = memory_open → devlist[5] → zero_fops
读取：file 的 read 走 read_zero，用户缓冲得到值为 0 的字节
~~~

第一层由 cdev 核心按设备号范围找 memory_fops。第二层由 memory_open 取 iminor(inode) 找 devlist 条目。它先做边界检查，再判该项是否有 fops。无效项返回 −ENXIO。合法的项把具体表装入本次 file，若该表还有 open 就继续调用。null 走下标 3，read_null 直接结束读取。zero 走下标 5，其普通成功读会填充请求长度的零。

`drivers/char/mem.c:727`

~~~c
minor = iminor(inode);
if (minor >= ARRAY_SIZE(devlist))
	return -ENXIO;

dev = &devlist[minor];
if (!dev->fops)
	return -ENXIO;
~~~

范围登记只保证先走到 memory_open。上面这段再验证 minor 是否在 devlist 内、该项是否提供具体操作。只有有效项才能执行下面的表切换。

`drivers/char/mem.c:735`

~~~c
filp->f_op = dev->fops;
filp->f_mode |= dev->fmode;

if (dev->fops->open)
	return dev->fops->open(inode, filp);

return 0;
~~~

filp 仍是第一次分派所操作的同一份 file。只换上次编号的表和模式标志。再往后的 read 直接使用这张表。

节点发布单独发生。chr_dev_init 建立 class 和带 dev_t 的设备对象。devtmpfs 或设备管理程序可以据此提供节点，用户看到的名字、权限和挂载视图还要到运行系统核对。手工节点同样只提供名称和编号。节点缺失常先在路径查找遇到 ENOENT，节点存在但驱动未建立匹配则可能在 open 遇到 ENXIO。

## 设计新驱动的回退路径

mem.c 是内建初始化示例。它对若干初始化失败采用打印或继续的处理，阅读时要区分它的实际策略和新写可退出驱动要承担的工作。用以下状态练一次反向撤销。

| 出错时刻 | 已发布资源 | 新驱动如何收尾 |
| --- | --- | --- |
| 设备号登记失败 | 无 | 保留返回值及冲突信息，直接返回 |
| cdev 已登记，创建设备类失败 | 编号与 cdev | 用实际主设备号执行对应注销 |
| 第 N 个实例发布失败 | 已登记区间、class 与前 N−1 个成功实例 | 停止接收新操作，撤销已发布实例，销毁 class，注销编号和 cdev，并按引用规则收尾 |

发布后可能已有进程打开过节点。移除节点或取消映射后，已打开的 file 引用仍可能存在。需要进一步区分撤掉新入口、结束在途操作和释放对象内存。不要让最后一步早于仍可执行的回调。

**本节复盘。** 口述动态主编号如何返回、谁创建 /dev 节点、为何同一主编号的两个节点能有不同 read、如何处理注销时仍有打开者。说到失败时指出具体返回分支。下一节将这套隐式登记拆成显式编号范围、cdev 与设备发布。[2.7 显式 cdev、设备类与设备节点](cdev.md)
