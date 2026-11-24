#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
gstroot="$repo/output/textbook-check/gst"
if ! command -v gst-launch-1.0 >/dev/null && [[ -x "$gstroot/usr/bin/gst-launch-1.0" ]]; then
    export PATH="$gstroot/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$gstroot/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export GST_PLUGIN_PATH="$gstroot/usr/lib/x86_64-linux-gnu/gstreamer-1.0${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
    export GST_REGISTRY="$gstroot/registry.bin"
fi

for element in videotestsrc capsfilter videoconvert fakesink; do
    gst-inspect-1.0 "$element" >/dev/null
done
mkdir -p "$repo/output"
logs=$(mktemp -d "$repo/output/gst-caps.XXXXXX")
printf '日志目录 %s\n' "$logs"
export LC_ALL=C
export GST_DEBUG_NO_COLOR=1

rgb='video/x-raw,format=RGB,width=320,height=240,framerate=30/1'
nv12='video/x-raw,format=NV12,width=320,height=240,framerate=30/1'

gst-launch-1.0 -v videotestsrc num-buffers=3 ! "$rgb" ! fakesink sync=false \
    >"$logs/rgb.log" 2>&1
if gst-launch-1.0 -v videotestsrc num-buffers=3 ! \
    capsfilter name=left caps="$rgb" ! capsfilter name=right caps="$nv12" ! \
    fakesink sync=false >"$logs/conflict.log" 2>&1; then
    printf 'RGB 与 NV12 直接相连本应失败\n' >&2
    exit 1
fi
gst-launch-1.0 -v videotestsrc num-buffers=3 ! "$rgb" ! \
    videoconvert name=convert ! "$nv12" ! fakesink sync=false \
    >"$logs/converted.log" 2>&1

grep -E 'GstFakeSink.*caps = .*format=\(string\)RGB|Got EOS' "$logs/rgb.log"
grep -E 'could not link|not-negotiated' "$logs/conflict.log"
grep -E 'convert.GstPad.sink.*format=\(string\)RGB' "$logs/converted.log"
grep -E 'convert.GstPad.src.*format=\(string\)NV12' "$logs/converted.log"
grep -E 'Got EOS' "$logs/converted.log"
