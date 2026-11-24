# 同一输入只改变时域混合。此 AWK 无模型、NPU 或厂商数据。
function middle_sample(position, frame) {
    return position < frame ? 0.10 : 0.80
}

BEGIN {
    split("100 108 104 96 104 96 92 100", flat, " ")
    for (frame = 2; frame <= 8; frame++) {
        value = flat[frame]
        blended = (flat[frame - 1] + value) / 2
        sum += value
        sumsq += value * value
        blend_sum += blended
        blend_sumsq += blended * blended
    }
    printf "等曝光平坦区标准差 %.2f -> %.2f\n",
           sqrt(sumsq / 7 - (sum / 7)^2), sqrt(blend_sumsq / 7 - (blend_sum / 7)^2)

    position = 3
    before = middle_sample(position, 3)
    current = middle_sample(position, 4)
    printf "移动边缘刚跨过该位置 原始=%.2f 上一帧=%.2f 混合=%.2f\n",
           current, before, (before + current) / 2

    width = 3840
    height = 2160
    stride = width * 2
    count = 3
    size = stride * height
    printf "示意 16 位容器 单缓冲=%d bytes 三缓冲=%d bytes 往返 30fps=%d bytes/s\n",
           size, size * count, size * 2 * 30
}
