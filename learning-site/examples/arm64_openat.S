    .text
    .global _start
_start:
    // 从当前工作目录找 sample，ABI 约定见本节正文。
    mov x0, #-100
    adr x1, path
    mov x2, #0
    mov x3, #0
    mov x8, #56
    svc #0

    // 这个示例只用退出状态表达原始返回值是否为负。
    cmp x0, #0
    cset w0, lt
    mov x8, #93
    svc #0

    .section .rodata
path:
    .asciz "sample"
    .section .note.GNU-stack,"",%progbits
