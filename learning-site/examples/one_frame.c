/* 示例程序仅接受本板已知的 MPLANE / NV12 / 单内存平面布局。
 * 在已确认空闲的输出节点取一帧，可选保存紧排 NV12，退出即释放队列。
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

struct mapping {
	void *ptr;
	size_t size;
};

static int call(int fd, unsigned long request, void *arg)
{
	int rc;
	do {
		rc = ioctl(fd, request, arg);
	} while (rc < 0 && errno == EINTR);
	return rc;
}

static struct v4l2_buffer descriptor(unsigned int index, struct v4l2_plane *plane)
{
	return (struct v4l2_buffer) {
		.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
		.memory = V4L2_MEMORY_MMAP, .index = index,
		.length = 1, .m.planes = plane,
	};
}

static int64_t monotonic_ms(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
		return -1;
	return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int dequeue(int fd, struct v4l2_buffer *frame)
{
	const int64_t start = monotonic_ms();

	if (start < 0)
		return -1;
	const int64_t deadline = start + 3000;

	for (;;) {
		const int64_t now = monotonic_ms();
		struct pollfd pfd = { .fd = fd, .events = POLLIN };

		if (now < 0)
			return -1;
		if (now >= deadline) {
			errno = ETIMEDOUT;
			return -1;
		}
		int ready = poll(&pfd, 1, (int)(deadline - now));
		if (ready < 0 && errno == EINTR)
			continue;
		if (ready < 0)
			return -1;
		if (!ready) {
			errno = ETIMEDOUT;
			return -1;
		}
		if (!(pfd.revents & POLLIN)) {
			errno = EIO;
			return -1;
		}
		if (ioctl(fd, VIDIOC_DQBUF, frame) == 0)
			return 0;
		if (errno != EINTR && errno != EAGAIN)
			return -1;
	}
}

static int write_row(int fd, const unsigned char *data, size_t size)
{
	while (size) {
		ssize_t written = write(fd, data, size);

		if (written < 0 && errno == EINTR)
			continue;
		if (written == 0)
			errno = EIO;
		if (written <= 0)
			return -1;
		data += written;
		size -= (size_t)written;
	}
	return 0;
}

static int save_nv12(const char *path, const unsigned char *pixels,
		     size_t rows, size_t width, size_t stride)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	int saved_errno = 0;

	if (fd < 0)
		return -1;
	/* 单内存平面中 Y 与 UV 行连续存放，逐行去掉对齐填充。 */
	for (size_t row = 0; row < rows; row++) {
		if (write_row(fd, pixels + row * stride, width) < 0) {
			saved_errno = errno;
			break;
		}
	}
	if (close(fd) < 0 && !saved_errno)
		saved_errno = errno;
	if (saved_errno) {
		unlink(path);
		errno = saved_errno;
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_format fmt = { .type = type };
	struct v4l2_capability cap = {0};
	struct v4l2_requestbuffers req = { .type = type,
		.memory = V4L2_MEMORY_MMAP, .count = 3 };
	struct v4l2_plane plane = {0};
	struct v4l2_buffer frame = descriptor(0, &plane);
	struct mapping *maps = NULL;
	unsigned int mapped = 0;
	int fd, streaming = 0, result = 1;

	if (argc != 2 && argc != 3) {
		fprintf(stderr, "用法: %s /dev/videoN [新文件.nv12]\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	if (call(fd, VIDIOC_QUERYCAP, &cap) < 0) {
		perror("QUERYCAP");
		goto finish;
	}
	unsigned int caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ?
		cap.device_caps : cap.capabilities;
	if (!(caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE) || !(caps & V4L2_CAP_STREAMING)) {
		fprintf(stderr, "节点需要多平面采集和流式 I/O 能力\n");
		goto finish;
	}
	if (call(fd, VIDIOC_G_FMT, &fmt) < 0) {
		perror("G_FMT");
		goto finish;
	}
	if (fmt.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_NV12 ||
	    fmt.fmt.pix_mp.num_planes != 1) {
		fprintf(stderr, "本例需要 NV12 和一个内存平面\n");
		goto finish;
	}
	const uint32_t width = fmt.fmt.pix_mp.width;
	const uint32_t height = fmt.fmt.pix_mp.height;
	const uint32_t stride = fmt.fmt.pix_mp.plane_fmt[0].bytesperline;
	const uint64_t rows = (uint64_t)height + height / 2;

	/* payload 是 u32，先验证最后一行的末尾可用 u32 表示。 */
	if (!width || !height || width % 2 || height % 2 || stride < width ||
	    rows - 1 > (UINT32_MAX - width) / stride) {
		fprintf(stderr, "NV12 尺寸或步长无效\n");
		goto finish;
	}
	const uint32_t needed = (uint32_t)((rows - 1) * stride + width);
	if (fmt.fmt.pix_mp.plane_fmt[0].sizeimage < needed) {
		fprintf(stderr, "sizeimage 不足以容纳完整 NV12\n");
		goto finish;
	}
	if (call(fd, VIDIOC_REQBUFS, &req) < 0) {
		perror("REQBUFS");
		goto finish;
	}
	if (!req.count) {
		fprintf(stderr, "驱动未分配缓冲\n");
		goto finish;
	}
	maps = calloc(req.count, sizeof(*maps));
	if (!maps) {
		perror("calloc");
		goto finish;
	}
	for (unsigned int i = 0; i < req.count; i++) {
		struct v4l2_plane p = {0};
		struct v4l2_buffer b = descriptor(i, &p);

		if (call(fd, VIDIOC_QUERYBUF, &b) < 0) {
			perror("QUERYBUF");
			goto finish;
		}
		maps[i].size = p.length;
		maps[i].ptr = mmap(NULL, p.length, PROT_READ | PROT_WRITE,
				   MAP_SHARED, fd, p.m.mem_offset);
		if (maps[i].ptr == MAP_FAILED) {
			perror("mmap");
			goto finish;
		}
		mapped++;
		if (call(fd, VIDIOC_QBUF, &b) < 0) {
			perror("QBUF");
			goto finish;
		}
	}
	if (call(fd, VIDIOC_STREAMON, &type) < 0) {
		perror("STREAMON");
		goto finish;
	}
	streaming = 1;
	if (dequeue(fd, &frame) < 0) {
		perror("等待或 DQBUF");
		goto finish;
	}
	if (frame.index >= mapped || (frame.flags & V4L2_BUF_FLAG_ERROR) ||
	    plane.bytesused > maps[frame.index].size || plane.data_offset >= plane.bytesused ||
	    plane.bytesused - plane.data_offset < needed) {
		fprintf(stderr, "错误帧或有效范围越界\n");
		goto finish;
	}
	const unsigned char *pixels = (unsigned char *)maps[frame.index].ptr + plane.data_offset;
	if (argc == 3 && save_nv12(argv[2], pixels, (size_t)rows, width, stride) < 0) {
		perror("保存 NV12");
		goto finish;
	}
	printf("%ux%u stride=%u index=%u sequence=%u payload=%u first_Y=%u\n",
	       width, height, stride, frame.index, frame.sequence,
	       plane.bytesused - plane.data_offset, (unsigned int)pixels[0]);
	printf("timestamp=%lld.%06lld timestamp_type=0x%x timestamp_source=0x%x\n",
	       (long long)frame.timestamp.tv_sec, (long long)frame.timestamp.tv_usec,
	       frame.flags & V4L2_BUF_FLAG_TIMESTAMP_MASK, frame.flags & V4L2_BUF_FLAG_TSTAMP_SRC_MASK);
	result = 0;

finish:
	/* 单帧模式结束即停流，未出队的缓冲由 STREAMOFF 归还。 */
	if (streaming && call(fd, VIDIOC_STREAMOFF, &type) < 0) {
		perror("STREAMOFF");
		result = 1;
	}
	for (unsigned int i = 0; i < mapped; i++)
		munmap(maps[i].ptr, maps[i].size);
	free(maps);
	close(fd);
	return result;
}
