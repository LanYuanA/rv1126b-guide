# 3.6 时间、超时与跨层时间戳

<script setup>
import exampleFile from '../examples/frame-intervals.sh?url'
</script>

一次相机采集至少包含设备产生帧、驱动提交完成项、应用真正出队三个时间。先记每个数字是在哪个事件打点、用哪种时钟和单位，再决定能否相减。

## 为什么 HZ 不能用来解释所有定时器？

jiffies 是内核的 tick 计数抽象。工作区基线的 CONFIG_HZ=250，因此以 tick 表示的一个单位约为 4 ms。此处的频率来自构建配置，不保证 CPU 每 4 ms 都实际进入一次定时中断。内核用 msecs_to_jiffies 等接口处理换算，用 time_after 等接口比较可能回绕的计数。普通 timer_list 常给粗粒度超时使用。hrtimer 按更细的时间值登记，可指定绝对或相对时间及允许的延迟范围。纳秒是表达单位，真正执行时还受平台定时硬件、IRQ 和调度影响。

~~~bash
rg '^CONFIG_(HZ|HIGH_RES_TIMERS|NO_HZ_IDLE)=' \
  atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal/.config
~~~

以上只读取候选构建配置。hrtimer 的 tim 依 mode 表示一个时刻或间隔，delta_ns 描述松弛范围。给循环采集安排超时时，应明确全程截止时刻还是每次等待的相对期限。若每次 EINTR 都重新用初始相对时间等待，整段调用可能被拉长。

`kernel/time/hrtimer.c:1351`

~~~c
base = lock_hrtimer_base(timer, &flags);

if (__hrtimer_start_range_ns(timer, tim, delta_ns, mode, base))
	hrtimer_reprogram(timer, true);

unlock_hrtimer_base(timer, &flags);
~~~

内核先锁住定时器所属的时钟基座，再把请求交给内部函数登记。若内部函数报告需要更新下一次到期事件，则重新编程。线程何时获得 CPU 仍取决于后续唤醒和调度。

<Sdk id="hrtimer-range" />

## 三类时钟与三个打点阶段

| 时间来源 | 可用于什么 | 相减前核对什么 |
| --- | --- | --- |
| CLOCK_REALTIME | 对照日期、外部事件 | 校时或人为设置可能跳变。适合展示墙钟，需额外约束才用于算耗时 |
| CLOCK_MONOTONIC / CLOCK_BOOTTIME | 同系统的间隔 | BOOTTIME 包括系统挂起期间，MONOTONIC 不包括。跨设备或跨重启需对齐 |
| 缓冲时间戳、媒体 PTS | 图像采集或播放时间轴 | 缓冲 flags 标出时钟和来源。PTS 另查 timebase、起点及是否重排 |

假设同一对事件的 MONOTONIC 时间是 12.000 s、12.040 s，持续 40 ms。模拟墙钟在第二次打点前回拨 1 s，显示差变成 −960 ms。这个例子用于说明时钟域与跳变，未调整 WSL 或板端时间。

## 复算原厂短采集日志

从仓库根目录读首条原始记录，再调用独立脚本统计同一采集会话。脚本只接受同域 EOF 记录及递增的序号和时间戳，遇到序号回绕、多会话或不同 flags 时应先分段或换用相应解析器。<a :href="exampleFile" download="frame-intervals.sh">下载完整统计脚本</a>。

~~~bash
rg -m1 '^cap dqbuf:' output/camera-check/capture.log
bash learning-site/examples/frame-intervals.sh output/camera-check/capture.log
~~~

实测首帧 ts 为 3121.485684 s，带 ts-monotonic 与 ts-src-eof。脚本读取 31 帧，序号缺口为 0，观测速率为 30.000 fps，间隔 P95 为 33.377 ms。相邻间隔只有 30 个，以 30 除首尾时间差。P95 将间隔排序后取向上取整的秩，此处为第 29 个。短记录只描述该窗口，无法推出长期尾延迟。

若没有历史文件，可用同域三帧样本复算。

~~~bash
printf '%s\n' \
  'cap dqbuf: 0 seq: 0 ts: 12.000 (ts-monotonic, ts-src-eof)' \
  'cap dqbuf: 1 seq: 1 ts: 12.040 (ts-monotonic, ts-src-eof)' \
  'cap dqbuf: 0 seq: 2 ts: 12.080 (ts-monotonic, ts-src-eof)' |
  bash learning-site/examples/frame-intervals.sh /dev/stdin
~~~

预期 3 帧、缺口 0、25.000 fps、P95 40.000 ms。将第三行时间改为 12.030，脚本应拒绝这份数据。这样避免把拼接错的日志算成负间隔或伪速度。

## 应用出队日志中的 ts 到底从哪来？

首条日志虽然写 cap dqbuf，其中的 ts 是驱动交给应用的缓冲时间戳。V35 填入缓冲后还会读一次驱动时间用于统计。看下面的赋值顺序，再给每个字段标上所属阶段。

`drivers/media/platform/rockchip/isp/capture_v35.c:1135`

~~~c
buf->vb.sequence = seq;
vb2_buf->timestamp = ns;
ns = rkisp_time_get_ns(dev);
stream->dbg.interval = ns - stream->dbg.timestamp;
stream->dbg.delay = ns - vb2_buf->timestamp;
~~~

前两句把帧序号和已有的帧时间交给 VB2。第三句重新采样时间。这里的 debug interval 用连续两次驱动打点相减，delay 用本次驱动打点与缓冲时间相减。应用实际从 DQBUF 返回需要在调用方另外打点。

<Sdk id="v35-buffer-time" />

## 本节复盘

1. 采集和显示都每 33 ms 打印一次，能否据此推出首帧延迟？两条流可保持相同节奏且相隔多个帧。
2. 测“请求开始到首次取得帧”，用同一应用单调时钟分别记录启动请求前和第一次 DQBUF 成功后。明确是否计入打开、排队与预热。历史日志只有缓冲时间，不能算出这个首帧指标。
3. 如果用 hrtimer 配置 1 ms 超时，回调延迟与等待者切入延迟如何分开？按定时器到期或回调、唤醒、切入和应用返回依次画点。

下一节从应用观察转到内存地址和页表。[3.7 虚拟内存、页表与缺页](virtual-memory.md)
