#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
sdk="$repo/atk_dlrv1126b_linux6.1_sdk"
kernel="$sdk/kernel-6.1"
base="$sdk/output/kernel-baseline"
cross="$sdk/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
export PATH="$base/host/usr/bin:$PATH"
export M4="$base/host/usr/bin/m4"
export BISON_PKGDATADIR="$base/host/usr/share/bison"
mkdir -p "$repo/output"
lab=$(mktemp -d "$repo/output/kconfig-compare.XXXXXX")
printf '构建目录 %s\n' "$lab"

prep() {
    local dir=$1
    mkdir -p "$dir"
    cp "$base/normal/.config" "$dir/.config"
}

kmake() {
    local dir=$1
    shift
    make -s -C "$kernel" "O=$dir" ARCH=arm64 "CROSS_COMPILE=$cross" "$@"
}

prep "$lab/baseline"
prep "$lab/no-proc-export"
prep "$lab/dependency-conflict"
"$kernel/scripts/config" --file "$lab/no-proc-export/.config" --disable IKCONFIG_PROC
"$kernel/scripts/config" --file "$lab/dependency-conflict/.config" --disable IKCONFIG --enable IKCONFIG_PROC
for name in baseline no-proc-export dependency-conflict; do
    kmake "$lab/$name" olddefconfig
    printf '\n%s 配置差分\n' "$name"
    "$kernel/scripts/diffconfig" "$base/normal/.config" "$lab/$name/.config"
done
grep -Fxq '# CONFIG_IKCONFIG_PROC is not set' "$lab/no-proc-export/.config"
grep -Fxq '# CONFIG_IKCONFIG is not set' "$lab/dependency-conflict/.config"
if grep -Fxq 'CONFIG_IKCONFIG_PROC=y' "$lab/dependency-conflict/.config"; then
    printf '父依赖关闭后仍启用了 proc 接口\n' >&2
    exit 1
fi

for name in baseline no-proc-export; do
    kmake "$lab/$name" kernel/configs.o
    printf '\n%s ARM64 配置对象的代码与数据段\n' "$name"
    "${cross}size" "$lab/$name/kernel/configs.o"
done
