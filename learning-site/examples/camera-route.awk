# 输入为本地 dtc 的 DTS 输出，只核对候选中的四对固件端点。
BEGIN {
    nodes[0] = ""
    left[0] = "imx415_out0"; right[0] = "csi_dphy_input0"
    left[1] = "csidphy0_out"; right[1] = "mipi0_csi2_input"
    left[2] = "mipi0_csi2_output"; right[2] = "cif_mipi_in0"
    left[3] = "mipi_lvds_sditf"; right[3] = "isp_vir0"
}
{
    match($0, /^\t*/)
    depth = RLENGTH
    if (depth && NF == 2 && $2 == "{") {
        nodes[depth] = nodes[depth - 1] "/" $1
        next
    }
    if (depth && $2 == "=") {
        path = nodes[depth - 1]
        val = $3
        if (path == "/__symbols__") {
            gsub(/[";]/, "", val)
            symbols[$1] = val
        } else if ($1 == "phandle" || $1 == "remote-endpoint") {
            gsub(/[<>;]/, "", val)
            if ($1 == "phandle")
                handles[path] = val
            else
                remote[path] = val
        }
    }
}
END {
    for (i = 0; i < 4; i++) {
        a = symbols[left[i]]
        b = symbols[right[i]]
        ok = (a != "" && b != "" && handles[a] != "" && handles[b] != "" &&
              remote[a] == handles[b] && remote[b] == handles[a])
        printf "%s ↔ %s: %s\n", left[i], right[i], ok ? "双向一致" : "缺失或不一致"
        if (!ok)
            failed = 1
    }
    exit failed + 0
}
