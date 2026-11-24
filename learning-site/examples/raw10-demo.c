#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void pack(const uint16_t pixel[4], uint8_t bytes[5])
{
    bytes[4] = 0;
    for (unsigned int i = 0; i < 4; i++) {
        assert(pixel[i] <= 0x3ff);
        bytes[i] = (uint8_t)(pixel[i] >> 2);
        /* 第五字节中，像素 i 的低两位从第 2*i 位开始。 */
        bytes[4] |= (uint8_t)((pixel[i] & 3U) << (2 * i));
    }
}

static void unpack(const uint8_t bytes[5], uint16_t pixel[4])
{
    for (unsigned int i = 0; i < 4; i++)
        pixel[i] = (uint16_t)(((unsigned int)bytes[i] << 2) |
                             ((bytes[4] >> (2 * i)) & 3U));
}

int main(void)
{
    const uint16_t input[4] = { 0x000, 0x155, 0x2aa, 0x3ff };
    const uint8_t expected[5] = { 0x00, 0x55, 0xaa, 0xff, 0xe4 };
    uint8_t bytes[5];
    uint16_t output[4];

    pack(input, bytes);
    assert(memcmp(expected, bytes, sizeof(bytes)) == 0);
    printf("载荷");
    for (unsigned int i = 0; i < 5; i++)
        printf(" %02x", (unsigned int)bytes[i]);
    puts("");

    unpack(bytes, output);
    printf("解包");
    for (unsigned int i = 0; i < 4; i++) {
        assert(input[i] == output[i]);
        printf(" %03x", (unsigned int)output[i]);
    }
    puts("");
    printf("3864 像素的载荷=%d 字节\n", 3864 / 4 * 5);
    return 0;
}
