# 简化的线性 RGB 灰卡实验，G 作为参考。避免饱和以隔离增益效果。
function report(label, r, g, b, gain_r, gain_b) {
    printf "%-20s 原始R/G=%.3f B/G=%.3f 增益R=%.3f B=%.3f 校正RGB=%.2f/%.2f/%.2f\n",
           label, r / g, b / g, gain_r, gain_b, r * gain_r, g, b * gain_b
}

BEGIN {
    report("warm-gray", 128, 96, 64, 96 / 128, 96 / 64)
    report("cool-gray", 72, 96, 112, 96 / 72, 96 / 112)

    # 同时有两种光时，全局增益让两块灰的均值中性，但每块仍有偏色。
    report("mixed-warm-side", 128, 96, 64, 96 / 100, 96 / 88)
    report("mixed-cool-side", 72, 96, 112, 96 / 100, 96 / 88)

    # 把红色物体误作灰卡后求得的增益，再应用到实际的暖光灰卡。
    report("biased-gray-world", 128, 96, 64, 70 / 180, 70 / 50)

    gain_r = 96 / 128
    gain_b = 96 / 64
    for (n = 1; n <= 40; n++) {
        gain_r = gain_r + 0.25 * (96 / 72 - gain_r)
        gain_b = gain_b + 0.25 * (96 / 112 - gain_b)
        ratio_r = 72 * gain_r / 96
        ratio_b = 112 * gain_b / 96
        if (ratio_r >= 0.98 && ratio_r <= 1.02 && ratio_b >= 0.98 && ratio_b <= 1.02) {
            printf "暖光切到冷光后第 %d 次更新 R/G=%.3f B/G=%.3f\n", n, ratio_r, ratio_b
            exit 0
        }
    }
    exit 1
}
