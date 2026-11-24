#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    printf '用法：sh %s sysfs 中的设备路径\n' "$0" >&2
    exit 2
fi

# 先解开总线索引，再读取实例上的关系链接。
device=$(readlink -f "$1")
printf '设备 -> %s\n' "$device"
for relation in subsystem driver of_node; do
    if [ -L "$device/$relation" ]; then
        printf '%s -> %s\n' "$relation" "$(readlink -f "$device/$relation")"
    else
        printf '%s 当前无链接\n' "$relation"
    fi
done
