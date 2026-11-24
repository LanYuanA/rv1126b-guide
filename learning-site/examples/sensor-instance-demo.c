#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

struct subdev;

struct subdev_ops {
    void (*set_stream)(struct subdev *, bool);
};

struct subdev {
    const struct subdev_ops *ops;
};

struct sensor {
    const char *name;
    struct subdev subdev;
    bool streaming;
};

struct client {
    struct subdev *driver_data;
};

static struct sensor *sensor_from_subdev(struct subdev *sd)
{
    /* 与内核 container_of 相同的地址关系，属于宿主对象模型。 */
    return (struct sensor *)((char *)sd - offsetof(struct sensor, subdev));
}

static void set_stream(struct subdev *sd, bool on)
{
    struct sensor *sensor = sensor_from_subdev(sd);

    sensor->streaming = on;
    printf("%s: streaming=%d\n", sensor->name, (int)sensor->streaming);
}

int main(void)
{
    const struct subdev_ops ops = { .set_stream = set_stream };
    struct sensor first = { .name = "3-001a", .subdev = { .ops = &ops } };
    struct sensor second = { .name = "4-001a", .subdev = { .ops = &ops } };
    struct client a = { .driver_data = &first.subdev };
    struct client b = { .driver_data = &second.subdev };

    a.driver_data->ops->set_stream(a.driver_data, true);
    assert(first.streaming && !second.streaming);
    b.driver_data->ops->set_stream(b.driver_data, false);
    assert(first.streaming && !second.streaming);
    assert(sensor_from_subdev(a.driver_data) == &first);
    assert(sensor_from_subdev(b.driver_data) == &second);
    puts("共用回调表，实例状态独立");
    return 0;
}
