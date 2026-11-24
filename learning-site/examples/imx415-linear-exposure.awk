# 用线性模式的有效高度和固定曝光行数演算，未写寄存器。
function report(vblank,    vts, limit, shr0) {
    vts = 2192 + vblank
    limit = vts - 8
    shr0 = vts - 1000
    printf "VBLANK=%d VTS=%d 曝光上限=%d SHR0=%d (0x%04x) 字节=%02x %02x %02x\n",
           vblank, vts, limit, shr0, shr0, shr0 % 256, int(shr0 / 256) % 256,
           int(shr0 / 65536)
}
BEGIN {
    report(58)
    report(100)
}
