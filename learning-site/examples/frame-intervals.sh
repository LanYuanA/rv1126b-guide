#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

detailed=false
if [[ ${1:-} == --detailed ]]; then
    detailed=true
    shift
fi
if [[ $# != 1 ]]; then
    printf '用法：bash %s [--detailed] 同一次采集日志\n' "$0" >&2
    exit 2
fi

intervals=$(mktemp)
trap 'rm -f -- "$intervals"' EXIT

# 仅处理同一采集会话的单调时钟 EOF 记录，异常数据显式拒绝。
awk -v intervals="$intervals" '
/^cap dqbuf:/ {
    seq = ""; ts = ""
    for (i = 1; i < NF; i++) {
        if ($i == "seq:") seq = $(i + 1)
        if ($i == "ts:") ts = $(i + 1)
    }
    if (seq !~ /^[0-9]+$/ || ts !~ /^[0-9]+[.][0-9]+$/ ||
        $0 !~ /[(]ts-monotonic, ts-src-eof[)]/ ||
        (n && (seq + 0 <= prev_seq || ts + 0 <= prev_ts))) {
        print "记录格式、时钟或采集会话不一致，行号 " NR > "/dev/stderr"
        invalid = 1
        exit 2
    }

    if (!n) first_ts = ts + 0
    else {
        printf "%.3f\n", 1000 * (ts - prev_ts) > intervals
        gaps += seq - prev_seq - 1
    }
    n++
    prev_seq = seq + 0
    prev_ts = ts + 0
}
END {
    if (invalid) exit 2
    if (n < 2) {
        print "至少需要两条出队记录" > "/dev/stderr"
        exit 2
    }
    printf "帧数=%d 序号缺口=%d 观测速率=%.3f fps\n",
           n, gaps, (n - 1) / (prev_ts - first_ts)
}
' "$1"

count=$(wc -l < "$intervals")
rank=$(( (95 * count + 99) / 100 ))
sort -n "$intervals" | awk -v count="$count" -v rank="$rank" -v detailed="$detailed" '
NR == rank { print "间隔 P95=" $0 " ms" }
NR == int((99 * count + 99) / 100) { p99 = $0 }
NR == count && detailed == "true" {
    printf "间隔数=%d P99=%s ms 最大=%s ms\n", count, p99, $0
}'
