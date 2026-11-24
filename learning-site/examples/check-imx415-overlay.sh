#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base=${1:-"$root/atk_dlrv1126b_linux6.1_sdk/output/kernel-baseline/normal"}
tools="$base/scripts/dtc"
src="$base/arch/arm64/boot/dts/rockchip/rv1126b-alientek-mipi720x1280.dtb"

mkdir -p "$root/output"
lab=$(mktemp -d "$root/output/imx415-overlay.XXXXXX")
printf '离线产物：%s\n' "$lab"
"$tools/dtc" -I dtb -O dts -o "$lab/before.dts" "$src" 2>"$lab/before-warnings.log"
"$tools/dtc" -@ -I dts -O dtb -o "$lab/disable.dtbo" "$root/learning-site/examples/disable-imx415-overlay.dts"
"$tools/fdtoverlay" -i "$src" -o "$lab/after.dtb" "$lab/disable.dtbo"
"$tools/dtc" -I dtb -O dts -o "$lab/after.dts" "$lab/after.dtb" 2>"$lab/after-warnings.log"

# 用同一 dtc 的输出约定生成预期文本，检查是否只有目标节点新增属性。
awk '
    /^\ti2c@21120000 \{/ { target_bus = 1 }
    /^\t};/ { target_bus = 0 }
    { print }
    target_bus && /^\t\timx415_0@1a \{/ {
        print "\t\t\tstatus = \"disabled\";"
        count++
    }
    END { if (count != 1) exit 1 }
' "$lab/before.dts" >"$lab/expected.dts"
diff -u "$lab/expected.dts" "$lab/after.dts"
diff -u "$lab/before.dts" "$lab/after.dts" || test "$?" -eq 1
