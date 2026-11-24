# 读取 media-ctl -p 的历史文本，仅比较指定媒体图中的 stream 0。
function report(src, sp, dst, dp,    a, b, link, state) {
    a = src ":" sp
    b = dst ":" dp
    link = a SUBSEP b
    if (!(link in links)) {
        print a " → " b " | 未找到链接"
        missing = 1
        return
    }
    if (formats[a] == "" || formats[b] == "")
        state = "一端或两端未记录 pad 格式"
    else if (formats[a] == formats[b])
        state = "码与尺寸一致"
    else
        state = "码或尺寸不同，核对活动格式"
    printf "%s → %s | %s | %s / %s | %s\n", a, b, links[link],
           formats[a] == "" ? "—" : formats[a],
           formats[b] == "" ? "—" : formats[b], state
}
{
    sub(/\r$/, "")
}
/^- entity [0-9]+:/ {
    entity = $0
    sub(/^- entity [0-9]+: /, "", entity)
    sub(/ \([^()]*\)$/, "", entity)
    pad = ""
    next
}
/^[[:space:]]+device node name / {
    devices[entity] = $NF
    next
}
/^[[:space:]]+pad[0-9]+:/ {
    pad = $1
    sub(/^pad/, "", pad)
    sub(/:$/, "", pad)
    next
}
/^[[:space:]]+\[stream:0 fmt:/ {
    format = $2
    sub(/^fmt:/, "", format)
    sub(/@.*/, "", format)
    formats[entity ":" pad] = format
    next
}
/^[[:space:]]+-> "/ {
    target = $0
    sub(/^[^"]*"/, "", target)
    sub(/\[.*$/, "", target)
    sub(/[[:space:]]+$/, "", target)
    sub(/":/, ":", target)
    flags = $0
    sub(/^.*\[/, "", flags)
    sub(/].*$/, "", flags)
    gsub(/[[:space:]]/, "", flags)
    links[(entity ":" pad) SUBSEP target] = flags ~ /(^|,)ENABLED(,|$)/ ? "启用" : "未启用"
}
END {
    report("rkcif-mipi-lvds", 0, "rkisp-isp-subdev", 0)
    report("rkisp-isp-subdev", 2, "rkisp_mainpath", 0)
    report("rkisp-input-params", 0, "rkisp-isp-subdev", 1)
    report("rkisp-isp-subdev", 3, "rkisp-statistics", 0)
    printf "mainpath 设备=%s\n", devices["rkisp_mainpath"]
    exit missing + 0
}
