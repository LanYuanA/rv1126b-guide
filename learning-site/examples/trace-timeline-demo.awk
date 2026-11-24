# 将已对齐为同域的整数 ns 轨迹配对。模型每次只有一个在途帧。
function fail(message) {
    print "轨迹无效，行 " NR "：" message > "/dev/stderr"
    invalid = 1
    exit 2
}

NF == 0 || $1 ~ /^#/ { next }

{
    if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/)
        fail("字段无效")
    time = $1 + 0
    cpu = $2 + 0
    kind = $3
    key = $4 + 0
    if (time < last)
        fail("时钟倒退")
    last = time
    if (kind == "lost")
        fail("有丢失记录")
    else if (kind == "irq_enter") {
        slot = ++depth[cpu]
        irq_id[cpu, slot] = key
        irq_time[cpu, slot] = time
    } else if (kind == "irq_exit") {
        slot = depth[cpu]
        if (!slot || irq_id[cpu, slot] != key)
            fail("IRQ 出入栈不匹配")
        if (key == camera_irq) {
            irq_duration = time - irq_time[cpu, slot]
            irq_end = time
        }
        delete irq_id[cpu, slot]
        delete irq_time[cpu, slot]
        depth[cpu]--
    } else if (kind == "vb2_done") {
        if (active || !irq_end)
            fail("图像完成缺少 IRQ 候选或已有在途帧")
        active = 1
        seq = key
        done = time
    } else if (kind == "wakeup" && key == capture_pid && active) {
        if (!wake)
            wake = time
    } else if (kind == "switch_in" && key == capture_pid && active) {
        if (wake && !running) {
            running = time
            run_cpu = cpu
        }
    } else if (kind == "dq" && $5 == capture_pid) {
        if (!active || key != seq || !running)
            fail("DQBUF 缺少缓冲、唤醒或调度证据")
        printf "seq=%d CPU=%d IRQ=%.1f us 退出到完成=%.1f us 完成到唤醒=%.1f us runnable=%.1f us 切入到出队=%.1f us\n",
               seq, run_cpu, irq_duration/1000, (done-irq_end)/1000,
               (wake-done)/1000, (running-wake)/1000, (time-running)/1000
        active = wake = running = irq_end = 0
        frames++
    }
}

END {
    if (invalid)
        exit 2
    for (cpu in depth)
        if (depth[cpu])
            fail("窗口里有 IRQ 未结束")
    if (active || !frames)
        fail("没有完整的帧证据")
}
