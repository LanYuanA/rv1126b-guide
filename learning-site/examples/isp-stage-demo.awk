# 小信号模型，仅演示各处理目标。所有参数来自人工输入。
function max(a, b) { return a > b ? a : b }
function min(a, b) { return a < b ? a : b }
function median3(a, b, c) { return a + b + c - min(min(a, b), c) - max(max(a, b), c) }
function report(label, r, g, b) { printf "%s %.2f %.2f %.2f\n", label, r, g, b }

BEGIN {
    black = 16
    center = max(80 - black, 0)
    corner = max(64 - black, 0)
    printf "黑电平和阴影 中心=%d 角落=%d 校正角落=%.0f\n", center, corner, corner * 4 / 3

    printf "坏点 同色点 62,64,66 中位数=%d 原始坏点=255\n", median3(62, 64, 66)

    # SGBRG：G 点 (1,1) 的左右为 R、上下为 B。
    red = (88 + 92) / 2
    green = 64
    blue = (40 + 44) / 2
    report("去马赛克 RGB", red, green, blue)
    red *= 64 / 90
    blue *= 64 / 42
    report("白平衡 RGB", red, green, blue)

    # 保持灰点用每行和为 1 的矩阵，红色样本仍可能变化。
    report("示意 CCM 前", 90, 60, 30)
    report("示意 CCM 后", 1.20 * 90 - 0.12 * 60 - 0.08 * 30,
           -0.08 * 90 + 1.16 * 60 - 0.08 * 30,
           -0.05 * 90 - 0.10 * 60 + 1.15 * 30)
    printf "示意色调 亮度0.25 -> %.2f，亮度1.00 -> %.2f\n", sqrt(0.25), sqrt(1.0)

    split("28 34 30 35 29 33", signal, " ")
    for (i = 2; i < 6; i++) {
        input_sum += signal[i]
        input_sq += signal[i] * signal[i]
        smooth = (signal[i - 1] + 2 * signal[i] + signal[i + 1]) / 4
        output_sum += smooth
        output_sq += smooth * smooth
    }
    printf "降噪示意 平坦区标准差 %.2f -> %.2f\n",
           sqrt(input_sq / 4 - (input_sum / 4)^2),
           sqrt(output_sq / 4 - (output_sum / 4)^2)

    # 50,50,150,150 的阶跃边缘做一轮 unsharp mask。
    left_blur = (50 + 2 * 50 + 150) / 4
    right_blur = (50 + 2 * 150 + 150) / 4
    printf "锐化示意 边缘两点 50/150 -> %.0f/%.0f\n", 100 - left_blur, 300 - right_blur
}
