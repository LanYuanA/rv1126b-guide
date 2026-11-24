#include <stdbool.h>
#include <stdio.h>

/* 只模拟正文列出的分支，不模拟驱动核心的并发与重试。 */
enum outcome { NO_MATCH, DEFER, INVALID, NO_DEVICE, BOUND };

static void trace(const char *name, bool match, bool supplier_ready,
                  enum outcome clock, enum outcome supply, enum outcome read_id)
{
    const char *stage = "match";
    enum outcome result = NO_MATCH;

    if (match) {
        stage = "core supplier check";
        result = DEFER;
        if (supplier_ready) {
            stage = "sensor xvclk";
            result = INVALID;
            if (clock == BOUND) {
                stage = "sensor regulators";
                result = supply;
                if (supply == BOUND) {
                    stage = "sensor read ID";
                    result = read_id;
                }
            }
        }
    }
    const char *const states[] = {
        "无匹配", "EPROBE_DEFER", "EINVAL", "ENODEV", "可以继续尝试登记"
    };
    printf("%s: %s -> %s\n", name, stage, states[result]);
}

int main(void)
{
    trace("无匹配", false, true, BOUND, BOUND, BOUND);
    trace("核心等待供应者", true, false, BOUND, BOUND, BOUND);
    trace("时钟暂不可用", true, true, DEFER, BOUND, BOUND);
    trace("电源暂不可用", true, true, BOUND, DEFER, BOUND);
    trace("读 ID 不符", true, true, BOUND, BOUND, NO_DEVICE);
    return 0;
}
