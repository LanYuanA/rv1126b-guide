#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char directory[] = "./.unlink-demo.XXXXXX";
static int dirfd = -1;

static void cleanup(void)
{
    if (dirfd >= 0) {
        /* 异常退出时也只处理本次创建的两个名字。 */
        unlinkat(dirfd, "clip", 0);
        unlinkat(dirfd, "second", 0);
        close(dirfd);
    }
    rmdir(directory);
}

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static void require(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void show_stat(const char *stage, int fd, nlink_t links)
{
    struct stat st;

    if (fstat(fd, &st) == -1)
        fail("fstat");
    printf("%s: dev=%ju inode=%ju nlink=%ju\n", stage, (uintmax_t)st.st_dev,
           (uintmax_t)st.st_ino, (uintmax_t)st.st_nlink);
    require(st.st_nlink == links, "硬链接数与本次操作不符");
}

static void require_missing(const char *name)
{
    struct stat st;
    int result = fstatat(dirfd, name, &st, 0);

    require(result == -1 && errno == ENOENT, "旧路径应该返回 ENOENT");
    printf("%s: ENOENT\n", name);
}

int main(void)
{
    const char payload[] = "frame";
    char buffer[sizeof(payload)] = { 0 };

    if (mkdtemp(directory) == NULL)
        fail("mkdtemp");
    if (atexit(cleanup) != 0) {
        rmdir(directory);
        require(0, "无法注册清理函数");
    }
    dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd == -1)
        fail("open directory");
    int fd = openat(dirfd, "clip", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (fd == -1)
        fail("openat clip");
    require(write(fd, payload, sizeof(payload) - 1) == (ssize_t)sizeof(payload) - 1,
            "写入实验数据失败");
    if (linkat(dirfd, "clip", dirfd, "second", 0) == -1)
        fail("linkat");
    show_stat("保留两个名字", fd, 2);

    if (unlinkat(dirfd, "clip", 0) == -1)
        fail("unlinkat clip");
    require_missing("clip");
    show_stat("保留第二个名字", fd, 1);

    struct stat opened;
    struct stat remaining;
    if (fstat(fd, &opened) == -1 || fstatat(dirfd, "second", &remaining, 0) == -1)
        fail("stat second");
    require(opened.st_dev == remaining.st_dev && opened.st_ino == remaining.st_ino,
            "第二个名字应指向同一文件");

    if (unlinkat(dirfd, "second", 0) == -1)
        fail("unlinkat second");
    require_missing("second");
    show_stat("两个名字均已移除", fd, 0);
    require(pread(fd, buffer, sizeof(payload) - 1, 0) == (ssize_t)sizeof(payload) - 1 &&
            memcmp(buffer, payload, sizeof(payload) - 1) == 0,
            "已打开的描述符应可读回原字节");
    printf("pread: %s\n", buffer);
    if (close(fd) == -1)
        fail("close");
    return EXIT_SUCCESS;
}
