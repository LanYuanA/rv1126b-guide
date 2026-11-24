#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

examples=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$examples/../.." && pwd)
mkdir -p "$repo/output"
logs=$(mktemp -d "$repo/output/camera-regression.XXXXXX")
printf '回归索引 %s\n' "$logs"
for round in 1 2 3; do
    bash "$examples/gst-multistream-demo.sh" >"$logs/round-$round.log"
    sed -n 's/^日志与素材 //p' "$logs/round-$round.log" >>"$logs/artifacts.txt"
    grep -q 'JPEG image data' "$logs/round-$round.log"
    printf '第 %d 轮五组并发通过\n' "$round"
done
original=$(head -n 1 "$logs/artifacts.txt")
# 模拟应用意外中止留下只有头部的一份拷贝。
head -c 128 "$original/all/main.mkv" >"$logs/truncated.mkv"
if gst-launch-1.0 -m filesrc "location=$logs/truncated.mkv" ! matroskademux ! h264parse ! \
    'video/x-h264,stream-format=byte-stream,alignment=au' ! openh264dec ! fakesink \
    >"$logs/truncated.log" 2>&1; then
    printf '截断文件意外通过解码\n' >&2
    exit 1
fi
grep -m 1 '^ERROR:' "$logs/truncated.log"
bash "$examples/gst-multistream-demo.sh" >"$logs/recovery.log"
grep -q 'JPEG image data' "$logs/recovery.log"
printf '故障文件保持原样，新运行的五组回归通过\n'
