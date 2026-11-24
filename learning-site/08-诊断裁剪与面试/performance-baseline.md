# 8.1 性能基线、采样与测量误差

<script setup>
import fixtureFile from '../examples/frame-tail-demo.awk?url'
import analysisFile from '../examples/frame-intervals.sh?url'
</script>

一段日志平均 30 fps，用户仍然可能看到突然停顿。要能定位原因，先说明测的是哪种时间、覆盖哪些帧，以及哪些观察会推翻假设。

## 从一句模糊描述写出可证伪的判断

例如“加备录后预览偶尔卡”。先定义在同源、同模式、同目标场景下，预览相邻呈现时间超 66.7 ms 算一次明显停顿，并统计每分钟次数。如果源端 SOF 已有变长间隔，先查采集、帧率和共同资源。若 sensor 准时且主录仍连续，只有预览呈现滞后，就要查预览线程、缓冲帧龄以及显示端。这个方案分别选择可观察的证据，条件不成立就更换假设。

| 指标 | 采在哪儿 | 单位及目的 |
| --- | --- | --- |
| 吞吐 | 某固定端点的连续有效输出 | fps 或字节/s，说明平均处理能力 |
| 首帧 | 从请求/启流到第一次有效出队或显示 | ms，两个端点都要写明 |
| 帧间隔 | 相邻两帧在同一端点的时间差 | ms，反映该端稳定程度 |
| 分阶段耗时 | 同一帧跨两个可关联端点的时间差 | ms 或 µs，常用中位数、P95、P99 和最大 |
| 缺口 | 同一会话内的 sequence 或已定义帧 ID | 帧，结合窗口起止与日志丢事件看 |

## 先核对时间域与样本边界

本项目历史日志标出 `ts-monotonic, ts-src-eof`。这里读的是帧元数据里的时间戳。想测用户应用收到帧的时间，须在 DQBUF 前后额外打点。与 trace 关联时核对各事件的 clock 原点、暂停行为和偏移。V35 代码给 VB2 队列设置 `V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC`。 `TSTAMP_SRC_EOF` 可以是 flags 的零值，应按掩码解释，位置依赖相应驱动采样。用 `sequence/index` 和一致的窗口关联同一帧。

源码摘录 `kernel-6.1/drivers/media/platform/rockchip/isp/capture_v35.c:1737–1742`

~~~c
q->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
q->lock = &stream->apilock;
q->dev = stream->ispdev->hw_dev->dev;
q->allow_cache_hints = 1;
q->bidirectional = 1;
if (stream->ispdev->hw_dev->is_dma_contig)
~~~

若有 n 次观测，在第一个与最后一个之间存在 n−1 个相邻间隔。观测速率用 `(n−1)/(t_last−t_first)`。从任意固定窗口数所有到达帧也能计算吞吐，但要把完整窗口当分母，不能混用。历史 31 次出队跨约 1 秒，按 n−1 得 30.000 fps，直接用 31 作同跨度分子会高估约 3.33%。

P95 取排序后的第 `ceil(0.95×m)` 个间隔，P99 同理。m=30 时 P99 等于最大值，P95 也只落在靠尾少数样本附近。高分位在短窗口对个别样本和舍入很敏感。报告要保留样本数与统计方法，并同时看超阈值次数、最大值和连续超限的时间。不同运行中的 P99 先分组比较，不把各组 P99 做一次简单平均当总 P99。

## 用同一个分析器复算历史和两份反例

工具只接受同一采集会话的单调时钟 EOF 记录，排除时间倒退与格式异常。可<a :href="fixtureFile" download="frame-tail-demo.awk">下载生成器</a>和<a :href="analysisFile" download="frame-intervals.sh">区间分析脚本</a>。在 WSL 仓库根目录执行。

~~~bash
mkdir -p output
lab=$(mktemp -d "$PWD/output/frame-tail.XXXXXX")
for mode in steady stall; do
  LC_ALL=C awk -v mode="$mode" -f learning-site/examples/frame-tail-demo.awk > "$lab/$mode.log"
  bash learning-site/examples/frame-intervals.sh --detailed "$lab/$mode.log"
done
bash learning-site/examples/frame-intervals.sh --detailed output/camera-check/capture.log
~~~

| 输入 | 间隔数 | fps | P95 ms | P99 ms | 最大 ms |
| --- | --- | --- | --- | --- | --- |
| steady | 100 | 30.000 | 33.334 | 33.334 | 33.334 |
| stall | 100 | 30.000 | 31.973 | 100.000 | 100.000 |
| 原厂历史短片 | 30 | 30.000 | 33.377 | 33.377 | 33.377 |

stall 人工加入两次 100 ms 间隔，再略缩短其余间隔保持相同平均。三个样本组的 sequence 均连续。即使 P95 更小，stall 仍有不能用平均或序号发现的停顿。历史一秒样本只支持那个窗口的结果，这组数据无法评价长时稳定性或当前硬件是否会偶发掉帧。

## A/B/A 怎样检查测量本身的影响

先定义基线输入和负载，固定链路、时钟、线程配置、媒体格式、支路开关、采集窗口及温度。保证观察点的定义一致，按记录保留数据和取消条件。

1. A1 只保留最低开销的指标，例如应用已有的时间戳或有界计数。
2. B 增加一个观察器，例如详细日志、tracepoint 或更高频的采样。只改变该项。
3. A2 恢复 A1，判断漂移、热状态或后台负载是否使两次基线已经不可比。
4. 多次重复，记录观察器的 CPU、产生字节、事件数和丢失计数。若 B 的变化显著大于 A1↔A2 波动，就要量化观察者影响，再考虑缩小窗口或减轻写日志。

此次完成的是历史日志复算和可控制的反例。真实四路的持续压力、采集器 A/B/A 及各时钟域的对齐留待实板。有了可复用的基线，再用下一节的日志和符号定位第一处异常。 [8.2 内核日志、dynamic debug、符号与调用栈](./kernel-debug-log.md)

## 本节复盘

1. **平均 30 fps，为什么还能卡？** 平均只描述总量或总跨度，长间隔会被其它较短间隔抵消。看尾部、超限次数和相邻帧的顺序。
2. **为什么 31 次 DQBUF 除以首尾跨度会偏大？** 首尾之间只有 30 个间隔；完整窗口计数需要有独立窗口边界。
3. **开启 trace 后尾部变差，如何判断是否被观测影响？** 比较 A/B/A，记录事件开销与丢失，用能复现的低开销基线判定变化。
