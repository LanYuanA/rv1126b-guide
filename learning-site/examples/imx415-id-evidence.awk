# 分类驱动日志中的单次 ID 检查记录，保留原文供复核。
/imx415 [0-9]+-00[0-9a-fA-F]+:/ {
    if (/Detected imx415 id /)
        state = "已接受 ID"
    else if (/skip sensor id check/)
        state = "跳过 ID"
    else if (/Unexpected sensor id/) {
        if (/ret\(0\)/)
            state = "传输完整但 ID 不符"
        else if (/ret\(-[0-9]+\)/)
            state = "helper 失败，ID 值不可作读回证据"
        else
            state = "ID 异常，需核对返回值"
    } else
        next
    found++
    sub(/\r$/, "")
    printf "%s | %s\n", state, $0
}
END {
    if (!found) {
        print "当前窗口未找到 ID 记录" > "/dev/stderr"
        exit 1
    }
}
