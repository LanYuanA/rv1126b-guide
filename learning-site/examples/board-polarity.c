#include <stdbool.h>
#include <stdio.h>

struct board_led {
    const char *revision;
    unsigned int line;
    bool active_low;
};

static void show_levels(const struct board_led *led)
{
    /* 驱动只请求逻辑开关，板级配置决定物理电平。 */
    printf("%s line=%u active_low=%u on=%u off=%u\n", led->revision,
           led->line, (unsigned int)led->active_low,
           (unsigned int)!led->active_low, (unsigned int)led->active_low);
}

int main(void)
{
    const struct board_led a = { "A", 4, false };
    const struct board_led b = { "B", 7, true };

    show_levels(&a);
    show_levels(&b);
    return 0;
}
