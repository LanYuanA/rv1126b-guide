#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C GST_DEBUG_NO_COLOR=1

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo/output"
lab=$(mktemp -d "$repo/output/gst-motion.XXXXXX")
printf '日志与素材 %s\n' "$lab"
cc -std=gnu11 -Wall -Wextra -Werror "$repo/learning-site/examples/gst-motion-remux.c" \
    $("${gst_pc:-pkg-config}" --cflags --libs gstreamer-app-1.0) -o "$lab/remux"

gst-launch-1.0 -m -v videotestsrc num-buffers=60 pattern=ball ! \
    'video/x-raw,width=320,height=240,format=I420,framerate=10/1' ! tee name=source \
    source. ! queue ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=10 \
    option-string=min-keyint=10:scenecut=0:open-gop=0 ! h264parse config-interval=-1 ! \
    'video/x-h264,stream-format=byte-stream,alignment=au' ! identity name=access silent=false ! \
    multifilesink "location=$lab/au-%02d.h264" \
    source. ! queue ! jpegenc ! multifilesink "location=$lab/still-%02d.jpg" post-messages=true >"$lab/record.log" 2>&1
grep -q '^Got EOS' "$lab/record.log"

# 合成帧号在 10 fps 下就是源时间的一位小数。按编码器 PTS 去重，
# 用到达顺序给这里无 B 帧的访问单元编号，再找所请求窗口之前的最后一个关键帧。
shutter=32
before=22
after=42
awk '
    /GstIdentity:access: last-message = chain/ {
        pts=$0
        sub(/^.*pts: /, "", pts)
        sub(/,.*/, "", pts)
        if (seen[pts]++) next
        key = ($0 !~ / delta-unit /)
        print index_in_clip++, pts, key
    }
    END { if (index_in_clip != 60) exit 1 }
' "$lab/record.log" > "$lab/access.tsv"
start=$(awk -v before="$before" '$1 <= before && $3 { start=$1 } END { if (start == "") exit 1; print start }' "$lab/access.tsv")
test "$start" -eq 20
"$lab/remux" "$lab" "$lab/clip.mp4" "$start" "$after"
presentation_us=$(( (shutter - start) * 100000 ))
cover="$lab/still-$(printf '%02d' "$shutter").jpg"
grep -F "${cover##*/}, " "$lab/record.log" | grep -q 'timestamp=(guint64)3200000000,'
bytes=$(wc -c <"$lab/clip.mp4")

# 只接受此实验产生的 JFIF JPEG，把 XMP APP1 插在 APP0 后面。
test "$(od -An -tx1 -N4 "$cover" | tr -d ' \n')" = ffd8ffe0
read -r length_hi length_lo < <(od -An -tu1 -j4 -N2 "$cover")
app0_end=$(( 4 + length_hi * 256 + length_lo ))
printf 'http://ns.adobe.com/xap/1.0/\000' >"$lab/xmp.bin"
cat >>"$lab/xmp.bin" <<XMP
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:Camera="http://ns.google.com/photos/1.0/camera/"
 xmlns:Container="http://ns.google.com/photos/1.0/container/"
 xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
 Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1"
 Camera:MotionPhotoPresentationTimestampUs="$presentation_us">
<Container:Directory><rdf:Seq>
<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary"/></rdf:li>
<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="$bytes"/></rdf:li>
</rdf:Seq></Container:Directory>
</rdf:Description></rdf:RDF></x:xmpmeta>
XMP
app1_length=$(( $(wc -c <"$lab/xmp.bin") + 2 ))
test "$app1_length" -le 65535
photo="$lab/RV1126B_MP.jpg"
{
    head -c "$app0_end" "$cover"
    printf '\377\341'
    printf "\\$(printf '%03o' "$((app1_length / 256))")\\$(printf '%03o' "$((app1_length % 256))")"
    cat "$lab/xmp.bin"
    tail -c "+$((app0_end + 1))" "$cover"
    cat "$lab/clip.mp4"
} > "$photo"

declared=$(grep -ao 'Item:Length="[0-9]*"' "$photo" | cut -d'"' -f2)
video_offset=$(( $(wc -c <"$photo") - declared ))
test "$video_offset" -eq "$(( $(wc -c <"$cover") + app1_length + 2 ))"
test "$(head -c "$video_offset" "$photo" | tail -c 2 | od -An -tx1 | tr -d ' \n')" = ffd9
tail -c "$declared" "$photo" >"$lab/extracted.mp4"
cmp "$lab/clip.mp4" "$lab/extracted.mp4"

gst-launch-1.0 -q filesrc "location=$photo" ! jpegparse ! jpegdec ! fakesink >"$lab/photo.log" 2>&1
gst-launch-1.0 -v filesrc "location=$lab/extracted.mp4" ! qtdemux ! h264parse ! \
    'video/x-h264,stream-format=byte-stream,alignment=au' ! openh264dec ! \
    identity name=clip silent=false ! fakesink sync=false >"$lab/clip.log" 2>&1
count=$(sed -nE '/GstIdentity:clip: last-message = chain/s/.*pts: ([^,]+),.*/\1/p' "$lab/clip.log" | sort -u | wc -l)
test "$count" -eq "$((after - start + 1))"
grep -q '^Got EOS' "$lab/clip.log"
grep -q 'GstIdentity:clip: last-message = chain.*pts: 0:00:01.200000000,' "$lab/clip.log"
printf '帧窗 %d..%d，封面帧 %d，短片相对时刻 %d us，解码 %d 帧\n' \
    "$start" "$after" "$shutter" "$presentation_us" "$count"
printf 'JPEG EOI 后的 MP4 起点 %d，长度 %d，封面和视频已分别解码\n' "$video_offset" "$declared"
