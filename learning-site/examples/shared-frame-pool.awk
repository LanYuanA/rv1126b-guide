# 模拟直接共享同一帧的两个消费者，以最后完成者决定槽位何时可用。
function run(capacity,    slot, frame, at, dropped, first_drop) {
    delete ready
    dropped = 0
    first_drop = -1
    for (frame = 0; frame < 8; frame++) {
        at = frame * 33
        for (slot = 0; slot < capacity; slot++)
            if (ready[slot] <= at)
                break
        if (slot == capacity) {
            if (first_drop < 0)
                first_drop = at
            printf "t=%3d 帧=%d 丢弃\n", at, frame
            dropped++
        } else {
            ready[slot] = at + 110
            printf "t=%3d 帧=%d 槽=%d 预览完成=%d 编码完成=%d\n",
                   at, frame, slot, at + 5, ready[slot]
        }
    }
    printf "槽数=%d 丢弃=%d 首次丢弃=%d ms（-1 表示无）\n",
           capacity, dropped, first_drop
}
BEGIN {
    run(3)
    run(4)
}
