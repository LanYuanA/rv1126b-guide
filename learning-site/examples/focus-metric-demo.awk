# 在一维靶标上混合低通与未滤波像素，模拟失焦趋势和往返迟滞。
# 这些位置是模型刻度，不能发送到真实执行器。
function abs(value) { return value < 0 ? -value : value }

function edge_score(position, peak, flat,   x, blur, weight, pixel, previous, score) {
    weight = abs(position - peak) / 80
    score = 0
    for (x = 2; x < 12; x++) {
        blur = (target[x - 1] + 2 * target[x] + target[x + 1]) / 4
        pixel = flat ? 120 : (1 - weight) * target[x] + weight * blur
        if (x > 2)
            score += (pixel - previous)^2
        previous = pixel
    }
    return score
}

function scan(label, start, stop, step, peak, flat,
              pos, score, best_pos, best, low, count) {
    best = -1
    for (pos = start; pos != stop + step; pos += step) {
        score = edge_score(pos, peak, flat)
        printf "%s\t%d\t%.2f\n", label, pos, score > trace
        if (!count || score < low)
            low = score
        if (score > best) {
            best = score
            best_pos = pos
        }
        count++
    }
    if (best - low < 10)
        printf "%s 无有效峰值（峰谷差 %.2f）\n", label, best - low
    else
        printf "%s 峰值位置=%d，分数=%.2f，峰谷差=%.2f\n", label, best_pos, best, best - low
}

BEGIN {
    if (trace == "") {
        print "请用 -v trace=路径 指定扫描 TSV" > "/dev/stderr"
        exit 2
    }
    split("60 60 60 180 180 60 60 180 180 180 60 60", target, " ")
    print "direction\tposition\tscore" > trace
    scan("forward", 0, 100, 5, 60, 0)
    scan("reverse", 100, 0, -5, 55, 0)
    scan("flat-roi", 0, 100, 5, 60, 1)
    close(trace)
}
