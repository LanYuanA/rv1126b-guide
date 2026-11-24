# 回放每行：session clock ns event 后跟事件字段。暂只接受单会话同域单调时间。
function fail(message) {
    bad = 1
    printf "无效输入，第 %d 行：%s\n", NR, message > "/dev/stderr"
    exit 2
}
function uint(value) { return value ~ /^[0-9]+$/ }
function frame_key(queue, slot_number, sequence) { return queue SUBSEP slot_number SUBSEP sequence }
function age(start, end) { return (end - start) / 1000000 }

BEGIN {
    if (!hold_ms) hold_ms = 50
    if (!capacity) capacity = 4096
}

NF == 0 || $1 ~ /^#/ { next }
{
    if ($2 != "mono" || !uint($3) || $3 + 0 > 9007199254740991 || (seen && ($1 != session || $3 + 0 < previous)))
        fail("会话、时钟域或时间顺序不一致")
    session = $1
    time = $3 + 0
    previous = time
    seen++
    kind = $4

    if (kind == "dq" || kind == "qbuf" || kind == "hold" || kind == "release") {
        if ($5 == "" || !uint($6) || !uint($7))
            fail("帧缺少队列、槽位或序号")
        queue = $5
        slot = queue SUBSEP ($6 + 0)
        frame = frame_key(queue, $6 + 0, $7 + 0)
        branch = frame SUBSEP $8
    }

    if (kind == "dq") {
        if (slot in owner)
            fail("尚未归还的槽位被再次交付")
        if ((queue in last_seq) && $7 + 0 <= last_seq[queue])
            fail("序号倒退，需划分会话才能回放")
        if (!(queue in last_seq) && ++queues > capacity) fail("队列容量不足")
        if (queue in last_seq) {
            gap = $7 - last_seq[queue] - 1
            if (gap)
                printf "观察到序号缺口 queue=%s before=%.0f after=%.0f gap=%.0f\n",
                       queue, last_seq[queue], $7, gap
            gaps += gap
        }
        last_seq[queue] = $7 + 0
        owner[slot] = frame
        delivered[frame] = time
        pending++
        if (pending > peak) peak = pending
        if (pending > capacity) fail("帧容量不足")
    } else if (kind == "hold") {
        if (!(frame in delivered) || $8 == "" || (branch in holding))
            fail("缺少交付记录或重复取得支路引用")
        if (++held > capacity) fail("支路容量不足")
        holding[branch] = time
        references[frame]++
    } else if (kind == "release") {
        if (!(branch in holding))
            fail("缺少支路引用")
        duration = age(holding[branch], time)
        if (duration >= hold_ms)
            printf "支路持有超阈值 queue=%s slot=%s seq=%s branch=%s hold=%.3f ms\n",
                   queue, $6, $7, $8, duration
        references[frame]--
        delete holding[branch]
        held--
    } else if (kind == "qbuf") {
        if (!(frame in delivered) || references[frame])
            fail("归还前缺交付或支路仍持有引用")
        elapsed = age(delivered[frame], time)
        if (elapsed > longest) longest = elapsed
        returned++
        pending--
        delete owner[slot]
        delete delivered[frame]
        delete references[frame]
    } else if (kind == "alloc") {
        if ($5 !~ /^0x[0-9a-fA-F]+$/ || !uint($6) || $6 == 0 || !uint($7) || $8 == "")
            fail("分配字段无效")
        if ($5 in object_bytes)
            fail("对象地址已存在，可能是缺失 free 或重复事件")
        if (++objects > capacity)
            fail("分配表容量不足")
        object_bytes[$5] = $6 + 0
        object_context[$5] = $7
        object_stack[$5] = $8
        live += $6
        live_by_stack[$8] += $6
        live_by_context[$7] += $6
        if ($6 <= 64) bucket64++
        else if ($6 <= 4096) bucket4096++
        else bucket_large++
    } else if (kind == "free") {
        if ($5 !~ /^0x[0-9a-fA-F]+$/ || !uint($6))
            fail("释放字段无效")
        if ($5 in object_bytes) {
            bytes = object_bytes[$5]
            live -= bytes
            live_by_stack[object_stack[$5]] -= bytes
            live_by_context[object_context[$5]] -= bytes
            if (!live_by_stack[object_stack[$5]]) delete live_by_stack[object_stack[$5]]
            if (!live_by_context[object_context[$5]]) delete live_by_context[object_context[$5]]
            delete object_bytes[$5]
            delete object_context[$5]
            delete object_stack[$5]
            objects--
        } else {
            unmatched_free++
        }
    } else if (kind == "stop") {
        printf "停止检查 seq=%s 活跃分配=%.0f bytes 待归还槽=%d\n", $5, live, pending
        if (stops && live == previous_stop) stable_stops++
        previous_stop = live
        stops++
    } else if (kind == "lost") {
        if (!uint($6) || $6 == 0)
            fail("丢失计数无效")
        lost += $6
    } else {
        fail("未知事件")
    }
}

END {
    if (bad || !seen) exit 2
    printf "session=%s gaps=%.0f peak_slots=%d returned=%d pending=%d max_slot_ms=%.3f\n",
           session, gaps, peak, returned, pending, longest
    printf "alloc_buckets <=64:%d <=4096:%d >4096:%d live=%.0f bytes unmatched_free=%d\n",
           bucket64, bucket4096, bucket_large, live, unmatched_free
    for (stack in live_by_stack)
        if (live_by_stack[stack]) printf "活跃栈 %s %.0f bytes\n", stack, live_by_stack[stack]
    for (context in live_by_context)
        if (live_by_context[context]) printf "分配时上下文 PID %s %.0f bytes\n", context, live_by_context[context]
    printf "相邻等值停止=%d/%d lost=%d\n", stable_stops, stops ? stops - 1 : 0, lost
    if (lost || unmatched_free || pending)
        print "可用证据受限，保留缺口，不做根因或泄漏断言"
}
