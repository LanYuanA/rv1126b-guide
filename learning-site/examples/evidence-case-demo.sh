#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

examples=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$examples/../.." && pwd)
history=${1:-"$repo/output/camera-check"}

printf '\n== 原厂历史识别与短采集 ==\n'
grep -m 1 'imx415 3-001a: Detected imx415 id' "$history/dmesg-before.log" | tr -d '\r'
grep 'vblank need >= 1000us' "$history/dmesg-after.log" | tr -d '\r'
bash "$examples/frame-intervals.sh" --detailed "$history/capture.log"
printf '历史保存帧 %d bytes\n' "$(wc -c <"$history/frame.nv12")"

printf '\n== WSL 合成轨迹，验证规则 ==\n'
bash "$examples/framescope.sh" replay "$examples/framescope-replay.tsv"
