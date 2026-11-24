#include <stdio.h>

struct thermometer;

struct thermometer_ops {
    int (*read_c)(const struct thermometer *meter);
};

struct thermometer {
    const struct thermometer_ops *ops;
    int sample_c;
    int correction_c;
};

static int read_sample(const struct thermometer *meter)
{
    return meter->sample_c;
}

static int read_calibrated(const struct thermometer *meter)
{
    return meter->sample_c + meter->correction_c;
}

static const struct thermometer_ops raw_ops = {
    .read_c = read_sample,
};

static const struct thermometer_ops calibrated_ops = {
    .read_c = read_calibrated,
};

static void show_reading(const char *label, const struct thermometer *meter)
{
    /* 表决定调用哪个函数，实参决定这个函数读哪支温度计。 */
    printf("%s = %d °C\n", label, meter->ops->read_c(meter));
}

int main(void)
{
    struct thermometer a = { .ops = &raw_ops, .sample_c = 20, .correction_c = 2 };
    struct thermometer b = { .ops = &raw_ops, .sample_c = 27, .correction_c = 1 };
    struct thermometer *alias = &a;

    printf("A direct = %d °C\n", read_sample(&a));
    show_reading("A raw", &a);
    show_reading("B raw", &b);

    /* 单独切换 A 的表，观测同一个实例在另一种算法下的读数。 */
    a.ops = &calibrated_ops;
    show_reading("A calibrated", &a);

    /* 两个名字指向同一份数据，从 alias 写入后再经 &a 读取。 */
    alias->sample_c = 24;
    show_reading("A after alias", &a);
    show_reading("B unchanged", &b);
    return 0;
}
