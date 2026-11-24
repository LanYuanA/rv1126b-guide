# 统计一段采集会话中的槽位复用，序号连续性按单调窗口计算。
/^cap dqbuf:/ {
    slot = $3
    seq = ""
    for (i = 4; i < NF; i++)
        if ($i == "seq:")
            seq = $(i + 1)
    if (slot !~ /^[0-9]+$/ || seq !~ /^[0-9]+$/ || (count && seq + 0 <= previous)) {
        print "无效字段或序号跨越采集窗口，行 " NR > "/dev/stderr"
        failed = 1
        exit 2
    }
    if (count && seq - previous > 1)
        gaps += seq - previous - 1
    previous = seq + 0
    if (slot in last && count < 8)
        printf "槽位 %s：sequence %d → %d\n", slot, last[slot], seq
    if (!(slot in last))
        slots++
    last[slot] = previous
    count++
}
END {
    if (failed || !count)
        exit 2
    printf "出队=%d 使用槽=%d 序号缺口=%d\n", count, slots, gaps
}
