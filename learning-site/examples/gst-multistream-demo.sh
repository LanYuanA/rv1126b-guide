#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C GST_DEBUG_NO_COLOR=1

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo/output"
logs=$(mktemp -d "$repo/output/gst-multistream.XXXXXX")
printf '日志与素材 %s\n' "$logs"
for element in x264enc h264parse openh264dec matroskamux matroskademux jpegenc jpegdec videoscale; do
    gst-inspect-1.0 "$element" >/dev/null
done

check_video() {
    local path=$1 width=$2 height=$3 count
    gst-launch-1.0 -v filesrc "location=$path" ! matroskademux ! h264parse ! \
        'video/x-h264,stream-format=byte-stream,alignment=au' ! openh264dec ! \
        "video/x-raw,width=$width,height=$height" ! identity name=decode silent=false ! \
        fakesink sync=false >"${path%.mkv}.decode.log" 2>&1
    count=$(sed -nE '/GstIdentity:decode: last-message = chain/s/.*pts: ([^,]+),.*/\1/p' \
        "${path%.mkv}.decode.log" | sort -u | wc -l)
    test "$count" -eq 60
    grep -q '^Got EOS' "${path%.mkv}.decode.log"
    printf '%s %dx%d 解码帧=%d 大小=%d bytes\n' "${path##*/}" "$width" "$height" "$count" "$(wc -c <"$path")"
}

for mode in preview main mirror separate all; do
    dir="$logs/$mode"
    mkdir -p "$dir"
    media=(videotestsrc num-buffers=60 ! 'video/x-raw,format=I420,width=320,height=240,framerate=30/1'
           ! tee name=raw raw. ! queue name=previewq ! videoscale ! 'video/x-raw,width=160,height=120'
           ! identity name=previewer silent=false ! fakesink sync=false)
    if [[ "$mode" != preview ]]; then
        media+=(raw. ! queue ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bitrate=512
                ! h264parse ! matroskamux streamable=true)
        if [[ "$mode" == mirror ]]; then
            media+=(! tee name=encoded encoded. ! queue ! filesink "location=$dir/main.mkv" sync=false
                    encoded. ! queue ! filesink "location=$dir/backup.mkv" sync=false)
        else
            media+=(! filesink "location=$dir/main.mkv" sync=false)
        fi
    fi
    if [[ "$mode" == separate || "$mode" == all ]]; then
        media+=(raw. ! queue ! videoscale ! 'video/x-raw,width=160,height=120' !
                x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bitrate=128 !
                h264parse ! matroskamux streamable=true ! filesink "location=$dir/backup.mkv" sync=false)
    fi
    if [[ "$mode" == all ]]; then
        media+=(raw. ! queue ! videorate drop-only=true ! 'video/x-raw,framerate=1/1'
                ! jpegenc ! multifilesink "location=$dir/still-%02d.jpg" post-messages=true)
    fi

    printf '\n%s\n' "$mode"
    GST_DEBUG=queue:6 /usr/bin/time -f '%e %M' -o "$dir/time.txt" \
        gst-launch-1.0 -m -v "${media[@]}" >"$dir/pipeline.log" 2>"$dir/queue.log"
    grep -q '^Got EOS' "$dir/pipeline.log"
    preview_count=$(sed -nE '/GstIdentity:previewer: last-message = chain/s/.*pts: ([^,]+),.*/\1/p' \
        "$dir/pipeline.log" | sort -u | wc -l)
    test "$preview_count" -eq 60
    read -r elapsed rss <"$dir/time.txt"
    printf '预览帧=%d 总耗时=%s s 峰值RSS=%s KiB\n' "$preview_count" "$elapsed" "$rss"
    awk '/<previewq> src position updated/ {print "预览首帧出队，日志计时 " $1; exit}' "$dir/queue.log"

    if [[ "$mode" != preview ]]; then
        check_video "$dir/main.mkv" 320 240
    fi
    if [[ "$mode" == mirror ]]; then
        cmp "$dir/main.mkv" "$dir/backup.mkv"
        check_video "$dir/backup.mkv" 320 240
    elif [[ "$mode" == separate || "$mode" == all ]]; then
        check_video "$dir/backup.mkv" 160 120
    fi
    if [[ "$mode" == all ]]; then
        grep 'GstMultiFileSink.*still-01.jpg.*timestamp=(guint64)1000000000' "$dir/pipeline.log"
        gst-launch-1.0 -q filesrc "location=$dir/still-01.jpg" ! jpegdec ! \
            'video/x-raw,width=320,height=240' ! fakesink
        file "$dir/still-01.jpg"
    fi
done
