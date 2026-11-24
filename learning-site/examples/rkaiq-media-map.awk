# 输入为一份 media-ctl -p 快照。只从实体标题提取节点，排除 link 中的名字。
/^- entity [0-9]+:/ {
    entity = $4
}
$1 == "device" && $2 == "node" && $3 == "name" {
    if (entity == "rkisp-isp-subdev" || entity == "rkisp_mainpath" ||
        entity == "rkisp-input-params" || entity == "rkisp-statistics") {
        node = $4
        sub(/\r$/, "", node)
        nodes[entity] = node
    }
}
END {
    names[1] = "rkisp-isp-subdev"
    names[2] = "rkisp_mainpath"
    names[3] = "rkisp-statistics"
    names[4] = "rkisp-input-params"
    roles[1] = "ISP 子设备"
    roles[2] = "图像输出"
    roles[3] = "统计元数据输出到用户态"
    roles[4] = "参数元数据输入到 ISP"
    for (i = 1; i <= 4; i++) {
        name = names[i]
        if (!(name in nodes)) {
            printf "未找到实体节点 %s\n", name > "/dev/stderr"
            missing = 1
            continue
        }
        printf "%s\t%s\t%s\n", name, nodes[name], roles[i]
    }
    exit missing
}
