#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo/output"
lab=$(mktemp -d "$repo/output/proc-snapshot.XXXXXX")
printf '快照目录 %s\n' "$lab"

snapshot() {
    local prefix=$1
    cat /proc/uptime >"$lab/$prefix.uptime"
    cat /proc/stat >"$lab/$prefix.stat"
    cat /proc/meminfo >"$lab/$prefix.meminfo"
    cat /proc/sys/kernel/random/boot_id >"$lab/$prefix.boot-id"
    cat /sys/devices/system/cpu/online >"$lab/$prefix.online"
}
snapshot before
sleep 1
snapshot after
if ! cmp -s "$lab/before.boot-id" "$lab/after.boot-id" ||
   ! cmp -s "$lab/before.online" "$lab/after.online"; then
    printf '内核启动代次或在线 CPU 发生变化，重新采样\n' >&2
    exit 1
fi

awk '
$1 == "cpu" {
    if (NF < 9) { invalid=1; exit 2 }
    n++
    for (i=2; i<=9; i++) {
        if ($i !~ /^[0-9]+$/) { invalid=1; exit 2 }
        delta[i] += n==1 ? -$i : $i
    }
}
END {
    if (invalid || n != 2) exit 2
    for (i=2; i<=9; i++) {
        if (delta[i] < 0) {
            print "CPU 计数倒退，当前窗口无效" > "/dev/stderr"
            exit 2
        }
        total += delta[i]
    }
    if (total <= 0) exit 2
    busy = delta[2] + delta[3] + delta[4] + delta[7] + delta[8]
    printf "CPU 差分 ticks=%d 执行=%.2f%% idle=%.2f%% iowait=%.2f%% steal=%.2f%%\n",
           total, 100*busy/total, 100*delta[5]/total, 100*delta[6]/total, 100*delta[9]/total
}' "$lab/before.stat" "$lab/after.stat"

awk '
$1 == "MemAvailable:" && $3 == "kB" { printf "MemAvailable %.2f MiB\n", $2/1024 }
$1 == "CmaTotal:" && $3 == "kB" { cma=1; printf "CmaTotal %.2f MiB\n", $2/1024 }
$1 == "CmaFree:" && $3 == "kB" { printf "CmaFree %.2f MiB\n", $2/1024 }
END { if (!cma) print "CMA 指标缺失" }
' "$lab/after.meminfo"
printf 'CPU online %s，USER_HZ %s\n' "$(cat "$lab/after.online")" "$(getconf CLK_TCK)"
for path in /sys/kernel/debug /sys/kernel/tracing; do
    if [[ -x "$path" && -r "$path" ]]; then
        printf '当前用户可访问 %s\n' "$path"
    else
        printf '当前用户不可访问或接口缺失 %s\n' "$path"
    fi
done
