#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
sdk=${1:-"$repo/atk_dlrv1126b_linux6.1_sdk"}
external="$sdk/external"
sample="$external/samples/simple_test/simple_vi_bind_vpss_bind_venc.c"
mpp="$external/mpp/test/mpi_enc_test.c"
rockit="$external/rockit/lib/arm64/rv1126b/linux/librockit.so"
export LC_ALL=C

printf '\n# SDK 样例的两个绑定和对应解绑\n'
awk '/s32Ret = RK_MPI_SYS_(Bind|UnBind)\(/ { print NR ":" $0; count++ }
     END { if (count != 4) exit 1 }' "$sample"

printf '\n# MPP 样例的编码入口与包管理\n'
grep -nE 'mpp_init\(.*MPP_CTX_ENC|mpi->encode_(put_frame|get_packet)|mpp_packet_deinit\(' "$mpp"

printf '\n# RV1126B 的 arm64 Rockit 动态库\n'
readelf -h "$rockit" | grep -E 'Class:|Machine:.*AArch64'
readelf -d "$rockit" | grep 'Shared library: \[librockchip_mpp.so.1\]'
readelf --dyn-syms --wide "$rockit" | awk '
    $7 != "UND" &&
    $8 ~ /^RK_MPI_(SYS_(Bind|UnBind)|VI_EnableChn|VPSS_StartGrp|VENC_(GetStream|ReleaseStream))$/ {
        print $8
        seen[$8]++
    }
    END {
        if (length(seen) != 6)
            exit 1
    }'
