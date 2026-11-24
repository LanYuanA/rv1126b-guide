#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || ( $1 != pinctrl && $1 != gpio ) ]]; then
    printf '用法：bash %s pinctrl|gpio\n' "$0" >&2
    exit 2
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base="$root/atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal"
dtb="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"

# 只读候选 DTB。此版 dtc 按深度缩进，借此限定各属性所属节点。
"$base/scripts/dtc/dtc" -q -I dtb -O dts "$dtb" |
    awk -v mode="$1" '
    /^\ti2c@21120000 \{/ { bus = 1 }
    /^\t};/ { bus = 0 }
    bus && /^\t\timx415_0@1a \{/ { sensor = 1 }
    /^\t\t};/ { sensor = 0 }
    /^\t\t\t(i2c3m[01]-pins|cam-clk0-pins) \{/ {
        group = $1
    }
    /^\t\t\t};/ { group = "" }
    /^\t\tgpio@21800000 \{/ { bank = 1 }
    /^\t\t};/ { bank = 0 }

    mode == "pinctrl" && (bus || sensor) && /pinctrl-(names|0) = / {
        important = (sensor && /^\t\t\tpinctrl-/) || (bus && /^\t\tpinctrl-/)
        if (important) {
            print (sensor ? "IMX415" : "I2C3"), $0
            found++
        }
    }
    mode == "pinctrl" && group && /rockchip,pins = |phandle = / {
        print group, $0
        found++
    }

    mode == "gpio" && bank && /^\t\t\tphandle = / {
        print "GPIO4", $0
        found++
    }
    mode == "gpio" && sensor && /^\t\t\t(reset|power)-gpios = / {
        print "IMX415", $0
        found++
    }
    END {
        if (found != (mode == "pinctrl" ? 10 : 3)) {
            print "候选 DTB 未找到完整的目标引用" > "/dev/stderr"
            exit 1
        }
    }'
