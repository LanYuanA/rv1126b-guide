#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static void check(int ok, const char *message)
{
    if (!ok) {
        fprintf(stderr, "%s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void check_pipe(void)
{
    int ends[2];
    char byte;
    check(pipe2(ends, O_NONBLOCK | O_CLOEXEC) == 0, "创建管道失败");

    struct pollfd event = { .fd = ends[0], .events = POLLIN };
    check(poll(&event, 1, 0) == 0, "空管道应暂无数据");
    check(write(ends[1], "X", 1) == 1, "写入标记失败");
    check(poll(&event, 1, 0) == 1 && (event.revents & POLLIN),
          "写入标记后应可读");

    // 用一次读取模拟另一消费者在轮询返回后先取到数据。
    check(read(ends[0], &byte, 1) == 1 && byte == 'X', "读取标记失败");
    ssize_t n = read(ends[0], &byte, 1);
    check(n == -1 && errno == EAGAIN, "数据被取走后应返回 EAGAIN");
    puts("poll 报可读，另一次读取取走 X，原读者得到 EAGAIN");

    check(close(ends[1]) == 0, "关闭写端失败");
    check(read(ends[0], &byte, 1) == 0, "管道读尽且无写端时应为 EOF");
    puts("最后一个写端关闭，读返回 0");
    check(close(ends[0]) == 0, "关闭读端失败");
}

static void check_mapping(void)
{
    long page_size = sysconf(_SC_PAGESIZE);
    check(page_size > 0, "读取页大小失败");
    size_t length = (size_t)page_size;
    int fd = memfd_create("映射示例", MFD_CLOEXEC);
    check(fd >= 0 && ftruncate(fd, page_size) == 0, "准备内存文件失败");
    char *mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    check(mapping != MAP_FAILED, "建立映射失败");

    // 映射有自己的引用，关闭创建它时使用的 fd 后仍可读写本例的内存文件。
    check(close(fd) == 0, "关闭内存文件失败");
    mapping[0] = 'M';
    printf("关闭 fd 后，映射仍可读写: %c\n", mapping[0]);
    check(munmap(mapping, length) == 0, "清理映射失败");
}

int main(void)
{
    check_pipe();
    check_mapping();
    return EXIT_SUCCESS;
}
