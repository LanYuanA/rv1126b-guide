#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if ! command -v gst-launch-1.0 >/dev/null; then
    printf '请先按站点的 WSL 宿主运行环境启用 gst-launch-1.0\n' >&2
    exit 1
fi
mkdir -p "$repo/output"
logs=$(mktemp -d "$repo/output/gst-state.XXXXXX")
printf '日志目录 %s\n' "$logs"
export LC_ALL=C
export GST_DEBUG_NO_COLOR=1
caps='video/x-raw,format=NV12,width=320,height=240,framerate=10/1'

gst-launch-1.0 -m videotestsrc num-buffers=5 ! "$caps" ! \
    fakesink sync=true >"$logs/sync.log" 2>&1
gst-launch-1.0 -m videotestsrc num-buffers=5 ! "$caps" ! \
    fakesink sync=false >"$logs/fast.log" 2>&1
gst-launch-1.0 -m videotestsrc is-live=true num-buffers=5 ! "$caps" ! \
    fakesink sync=true >"$logs/live.log" 2>&1
if gst-launch-1.0 -m filesrc location="$logs/missing.raw" ! \
    fakesink >"$logs/error.log" 2>&1; then
    printf '不存在的源文件本应触发 ERROR\n' >&2
    exit 1
fi

for mode in sync fast live; do
    printf '\n%s\n' "$mode"
    grep -E 'PREROLLED|does not need PREROLL|^Got EOS|^Execution ended' "$logs/$mode.log"
    grep -q '^Got EOS' "$logs/$mode.log"
done
grep -q 'does not need PREROLL' "$logs/live.log"
printf '\nerror\n'
grep -m 1 '^ERROR:' "$logs/error.log"
