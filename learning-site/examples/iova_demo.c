#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

enum { PAGE_SIZE = 0x1000 };

struct mapping {
    unsigned int iova;
    unsigned int physical;
    bool writable;
};

static void check_write(const char *label, const struct mapping *pages, size_t count,
                        unsigned int addr, unsigned int length)
{
    printf("%s\n", label);
    while (length > 0) {
        unsigned int offset = addr % PAGE_SIZE;
        size_t i = 0;

        /* 查页基址，再用相同页内偏移计算物理地址。 */
        while (i < count && pages[i].iova != addr - offset)
            i++;
        if (i == count) {
            printf("首个失败地址=0x%x（无映射）\n", addr);
            return;
        }
        if (!pages[i].writable) {
            printf("首个失败地址=0x%x（写权限缺失）\n", addr);
            return;
        }
        unsigned int segment = PAGE_SIZE - offset;
        if (segment > length)
            segment = length;
        printf("IOVA=0x%x 物理地址=0x%x 字节=0x%x\n",
               addr, pages[i].physical + offset, segment);
        addr += segment;
        length -= segment;
    }
    puts("整段可写");
}

int main(void)
{
    struct mapping pages[] = {
        { 0x10000, 0xa000, true },
        { 0x11000, 0x37000, true },
    };

    check_write("恰好到边界", pages, 2, 0x10ff0, 0x1010);
    check_write("多请求一个字节", pages, 2, 0x10ff0, 0x1011);
    pages[1].writable = false;
    check_write("第二页改成只读", pages, 2, 0x10ff0, 0x1010);
    return 0;
}
