# 按 SDK HDR_X2 的整数公式复算两组受控行值，再用简化模型观察亮暗与错位。
function maximum(a, b) { return a > b ? a : b }
function minimum(a, b) { return a < b ? a : b }

function timing(label, long_lines, short_lines, old_rhs,
                shr0, shr1, rhs, min_rhs, max_rhs) {
    shr0 = fsc - long_lines
    min_rhs = 4 * int((maximum(17, old_rhs + 2 * brl - fsc + 2) + 3) / 4) + 1
    max_rhs = minimum(4 * int((2 * brl - 1) / 4) + 1, 4 * int((shr0 - 9) / 4) + 1)
    if (max_rhs < min_rhs) {
        printf "%s: RHS1 min=%d max=%d，不存在合法区间\n", label, min_rhs, max_rhs
        return
    }
    rhs = 4 * int((9 + short_lines + 3) / 4) + 1
    rhs = maximum(min_rhs, minimum(rhs, max_rhs))
    shr1 = maximum(9, rhs - short_lines)
    shr0 = maximum(rhs + 9, minimum(shr0, fsc - 8))
    printf "%s: FSC=%d RHS1=%d SHR0=%d SHR1=%d 长行=%d 短行=%d\n",
           label, fsc, rhs, shr0, shr1, fsc - shr0, rhs - shr1
}

function sample(level, exposure) { return int(minimum(level * exposure, 1) * 1023 + 0.5) }

function report(label, level,   l, s, normalized) {
    l = sample(level, 8)
    s = sample(level, 1)
    normalized = l < 1023 ? l / (1023 * 8) : s / 1023
    printf "%s: long=%d short=%d 合成线性估计=%.4f\n", label, l, s, normalized
}

BEGIN {
    fsc = 4600
    brl = 2228
    timing("可行行值", 3200, 180, 225)
    timing("冲突行值", 4480, 40, 401)
    report("深暗", 0.006)
    report("高光", 0.8)
    printf "曝光时间中心相隔 5 ms，移动速度 240 px/s，边缘相差 %.2f px\n", 240 * 0.005
    printf "两条阶跃边界相差一像素，边界间一像素混合值 %.2f（两侧是 0.10 和 0.80）\n", (0.10 + 0.80) / 2
}
