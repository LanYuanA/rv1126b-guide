#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

int main(void)
{
    uint16_t reg = UINT16_C(0x1234);
    const unsigned char *host = (const unsigned char *)&reg;
    unsigned char wire[] = { reg >> 8, reg & UINT16_C(0xff) };
    unsigned char reply[] = { 0x01, 0x23 };

    /* 按协议把最高字节放到高位，结果与主机的字节排列无关。 */
    uint32_t value = ((uint32_t)reply[0] << 8) | reply[1];

    printf("host=%02x %02x wire=%02x %02x array=%zu bytes\n",
           (unsigned int)host[0], (unsigned int)host[1],
           (unsigned int)wire[0], (unsigned int)wire[1], sizeof(wire));
    printf("value=%" PRIu32 " low=0x%" PRIx32 "\n",
           value, value & UINT32_C(0xff));
}
