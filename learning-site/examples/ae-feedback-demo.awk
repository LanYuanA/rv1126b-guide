# 线性曝光反馈模型，亮度阶跃发生在 frame 12。曝光乘积在 log2 域更新，
# 拍摄约束固定最短积分 1 ms、运动积分上限 8 ms、总倍率上限 8×。
function limit(value, low, high) { return value < low ? low : value > high ? high : value }
function abs(value) { return value < 0 ? -value : value }
function log2(value) { return log(value) / log(2) }

function simulate(name, rate, delay, center_weight,
                  frame, k, ambient, applied, exposure, gain, face, background, meter,
                  command_log, peak, streak, settle, final_face, history) {
    for (k = -delay; k < 0; k++)
        history[k] = 0
    command_log = 0
    peak = 0
    streak = 0
    settle = -1
    for (frame = 0; frame < 60; frame++) {
        ambient = frame < 12 ? 1 : 0.25
        applied = 2 ^ history[frame - delay]
        exposure = limit(4 * applied, 1, 8)
        gain = limit(4 * applied / exposure, 1, 8)
        face = limit(0.42 * ambient * exposure * gain / 4, 0, 1)
        background = limit(0.84 * ambient * exposure * gain / 4, 0, 1)
        meter = center_weight * face + (1 - center_weight) * background
        command_log = limit(command_log + rate * log2(0.42 / meter), -2, 4)
        history[frame] = command_log
        printf "%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n",
               name, frame, ambient, exposure, gain, face, meter, 2 ^ command_log > trace
        if (frame < 12)
            continue
        if (face - 0.42 > peak)
            peak = face - 0.42
        if (abs(face - 0.42) <= 0.42 * 0.05) {
            streak++
            if (streak == 4 && settle == -1)
                settle = frame - 3 - 12
        } else {
            streak = 0
        }
        final_face = face
    }
    printf "%s\t容差带进入(帧)=%d\t过冲=%5.1f%%\t最后主体亮度=%.3f\n",
           name, settle, 100 * peak / 0.42, final_face
}

BEGIN {
    if (trace == "") {
        print "请用 -v trace=路径 指定实验逐帧 TSV" > "/dev/stderr"
        exit 2
    }
    print "case\tframe\tlight\texposure_ms\tgain\tface\tmeter\tqueued_multiplier" > trace
    simulate("center-smooth", 0.28, 2, 1)
    simulate("center-aggressive", 1.05, 2, 1)
    simulate("matrix-meter", 0.28, 2, 0.25)
    close(trace)
}
