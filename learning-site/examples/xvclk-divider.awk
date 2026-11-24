# 只比较理想整数分频。父频和分频范围来自该候选的源码描述。
function report(request,    i, divisor, parent) {
    for (i = 1; i <= 2; i++) {
        parent = parents[i]
        for (divisor = 1; divisor <= 32; divisor++) {
            if (parent == request * divisor)
                printf "请求=%d Hz 父频=%d Hz 除数=%d\n", request, parent, divisor
        }
    }
}
BEGIN {
    parents[1] = 1188000000 / 2
    parents[2] = 24000000
    report(37125000)
    report(27000000)
}
