#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct v4l2_capability cap = {0};
	unsigned int flags;
	int fd, rc;

	if (argc != 2) {
		fprintf(stderr, "用法: %s /dev/videoN\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	do {
		rc = ioctl(fd, VIDIOC_QUERYCAP, &cap);
	} while (rc < 0 && errno == EINTR);
	if (rc < 0) {
		perror("VIDIOC_QUERYCAP");
		close(fd);
		return 1;
	}
	/* 有 DEVICE_CAPS 时，device_caps 描述当前节点。 */
	flags = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ?
		cap.device_caps : cap.capabilities;
	printf("driver=%s card=%s capture=%d mplane=%d streaming=%d\n",
	       cap.driver, cap.card, !!(flags & V4L2_CAP_VIDEO_CAPTURE),
	       !!(flags & V4L2_CAP_VIDEO_CAPTURE_MPLANE),
	       !!(flags & V4L2_CAP_STREAMING));
	return close(fd) < 0;
}
