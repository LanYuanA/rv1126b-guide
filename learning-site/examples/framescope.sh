#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

examples=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# != 2 ]]; then
    printf '用法：bash %s {replay|v4l2-log} 文件\n' "$0" >&2
    exit 2
fi
case $1 in
    replay) exec awk -f "$examples/framescope-replay.awk" < "$2" ;;
    v4l2-log)
        printf '来源 v4l2-ctl 仅有出队元数据，归还、调度、分配证据缺失\n'
        exec bash "$examples/frame-intervals.sh" --detailed "$2"
        ;;
    *) printf '未知模式 %s\n' "$1" >&2; exit 2 ;;
esac
