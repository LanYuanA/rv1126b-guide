#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static ssize_t show_read(const char *label, int fd)
{
    char buf[2];
    ssize_t n;

    do {
        n = read(fd, buf, sizeof(buf));
    } while (n == -1 && errno == EINTR);

    if (n == -1) {
        int saved = errno;
        printf("%s: -1, %s\n", label, saved == EAGAIN ? "EAGAIN" : "其他错误");
        if (saved != EAGAIN) {
            errno = saved;
            fail("read");
        }
    } else {
        printf("%s: %zd, %.*s\n", label, n, (int)n, buf);
    }
    return n;
}

int main(int argc, char **argv)
{
    if (argc != 3)
        return EXIT_FAILURE;

    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd == -1)
        fail("open sample");
    while (show_read("file", fd) > 0)
        ;
    if (close(fd) == -1)
        fail("close sample");

    fd = open(argv[2], O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        close(fd);
        fputs("expected path to be missing\n", stderr);
        return EXIT_FAILURE;
    }
    if (errno != ENOENT)
        fail("open missing");
    puts("open missing: -1, ENOENT");

    int ends[2];
    if (pipe2(ends, O_NONBLOCK | O_CLOEXEC) == -1)
        fail("pipe2");
    show_read("empty pipe with writer", ends[0]);

    int capacity = fcntl(ends[1], F_GETPIPE_SZ);
    if (capacity == -1)
        fail("F_GETPIPE_SZ");
    size_t requested = (size_t)capacity + 1;
    char *data = calloc(requested, 1);
    if (data == NULL)
        fail("calloc");
    ssize_t written = write(ends[1], data, requested);
    free(data);
    if (written == -1)
        fail("write pipe");
    printf("pipe write: 请求=%zu, 实际=%zd\n", requested, written);

    if (close(ends[1]) == -1)
        fail("close writer");
    char remaining[4096];
    ssize_t n;
    do {
        n = read(ends[0], remaining, sizeof(remaining));
    } while (n > 0 || (n == -1 && errno == EINTR));
    if (n == -1)
        fail("drain pipe");
    show_read("pipe drained without writer", ends[0]);
    return close(ends[0]) == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
