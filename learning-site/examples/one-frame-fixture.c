/* 只用于宿主测试，以链接器替换四个系统接口。模拟一帧带行填充的 NV12。 */
#include <errno.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/mman.h>

static unsigned char pixels[24] = {
    0xaa, 0xbb, 1, 2, 3, 4, 0xcc, 0xcc, 5, 6, 7, 8, 0xcc, 0xcc,
    9, 10, 11, 12, 0xcc, 0xcc
};
static int dequeues;
int __wrap_ioctl(int fd, unsigned long op, ...)
{
    (void)fd;
    va_list ap;
    va_start(ap, op);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    switch (op) {
    case VIDIOC_QUERYCAP: {
        struct v4l2_capability *cap = arg;
        cap->capabilities = V4L2_CAP_DEVICE_CAPS;
        cap->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
        return 0;
    }
    case VIDIOC_G_FMT: {
        struct v4l2_pix_format_mplane *p = &((struct v4l2_format *)arg)->fmt.pix_mp;
        p->pixelformat = V4L2_PIX_FMT_NV12;
        p->num_planes = 1;
        p->width = 4;
        p->height = 2;
        p->plane_fmt[0].bytesperline = 6;
        p->plane_fmt[0].sizeimage = 18;
        return 0;
    }
    case VIDIOC_REQBUFS:
        ((struct v4l2_requestbuffers *)arg)->count = 2;
        return 0;
    case VIDIOC_QUERYBUF:
        ((struct v4l2_buffer *)arg)->m.planes[0].length = sizeof(pixels);
        return 0;
    case VIDIOC_DQBUF: {
        if (!dequeues++) {
            errno = EAGAIN;
            return -1;
        }
        struct v4l2_buffer *b = arg;
        b->index = 0;
        b->sequence = 7;
        b->m.planes[0].data_offset = 2;
        b->m.planes[0].bytesused = getenv("SHORT_FRAME") ? 17 : 20;
        return 0;
    }
    case VIDIOC_QBUF: case VIDIOC_STREAMON: case VIDIOC_STREAMOFF:
        return 0;
    default:
        abort();
    }
}
int __wrap_poll(struct pollfd *fds, nfds_t count, int timeout)
{
    if (count != 1 || timeout <= 0 || timeout > 3000)
        abort();
    fds[0].revents = POLLIN;
    return 1;
}
void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
{
    (void)addr; (void)prot; (void)flags; (void)fd; (void)offset;
    if (len != sizeof(pixels))
        abort();
    return pixels;
}
int __wrap_munmap(void *addr, size_t len)
{
    if (addr != pixels || len != sizeof(pixels))
        abort();
    return 0;
}
