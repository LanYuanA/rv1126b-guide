# 3.11 页缓存、脏页与写回

<script setup>
import exampleFile from '../examples/writeback_demo.c?url'
</script>

录像程序收到 write 成功，断电后是否还能找到完整分段？先分开应用缓冲、内核写回、目录名字和容器收尾，再给每个阶段安排证据。

## 测量三次操作

在 WSL 仓库根目录运行。程序在当前挂载创建自己的临时目录，用同一个单调时钟分开计时。成功后核对最终名字和文件长度，再清理。<a :href="exampleFile" download="writeback_demo.c">下载完整 C 实验</a>。

~~~bash
findmnt -no TARGET,SOURCE,FSTYPE -T .
mkdir -p output
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/writeback_demo.c \
  -o output/writeback-demo
./output/writeback-demo
~~~

本轮在 WSL ext4 上写入 4,194,304 字节。一次运行的 write 为 3.121 ms，文件 fsync 为 9.447 ms，目录 fsync 为 1.675 ms。close 和 rename 在两次同步之间执行，未计入这三项耗时。程序对短写继续推进，只在确认最终名字和长度以后报告成功。其他运行的耗时会随脏页、水位、日志事务和虚拟磁盘负载而变化。若出现错误，先记录出错的调用、挂载类型和 errno。当前只验收临时文件的操作与长度。

## 一段字节先在哪些地方停留？

| 阶段 | 状态变化 | 可观察到什么 |
| --- | --- | --- |
| fwrite 与 fflush | 用户态 stdio 可能先积累字节，fflush 要求把积累内容交下去 | 查调用返回值，核对实际进入 write 的时间 |
| 普通 buffered write | 文件数据进入页缓存，多数情况下页随后处于 dirty 状态 | 返回的字节数用于推进进度，另有同步写和直接 I/O 路径 |
| 后台写回 | 选择脏页，提交文件系统数据 I/O 并跟踪完成 | Dirty、Writeback、写回与块层事件 |
| 文件同步与发布 | 处理文件数据与相关元数据，改名及目录同步负责名字的发布 | 核对各调用返回值，必要时做恢复验证 |

上一节看的是路径名和打开文件的寿命。本节沿打开文件的 address_space 看页缓存。不同打开对象可以有各自的偏移，同时通过 inode 访问同一个数据缓存。页被修改后，要记下它与存储内容有差异。写正在进行时有 writeback 状态，写回期间再次修改仍可能需要新一轮写回。

~~~text
应用缓冲 → write → ext4 写入路径 → 页缓存被修改
  → 后台或显式同步发起写回 → 文件系统映射块 → 块设备 I/O
  → 文件状态和可能的错误由同步路径检查
  → rename 发布名字 → 目录 fsync 同步名字相关改动
~~~

## 普通 ext4 写入怎样进入页缓存？

本地 SDK 的 ext4_buffered_write_iter 可进入 generic_perform_write。在通用循环里，文件系统回调先按 mapping 和偏移准备目标页。通用层负责拷贝本轮用户数据，再把实际拷贝量交给回调。

`mm/filemap.c:3854`

~~~c
copied = copy_page_from_iter_atomic(page, offset, bytes, i);
flush_dcache_page(page);

status = a_ops->write_end(file, mapping, pos, bytes, copied,
						page, fsdata);
~~~

这里的 offset 在该页内。write_end 根据实际拷贝量收尾，文件系统可更新脏状态等记账。必要时循环撤销未接受的迭代器进度。这里的 dcache 操作涉及 CPU 缓存维护，完成后仍要由文件系统写回到存储。

<Sdk id="ext4-buffered-write" />

`mm/filemap.c:3877`

~~~c
pos += status;
written += status;

balance_dirty_pages_ratelimited(mapping);
~~~

内核只推进已接受的字节。末句按条件进入脏页平衡算法。背景写回跟不上时，生产脏页的进程也可能被节流，所以一次普通 write 一样会变慢。看到耗时变长，先区分复制、脏页节流、文件系统工作和实际 I/O 等待，再找时间关联。

## fsync 从哪里得知数据和错误？

`fs/sync.c:184`

~~~c
if (!file->f_op->fsync)
	return -EINVAL;
if (!datasync && (inode->i_state & I_DIRTY_TIME))
	mark_inode_dirty_sync(inode);
return file->f_op->fsync(file, start, end, datasync);
~~~

VFS 根据打开对象分派。fdatasync 聚焦数据及取回数据必须的元数据。文件长度仍可能在范围内。fsync 还覆盖该文件的其他相关元数据。看 ext4 时，先找下面的文件范围写回与等待，再跟相关日志事务。

`fs/ext4/fsync.c:151`

~~~c
ret = file_write_and_wait_range(file, start, end);
if (ret)
	goto out;
~~~

后续按配置和分支处理事务，必要时发设备 flush。返回前还检查当前打开对象是否有待报告的写回错误。

`fs/ext4/fsync.c:182`

~~~c
err = file_check_and_advance_wb_err(file);
if (ret == 0)
	ret = err;
~~~

先前 write 成功之后仍可能在同步报告写回失败。实验将同步失败视为失败，并保留是哪一次调用返回错误。介质需要正确实现其缓存与 flush 语义，恢复效果还需在目标环境验证。

<Sdk id="ext4-file-sync" />

## 录像分段怎么收尾和验收？

同一文件系统内可以先写临时名称。最终发布前，让 muxer 正常完成尾部索引或分片，排空应用缓冲，安排文件同步并检查关闭结果。之后 rename 为最终名称，同步父目录。本实验的两个名字在同一目录。跨目录发布涉及两个父目录的持久化边界。若框架封装 fd，按它公开的收尾与同步接口安排步骤。

| 要验收什么 | 查哪个可观察结果 |
| --- | --- |
| 能列出最终名字 | 改名前后分别查目录，核对文件身份、长度和返回码 |
| 能播放到末尾 | 用真实分段解封装和解码，核对尾帧、时间轴与错误 |
| 故障恢复后分段可用 | 按授权的恢复窗口核对介质、重新挂载和文件内容 |

字节实验未生成媒体容器，未执行掉电或恢复操作。真实录像后续应按容器格式区分头部可读、索引完结与最后一帧真正可解码。

## 本节复盘

1. 普通 write 返回正数后，为什么文件同步仍可返回错误？分别指出页缓存与写回错误的证据。
2. fsync 文件成功以后，为什么还同步目录？说明文件对象与目录项各是谁的元数据。
3. 文件有长度却不能解码到尾部，先查 muxer 的哪些收尾行为？再决定怎样验证介质。
4. write 很慢、紧随其后的 fsync 很快，能否单凭两条耗时判断最慢的是块设备？列出两个还需核对的阶段。

下一节沿写回提交到块设备的路径，看看平均吞吐如何掩盖排队峰值。[3.12 块层、存储请求与尾延迟](block-io.md)
