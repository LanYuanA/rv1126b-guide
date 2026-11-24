# 用固定的目标框序列验证 2× 数字取景。各个坐标先限制再按 2 对齐。
function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v }
function abs(v) { return v < 0 ? -v : v }
function aligned(v, limit) { return 2 * int(clamp(v, 0, limit) / 2) }
function move(current, target, max_position) {
    return aligned(current + clamp(target - current, -max_step, max_step), max_position)
}
function smooth(current, target, max_position) {
    return abs(target - current) <= dead_zone ? current : move(current, target, max_position)
}

BEGIN {
    width = 3840
    height = 2160
    roi_w = 1920
    roi_h = 1080
    center_left = (width - roi_w) / 2
    center_top = (height - roi_h) / 2
    left = center_left
    top = center_top
    dead_zone = 24
    max_step = 160
    lost = 0
    print "帧 目标 直接left/top 平滑left/top"
}

NF && $1 !~ /^#/ {
    frame = $1
    if ($2 == "-") {
        lost++
        if (lost >= 3) {
            left = move(left, center_left, width - roi_w)
            top = move(top, center_top, height - roi_h)
        }
        printf "%2d 丢失   -             %d/%d\n", frame, left, top
        next
    }
    lost = 0
    target_x = ($2 + $4) / 2
    target_y = ($3 + $5) / 2
    target_left = aligned(target_x - roi_w / 2, width - roi_w)
    target_top = aligned(target_y - roi_h / 2, height - roi_h)
    left = smooth(left, target_left, width - roi_w)
    top = smooth(top, target_top, height - roi_h)
    printf "%2d 可见   %4d/%-4d     %d/%d\n", frame, target_left, target_top, left, top
}
