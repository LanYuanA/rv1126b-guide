# 两份序列均有 100 个间隔，合计 100/30 秒，帧序号连续。
BEGIN {
    if (mode != "steady" && mode != "stall") {
        print "mode 应为 steady 或 stall" > "/dev/stderr"
        exit 2
    }
    total = 100 / 30
    short_interval = (total - 2 * 0.1) / 98
    time = 1
    printf "cap dqbuf: seq: 0 ts: %.6f (ts-monotonic, ts-src-eof)\n", time
    for (i = 1; i <= 100; i++) {
        if (mode == "steady")
            time += 1 / 30
        else if (i == 35 || i == 76)
            time += 0.1
        else
            time += short_interval
        printf "cap dqbuf: seq: %d ts: %.6f (ts-monotonic, ts-src-eof)\n", i, time
    }
}
