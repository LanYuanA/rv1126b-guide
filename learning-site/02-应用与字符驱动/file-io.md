# 2.1 应用文件 I/O 与 errno

<script setup>
import exampleFile from '../examples/file_io_demo.c?url'
</script>

读 5 字节只收到 2 字节，为什么应用有时应继续读，有时应等待，有时应该结束？先用普通文件和 pipe 对照返回值，再沿 Linux 6.1 的读路径确定错误出现的位置。做完这一步，应能从应用的报错中找出失败的是 open、read 还是 ioctl。

## 先决定如何打开

`open(path, flags, ...)` 成功时返回非负 fd，0 也是有效值。失败返回 −1。路径相对于进程当前目录，`openat` 还可以指定目录 fd。下面三类标志影响不同环节。

| 类别 | 示例 | 后续行为 |
| --- | --- | --- |
| 访问方式 | O_RDONLY、O_WRONLY、O_RDWR | 控制该次打开能否读写。它们是互斥模式，O_RDONLY 通常编码为 0，查看时先与 O_ACCMODE 做掩码 |
| 打开条件 | O_CREAT、O_EXCL、O_TRUNC | 影响创建或打开时的动作。指定 O_CREAT 时还要传创建模式，最终权限受 umask 等约束 |
| 描述符及状态 | O_CLOEXEC、O_NONBLOCK | 前者给 fd 设置执行新程序时关闭的标志。后者是打开文件的状态，支持非阻塞的对象可在等待条件未满足时返回 EAGAIN |

`O_CLOEXEC` 在打开时原子地设置描述符标志，可避免多线程的 open 与另一个线程的 fork/exec 之间发生继承竞态。同一打开文件的别名可共享 `O_NONBLOCK` 等状态。访问模式、描述符标志和打开文件状态要分别解释，后面会沿 fdtable 和 struct file 看它们的存放位置。

## 实跑三种读和一次短写

在 WSL 用 Bash 执行。只创建并清理一个临时目录。每次 read 请求两字节，先预测普通文件最后两个返回值。再预测非阻塞 pipe 在写端仍开和写端已关时分别返回什么。pipe 大写入请求比容量多一字节，观察正的短写。

<a :href="exampleFile" download="file_io_demo.c">完整 C 实验</a>，仓库路径为 `learning-site/examples/file_io_demo.c`。

~~~bash
(
set -eu
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
printf abc > "$lab/sample"
cc -std=c11 -Wall -Wextra -Werror learning-site/examples/file_io_demo.c -o "$lab/io"
"$lab/io" "$lab/sample" "$lab/missing"
)
~~~

| 观察 | 返回值 | 下一步 |
| --- | --- | --- |
| 普通文件前三次读 | 2 字节 ab、1 字节 c、0 字节 | 保存正数返回的全部内容。若协议要求 5 字节，这轮最终是提前到达 EOF |
| 不存在的路径 | open 返回 −1，ENOENT | 先查相对路径起点及目标。此调用没有产生有效 fd |
| 空 pipe 且仍有写端 | read 返回 −1，EAGAIN | 当前还可能有生产者。等待可读或写端关闭，再按真实结果处理 |
| 写空 pipe，请求超容量 | 写入正数且小于请求 | 普通字节流继续写时应移动输入指针并扣除实际字节数 |
| pipe 缓冲已经读尽，写端全关 | read 返回 0 | 流已到 EOF |

本次 WSL 查询到 pipe 容量为 65,536 字节，请求写 65,537 字节，实际写入 65,536 字节。容量随环境变化。write 的“按剩余部分继续”适用于允许分拆的字节流。若驱动约定一次 write 是完整消息，重复 write 剩余字节可能变成另一条消息。先读接口语义再写循环。pipe 小于等于 PIPE_BUF 的原子写条件，也不能用本次超容量实验反推。

### 只读关键三行

`file_io_demo.c` 的 `show_read` 每次向 read 提交两字节缓冲。返回 −1 且 errno 是 EINTR 时重新调用，这一轮没有报告已读取字节。

~~~c
do {
    n = read(fd, buf, sizeof(buf));
} while (n == -1 && errno == EINTR);
~~~

一旦拿到正数，`n` 就是这轮的进展，哪怕小于两字节。零和 −1 各由调用方按上表处理。测试的临时目录准备、pipe 分配和退出清理由独立文件统一保存。

## 失败为什么要记下操作名

用户态 C 库通常把内核的负错误码变成 −1，并设置线程的 errno。成功调用之后只处理返回值，旧 errno 可能仍保留。失败后若还要清理或输出，先存 errno，避免后续函数覆盖它。

- **正数**是此次已经取得的进展。下一次操作要在正确偏移继续，别覆盖前面已经收下的数据。
- **零**在请求长度大于零、且接口定义为字节流读取时通常表示 EOF。零长度 read 不提供取流状态。
- **EINTR** 在没有报告已完成字节时可按业务规则重试。本例对读做了处理，实验没有主动注入信号。停止请求或超时策略仍由应用检查。
- **EAGAIN** 适用于稍后再试的状态。用 poll 等待，醒来再检查结果。多个消费者可能在通知和读取之间取走数据，所以醒来后仍可能返回 EAGAIN。
- **其他错误**要保留调用名、fd 或路径、请求参数、返回值与 errno。只清理本次成功取得的资源。Linux 上 close 的资源释放和事后错误报告是两回事，别在另一线程可能复用编号时用旧 fd 盲目再 close。

沿 `ksys_read` 找到 `fdget_pos`。查不到有效 fd 时可直接返回 −EBADF；找到打开文件后才进入 `vfs_read` 检查访问方式和用户缓冲，分派到操作表中的 read 或 read_iter。应用日志里的 EBADF 需要结合当次参数判断发生在获取对象还是访问方式检查。下面两个入口可逐步核对。

<Sdk id="read-fd-lookup" />

查到 file 后才有对象可读。下一段在 VFS 检查访问方向，再决定调用哪个读入口。

<Sdk id="vfs-read-dispatch" />

## 本节复盘

1. **read 比请求少，是否一定到了文件末尾？** 先按实际进展推进，下一次调用才可能报告 EOF。也可能是 pipe 当时只有这些数据。
2. **为什么同样没数据，正忙等 EAGAIN 的程序会拖慢其他任务？** 此时条件尚未成立，循环反复进内核消耗 CPU。使用就绪通知，并准备再次遇到 EAGAIN。
3. **相机提示“打开失败”应先问什么？** 要它区分 open 的 ENOENT、查询能力的 ENOTTY、非阻塞出队的 EAGAIN。三者分别指向路径、命令支持和队列时序。可继续阅读[视频缓冲的完成条件](../05-相机驱动实践/capture.md)。

知道应用看到的返回值后，下一节追踪请求怎样从用户指令到达内核处理函数。[2.2 ARM64 同步异常与系统调用](arm64-syscall.md)
