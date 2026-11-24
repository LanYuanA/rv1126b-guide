# 单个明确依赖的状态模型。完整内核还考虑 notifier 树、锁和回滚。
function advance(    matched) {
    matched = notifier && registered && waiting == advertised
    if (matched && !bound) {
        bound = 1
        print "  bound：接收端取得预期对象"
        print "  complete：模型中的唯一依赖已满足"
    }
}
function add_sensor(endpoint) {
    registered = 1
    advertised = endpoint
    print "  sensor 注册 " endpoint
    advance()
}
function add_notifier(endpoint) {
    notifier = 1
    waiting = endpoint
    print "  notifier 等待 " endpoint
    advance()
}
function reset(title) {
    registered = notifier = bound = 0
    print title
}
BEGIN {
    reset("sensor 先注册")
    add_sensor("endpoint-A")
    add_notifier("endpoint-A")
    if (!bound) exit 1

    reset("接收端先注册")
    add_notifier("endpoint-A")
    add_sensor("endpoint-A")
    if (!bound) exit 1

    reset("已登记的远端指错")
    add_notifier("endpoint-B")
    add_sensor("endpoint-A")
    if (bound) exit 1
    print "  仍在等待：检查活动树和匹配项"
}
