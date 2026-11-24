# 每条输入依次记录组名、轮次、分配数、释放数、活动对象数和总槽数。
/^[[:space:]]*(#|$)/ { next }
NF != 6 {
    print "输入应包含六列，行号 " NR > "/dev/stderr"
    exit 2
}
{
    group = $1
    live = $5 + 0
    if (!(group in baseline))
        baseline[group] = live
    net[group] += $3 - $4
    printf "%s 第%d轮: 本轮净分配=%d 累计净分配=%d 活动变化=%d 槽数=%d\n",
           group, $2, $3 - $4, net[group], live - baseline[group], $6
}
