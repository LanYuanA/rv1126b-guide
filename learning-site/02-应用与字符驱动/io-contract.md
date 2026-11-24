# 2.9 设计 read、write、ioctl、poll 和 mmap

<script setup>
import exampleFile from '../examples/io_contract_demo.c?url'
</script>

接口设计先回答应用要做什么：传字节、查状态、等数据，还是访问映射缓冲。接着为每个调用写清成功值、何时暂时不可用、失败后状态是否改变。

## read/write 的契约由驱动定义

便笺的一次成功 write 会替换整条消息，并把游标设为 0。空写返回 0 并保留原内容，超过 128 字节返回 EMSGSIZE，复制失败返回 EFAULT。read 到当前消息末尾返回 0。若要改成等待下一条消息，必须重新定义 EOF、非阻塞和唤醒条件，否则旧程序可能一直等或提前退出。

从 `examples/char/rvnote.c:39` 取提交消息的临界区。

~~~c
mutex_lock(&note->lock);
memcpy(note->text, tmp, count);
note->len = count;
note->cursor = 0;
mutex_unlock(&note->lock);
~~~

tmp 已经完成用户数据复制。锁让读者看到内容、长度和游标的一致组合。对普通字节流，短写可以按剩余长度继续。对便笺，第二次 write 会再次替换消息，所以应用须按整条消息重试策略处理。

## ioctl 把命令和数据布局写进 ABI

视频应用用 QUERYCAP 查能力，用 G_FMT 读实际格式。fd 决定对象，命令决定参数含义。_IO、_IOR、_IOW、_IOWR 编码命令是否携带数据及方向，方向以应用为参照。定义结构时要规定字段宽度、对齐、保留位及兼容方式，避免把内核指针或不定宽度当作长期协议。驱动先核对命令、长度和参数，输出结构应初始化。

复用 [QUERYCAP 示例](../01-开发环境/build.md#elf) 对 /dev/null 验证 ENOTTY。节点能打开，失败发生在下一笔 ioctl。先记下调用名，才能将路径失败与命令不受支持分开。

## poll 报可读，数据留给谁？

下面是管道将调用者登记到对应等待队列的位置。

源码摘录 `kernel-6.1/fs/pipe.c:669–672`

~~~c
if (filp->f_mode & FMODE_READ)
	poll_wait(filp, &pipe->rd_wait, wait);
if (filp->f_mode & FMODE_WRITE)
	poll_wait(filp, &pipe->wr_wait, wait);
~~~

filp 是这次打开，rd_wait 让写者可以通知读者。登记等待与检查就绪是两个动作，真正的可读位来自下面的状态判断。

源码摘录 `kernel-6.1/fs/pipe.c:683–688`

~~~c
if (filp->f_mode & FMODE_READ) {
	if (!pipe_empty(head, tail))
		mask |= EPOLLIN | EPOLLRDNORM;
	if (!pipe->writers && filp->f_version != pipe->w_counter)
		mask |= EPOLLHUP;
}
~~~

缓冲非空时可报告 POLLIN。poll 回来后，另一消费者仍可以提前取走数据。非阻塞 read 需处理新的 EAGAIN，也要区分“无写端且已读尽”的 EOF。非阻塞视频 DQBUF 同样要检查实际返回值。

## mmap 建立映射，槽位所有权还要看队列

视频应用先用 QUERYBUF 取得接口返回的长度与映射偏移，再调用 mmap。此时进程有一段可用的虚拟地址。QBUF 将槽位交给驱动，成功 DQBUF 才交还应用。映射继续有效并不能保证应用当前有权读取槽中像素。解除映射和队列释放也有各自的时点。

在 WSL 用同一管道依次模拟两个读者，再用 memfd 观察映射保有的引用。<a :href="exampleFile" download="io_contract_demo.c">下载完整实验</a>。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
cc -std=c11 -Wall -Wextra -Werror learning-site/examples/io_contract_demo.c -o "$lab/io-contract"
"$lab/io-contract"
)
~~~

预期先报告可读，另一读者取走 X 后原读者得到 EAGAIN。最后一个写端关闭后读返回 0。内存文件的映射在关闭原 fd 后仍可读取 M，最后由 munmap 清理。这个结果验证普通内存文件的引用边界。视频队列还需按其接口约定验证。

## 本节复盘

1. 同一个 fd 先 poll 再 read，能否断定这次必定取到数据？用 X 被另一读者提前消费的过程回答。
2. 请求 200 字节写便笺，驱动报 EMSGSIZE，为什么应先查消息边界再决定重试？
3. mmap 后何时能读取视频槽？分别在图上标出“有映射”和“应用取得槽位”。[视频队列](../05-相机驱动实践/capture.md)

下一节检查初始化失败和设备退出时如何回退。[2.10 多实例、错误回退与卸载](driver-lifetime.md)
