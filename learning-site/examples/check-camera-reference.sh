#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base="$root/atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal"
history="$root/output/camera-check"
dtb="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"

# 候选构建和原厂历史是两套证据，要分别标识。
printf '候选构建\n'
rg '^CONFIG_VIDEO_IMX415=[ym]$' "$base/.config"
sha256sum "$dtb"

printf '\n原厂历史\n'
rg -m1 -o 'Linux version [^ ]+' "$history/dmesg-before.log"
rg -m1 'imx415 3-001a: Detected imx415 id' "$history/dmesg-before.log"
frames=$(rg -c '^cap dqbuf:' "$history/capture.log")
bytes=$(wc -c <"$history/frame.nv12")
printf '出队记录=%s，单帧文件=%s 字节\n' "$frames" "$bytes"
printf '本案例紧排 NV12 预计=%d 字节\n' "$((3840 * 2160 * 3 / 2))"
printf '历史单帧 SHA-256\n'
sha256sum "$history/frame.nv12"
