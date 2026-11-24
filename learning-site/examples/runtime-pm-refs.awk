# 模拟普通开停流路径，只对持有的引用记账。
function report(event, action, expected) {
    printf "%s: %s, stream=%d, 其他=%d, 合计=%d\n",
           event, action, stream_ref, other_ref, stream_ref + other_ref
    if (stream_ref + other_ref != expected)
        exit 1
}
function start(event, resume_ok, registers_ok, expected) {
    if (stream_ref) {
        report(event, "已在开流，保持引用", expected)
        return
    }
    stream_ref++
    if (!resume_ok) {
        stream_ref--
        report(event, "get_sync 失败，用 put_noidle 配平", expected)
    } else if (!registers_ok) {
        stream_ref--
        report(event, "写寄存器失败，用 put 归还引用", expected)
    } else {
        report(event, "成功，保留开流引用", expected)
    }
}
function stop(event, expected) {
    if (stream_ref)
        stream_ref--
    report(event, "归还开流引用", expected)
}
BEGIN {
    report("仅打开 fd", "模型未增加 sensor 引用", 0)
    start("第一次开流", 1, 1, 1)
    start("重复开流", 1, 1, 1)
    stop("第一次停流", 0)
    start("恢复失败", 0, 0, 0)
    start("启动失败", 1, 0, 0)
    other_ref = 1
    start("重新开流", 1, 1, 2)
    stop("重新停流", 1)
    other_ref = 0
    report("另一使用者退出", "归还其他引用", 0)
}
