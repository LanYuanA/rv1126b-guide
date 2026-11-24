# 只模拟单槽交接。提交异步任务与完成读取是两个独立事件。
function run(label, returned,    next_capture, consumer_done, second_write, overlap) {
    next_capture = 33
    consumer_done = 48
    # 捕获在下一帧时刻才会开始，已归还的槽才可被选中。
    second_write = returned > next_capture ? returned : next_capture
    overlap = consumer_done > second_write ? consumer_done - second_write : 0
    printf "%s: 归还=%d ms, 最早复写=%d ms, 读取重叠=%d ms\n",
           label, returned, second_write, overlap
}
BEGIN {
    run("提交时归还", 5)
    run("完成时归还", 48)
}
