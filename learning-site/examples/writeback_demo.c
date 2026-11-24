#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static char directory[] = "./.writeback-demo.XXXXXX";
static int dirfd = -1;
static unsigned char payload[4U * 1024U * 1024U];

static void cleanup(void)
{
    if (dirfd >= 0) {
        /* 只清理该次运行创建的名字。 */
        unlinkat(dirfd, "clip.part", 0);
        unlinkat(dirfd, "clip.bin", 0);
        close(dirfd);
    }
    rmdir(directory);
}

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static struct timespec now(void)
{
    struct timespec value;

    if (clock_gettime(CLOCK_MONOTONIC, &value) == -1)
        fail("clock_gettime");
    return value;
}

static double ms_between(struct timespec start, struct timespec end)
{
    return (end.tv_sec - start.tv_sec) * 1000.0 +
           (end.tv_nsec - start.tv_nsec) / 1000000.0;
}

static void write_all(int fd)
{
    size_t offset = 0;

    /* write 可能短写，只有已接受的字节才计入进度。 */
    while (offset < sizeof(payload)) {
        ssize_t count = write(fd, payload + offset, sizeof(payload) - offset);
        if (count < 0 && errno == EINTR)
            continue;
        if (count == 0)
            errno = EIO;
        if (count <= 0)
            fail("write");
        offset += (size_t)count;
    }
}

int main(void)
{
    if (mkdtemp(directory) == NULL)
        fail("mkdtemp");
    if (atexit(cleanup) != 0) {
        rmdir(directory);
        fputs("无法注册清理函数\n", stderr);
        return EXIT_FAILURE;
    }
    dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd == -1)
        fail("open directory");
    int fd = openat(dirfd, "clip.part", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd == -1)
        fail("openat");

    /* 先准备用户缓冲，把用户空间的首次触页移到计时窗外。 */
    for (size_t i = 0; i < sizeof(payload); i++)
        payload[i] = (unsigned char)(i * 31U);
    struct timespec start = now();
    write_all(fd);
    struct timespec written = now();
    if (fsync(fd) == -1)
        fail("fsync file");
    struct timespec synced = now();
    if (close(fd) == -1)
        fail("close");
    if (renameat(dirfd, "clip.part", dirfd, "clip.bin") == -1)
        fail("renameat");

    struct timespec renamed = now();
    if (fsync(dirfd) == -1)
        fail("fsync directory");
    struct timespec dir_synced = now();
    struct stat st;
    if (fstatat(dirfd, "clip.bin", &st, 0) == -1)
        fail("fstatat");
    if (st.st_size != (off_t)sizeof(payload)) {
        fputs("改名后的文件长度不匹配\n", stderr);
        return EXIT_FAILURE;
    }
    printf("写入=%zu 字节, write=%.3f ms, 文件 fsync=%.3f ms, 目录 fsync=%.3f ms\n",
           sizeof(payload), ms_between(start, written),
           ms_between(written, synced), ms_between(renamed, dir_synced));
    puts("最终名字与长度已核对");
    return EXIT_SUCCESS;
}
