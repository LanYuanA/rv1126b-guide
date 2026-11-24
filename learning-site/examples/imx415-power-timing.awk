# 只累加普通路径的 usleep_range 参数。操作耗时和调度延迟另计。
function show(stage, min_wait, max_wait) {
    minimum += min_wait
    maximum += max_wait
    printf "%s：累计请求睡眠 %.0f～%.0f ms\n", stage, minimum / 1000, maximum / 1000
}
BEGIN {
    show("POWER 请求后，准备释放 RESET", 10000, 20000)
    show("RESET 释放后，准备配置 XVCLK", 10000, 20000)
    show("bulk 成功后，准备返回 probe", 20000, 30000)
}
