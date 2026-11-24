#include <errno.h>
#include <inttypes.h>
#include <linux/i2c.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* 使用 WSL 的 I2C 消息类型。回包和传输返回值由调用者给定，整个实验在内存中进行。 */
static int model_read(uint16_t addr, uint16_t reg, const uint8_t *reply,
                      unsigned int len, int transfer_ret, uint32_t *value)
{
    uint8_t reg_bytes[] = { (uint8_t)(reg >> 8), (uint8_t)reg };
    uint8_t data[4] = { 0 };

    if (len == 0 || len > sizeof(data))
        return -EINVAL;

    struct i2c_msg msgs[] = {
        { .addr = addr, .flags = 0, .len = sizeof(reg_bytes), .buf = reg_bytes },
        { .addr = addr, .flags = I2C_M_RD, .len = len, .buf = data + sizeof(data) - len },
    };

    printf("W@%02x [%02x %02x] + R@%02x [%u byte(s)], ret=%d\n",
           msgs[0].addr, msgs[0].buf[0], msgs[0].buf[1],
           msgs[1].addr, msgs[1].len, transfer_ret);
    if (transfer_ret != 2)
        return -EIO;

    /* 只有两条消息都完成才交付结果。按大端字节顺序复原数值，与宿主端序无关。 */
    memcpy(msgs[1].buf, reply, msgs[1].len);
    *value = 0;
    for (size_t i = 0; i < sizeof(data); ++i)
        *value = (*value << 8) | data[i];
    return 0;
}

static void show_case(const char *label, const uint8_t *reply,
                      unsigned int len, int transfer_ret)
{
    /* 哨兵值帮助观察失败路径上输出参数是否被改写。 */
    uint32_t value = UINT32_C(0xdeadbeef);
    printf("%s\n", label);
    int status = model_read(0x1a, 0x311a, reply, len, transfer_ret, &value);
    printf("helper=%d value=%08" PRIx32 "\n", status, value);
}

int main(void)
{
    const uint8_t id[] = { 0xe0 };
    const uint8_t pair[] = { 0x12, 0x34 };
    show_case("ID", id, 1, 2);
    show_case("two bytes", pair, 2, 2);
    show_case("one message completed", id, 1, 1);
    show_case("timeout", id, 1, -ETIMEDOUT);
    show_case("invalid length", id, 0, 2);
    return 0;
}
