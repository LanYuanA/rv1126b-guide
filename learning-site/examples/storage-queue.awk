# 单位为 1/30 毫秒，避免 30 fps 的小数时钟影响边界判断。
function run(label, burst,    i, arrival, service, start, retired, depth,
             peak, max_wait, total, rank, seen, p95, ticks) {
    for (i = 0; i < 30; i++) {
        arrival = i * 1000
        # 两组总服务时间相等。慢项都从每个十帧组的首帧开始。
        service = burst ? (i % 10 == 0 ? 3600 : 120) : 468
        while (retired < i && completion[retired] <= arrival)
            retired++
        depth = i - retired + 1
        if (depth > peak)
            peak = depth
        start = (i == 0 || completion[i - 1] < arrival) ? arrival : completion[i - 1]
        if (start - arrival > max_wait)
            max_wait = start - arrival
        completion[i] = start + service
        total += service
        count[service]++
    }
    # 最近秩 P95，30 个观察值中的第 29 大小顺位。
    rank = 29
    for (ticks = 0; ticks <= 3600; ticks++) {
        seen += count[ticks]
        if (seen >= rank) {
            p95 = ticks
            break
        }
    }
    printf "%s: 平均=%.1f ms P95=%.1f ms 在途峰值=%d 最长等待=%.3f ms\n",
           label, total / (30 * 30), p95 / 30, peak, max_wait / 30
    delete completion
    delete count
}
BEGIN {
    run("平稳", 0)
    run("突发", 1)
}
