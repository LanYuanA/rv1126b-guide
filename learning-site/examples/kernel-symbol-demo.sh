#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
sdk="$repo/atk_dlrv1126b_linux6.1_sdk"
cross="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
vmlinux="${1:-$sdk/output/kernel-baseline/normal/vmlinux}"
export CROSS_COMPILE="$cross"

"${cross}readelf" -SW "$vmlinux" | grep -E '\.debug_(info|line)[[:space:]]'
"${cross}readelf" -n "$vmlinux" | awk '/Build ID:/ {print}'
"${cross}readelf" -sW "$vmlinux" | awk '$4 == "FUNC" && $8 == "meminfo_proc_show" {print "symbol size bytes", $3}'
resolved=$("$sdk/kernel-6.1/scripts/faddr2line" "$vmlinux" meminfo_proc_show+0x10 2>&1)
printf '%s\n' "$resolved"
grep -q 'fs/proc/meminfo.c:[0-9]' <<<"$resolved"
wrong=$("$sdk/kernel-6.1/scripts/faddr2line" "$vmlinux" meminfo_proc_show+0x10/0x1 2>&1)
printf '%s\n' "$wrong"
grep -Fq 'no match for meminfo_proc_show+0x10/0x1' <<<"$wrong"
