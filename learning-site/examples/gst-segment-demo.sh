#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C GST_DEBUG_NO_COLOR=1

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo/output"
logs=$(mktemp -d "$repo/output/gst-segment.XXXXXX")
printf '日志与片段 %s\n' "$logs"

for element in x264enc x265enc h264parse h265parse openh264dec libde265dec splitmuxsink qtdemux; do
    gst-inspect-1.0 "$element" >/dev/null
done

run_case() {
    local codec=$1 gop=$2 decoder dir part frames first bytes total=0
    local -a encoder opened expected parser_layout
    dir="$logs/$codec-gop$gop"
    mkdir -p "$dir"
    if [[ "$codec" == h264 ]]; then
        encoder=(x264enc tune=zerolatency speed-preset=ultrafast "key-int-max=$gop"
                 "option-string=min-keyint=$gop:scenecut=0:open-gop=0")
        decoder=openh264dec
    else
        encoder=(x265enc tune=zerolatency speed-preset=ultrafast "key-int-max=$gop"
                 "option-string=pools=none:frame-threads=1:min-keyint=$gop:scenecut=0:open-gop=0")
        decoder=libde265dec
    fi
    if [[ "$gop" == 10 ]]; then
        expected=(0 2000000000 4000000000 6000000000)
    else
        expected=(0 3000000000 6000000000)
    fi
    parser_layout=("video/x-$codec,stream-format=byte-stream,alignment=au")
    gst-launch-1.0 -m videotestsrc num-buffers=70 ! \
        'video/x-raw,format=I420,width=320,height=240,framerate=10/1' ! \
        "${encoder[@]}" ! "${codec}parse" ! \
        splitmuxsink "location=$dir/segment-%02d.mp4" max-size-time=2000000000 \
        >"$dir/split.log" 2>&1
    grep -q '^Got EOS' "$dir/split.log"
    mapfile -t opened < <(sed -nE '/splitmuxsink-fragment-opened/s/.*running-time=\(guint64\)([0-9]+).*/\1/p' "$dir/split.log")
    test "${opened[*]}" = "${expected[*]}"
    printf '\n%s GOP=%d 片段起点(ns) %s\n' "$codec" "$gop" "${opened[*]}"

    for part in "$dir"/segment-*.mp4; do
        gst-launch-1.0 -v filesrc "location=$part" ! qtdemux ! "${codec}parse" ! \
            "${parser_layout[@]}" ! identity name=coded silent=false ! "$decoder" ! \
            identity name=decoded silent=false ! fakesink sync=false >"${part%.mp4}.log" 2>&1
        grep -q '^Got EOS' "${part%.mp4}.log"
        first=$(grep -m 1 'GstIdentity:coded: last-message = chain' "${part%.mp4}.log")
        if [[ "$first" == *' delta-unit '* ]]; then
            printf '片段首个访问单元仍需参考帧 %s\n' "$part" >&2
            exit 1
        fi
        frames=$(sed -nE '/GstIdentity:decoded: last-message = chain/s/.*pts: ([^,]+),.*/\1/p' "${part%.mp4}.log" |
            sort -u | wc -l)
        test "$frames" -gt 0
        total=$((total + frames))
        bytes=$(wc -c <"$part")
        printf '%s 帧=%d 字节=%d 首个访问单元未标 DELTA_UNIT\n' "${part##*/}" "$frames" "$bytes"
    done
    test "$total" -eq 70
}
run_case h264 10
run_case h264 30
run_case h265 10
