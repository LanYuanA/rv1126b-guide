#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
command -v gst-launch-1.0 >/dev/null || {
    printf '请先启用站点的 WSL GStreamer 环境\n' >&2
    exit 1
}
mkdir -p "$repo/output"
logs=$(mktemp -d "$repo/output/gst-queue.XXXXXX")
printf '日志目录 %s\n' "$logs"
export LC_ALL=C GST_DEBUG_NO_COLOR=1
caps='video/x-raw,format=NV12,width=320,height=240,framerate=30/1'
for mode in no upstream downstream; do
    GST_DEBUG=queue:6 gst-launch-1.0 -v videotestsrc num-buffers=18 ! "$caps" ! \
        tee name=fan \
        fan. ! queue name=previewq ! identity name=preview silent=false ! fakesink sync=false \
        fan. ! queue name=slowq max-size-buffers=3 max-size-bytes=0 max-size-time=0 leaky="$mode" ! \
        identity name=record sleep-time=40000 silent=false ! fakesink sync=false \
        >"$logs/$mode.log" 2>"$logs/$mode.queue.log"
    grep -q '^Got EOS' "$logs/$mode.log"
    printf '\nleaky=%s\n' "$mode"
    for branch in preview record; do
        # stdout 在 preroll 完成时有机会重复展示首个属性通知，按 offset 去重。
        sed -nE "/GstIdentity:$branch: last-message = chain/s/.*offset: ([0-9]+),.*/\1/p" "$logs/$mode.log" |
            sort -nu >"$logs/$mode.$branch.txt"
        count=$(wc -l <"$logs/$mode.$branch.txt")
        printf '%s=%d offsets=%s\n' "$branch" "$count" "$(paste -sd , "$logs/$mode.$branch.txt")"
        if [[ "$branch" == preview || "$mode" == no ]]; then
            diff -u <(seq 0 17) "$logs/$mode.$branch.txt"
        else
            test "$count" -gt 0 && test "$count" -lt 18
        fi
    done
    grep '^Execution ended' "$logs/$mode.log"
    awk '/<previewq> src position updated to 0:00:00.600000000/ {
        print "预览队列最后一帧出队，日志计时 " $1
    }' "$logs/$mode.queue.log"
done
grep -xq 17 "$logs/downstream.record.txt"
