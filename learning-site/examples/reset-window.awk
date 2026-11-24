# 手工设定的波形刻度，单位为微秒。阈值只用于演算。
function compare(name, release, rails, clock, start,    earliest) {
    # 假设复位释放、供电稳定、时钟稳定都必须先达到。
    earliest = release + 20
    if (rails > earliest)
        earliest = rails
    if (clock > earliest)
        earliest = clock

    printf "%s：最早 START=%d us，实际 START=%d us，余量=%d us\n",
           name, earliest, start, start - earliest
}
BEGIN {
    compare("晚开始", 100, 110, 150, 170)
    compare("复位等待够，时钟尚未稳定", 100, 110, 150, 140)
}
