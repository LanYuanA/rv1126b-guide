# 使用标称有效像素和数据 lane 速率，未纳入突发或包开销。
function report(lanes,    each_lane) {
    each_lane = payload / lanes
    printf "%d lane：载荷 %.3f Gbit/s，平均每 lane %.3f Mbit/s，" \
           "名义每 lane %.0f Mbit/s，占比 %.2f%%\n",
           lanes, payload / 1e9, each_lane / 1e6, nominal / 1e6,
           100 * each_lane / nominal
}
BEGIN {
    payload = 3864 * 2192 * 30 * 10
    nominal = 2 * 446 * 1e6
    report(4)
    report(2)
}
