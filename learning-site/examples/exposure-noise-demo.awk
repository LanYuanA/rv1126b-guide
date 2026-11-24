# 简化的线性采样模型，不使用 IMX415 的标定参数。
# radiance 是每毫秒到达的电子数期望，模拟增益在量化前，数字增益在量化后。
function uniform() {
    state = (16807 * state) % 2147483647
    return state / 2147483647
}

function normal(    sum, n) {
    sum = 0
    for (n = 0; n < 12; n++)
        sum += uniform()
    return sum - 6
}

function clip(value, low, high) {
    if (value < low)
        return low
    if (value > high)
        return high
    return value
}

function measure(label, radiance, ms, analog, digital,    i, signal, electrons, adc, out, mean, sq, saturated, sd) {
    mean = sq = saturated = 0
    signal = radiance * ms
    for (i = 0; i < samples; i++) {
        # 光子散粒噪声用均值较高时的正态近似，读取噪声的简化标准差为 3 e-。
        electrons = clip(signal + sqrt(signal) * normal(), 0, full_well)
        electrons = electrons + 3 * normal()
        adc = clip(int(electrons * analog / electrons_per_code + 0.5), 0, max_code)
        saturated += (adc == max_code)
        out = clip(adc * digital, 0, max_code)
        mean += out
        sq += out * out
    }
    mean /= samples
    sd = sqrt(sq / samples - mean * mean)
    printf "%-25s %6.2f %5.2f %5.2f %7.2f %7.2f %8.2f %8.2f%%\n",
           label, ms, analog, digital, mean, sd, velocity * ms / 1000,
           100 * saturated / samples
}

BEGIN {
    state = 47
    samples = 8192
    full_well = 10000
    electrons_per_code = 8
    max_code = 1023
    velocity = 240
    print "组别                      曝光ms 模拟增益 数字增益 均值DN  标准差DN  拖影px  ADC饱和"
    measure("gray-long", 80, 10, 1, 1)
    measure("gray-short-analog", 80, 2.5, 4, 1)
    measure("gray-short-digital", 80, 2.5, 1, 4)
    measure("bright-long", 1800, 10, 1, 1)
    measure("bright-long-reduced", 1800, 10, 1, 0.25)
    measure("bright-short", 1800, 2.5, 1, 1)
}
