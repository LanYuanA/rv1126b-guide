#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static struct rusage snapshot(void)
{
    struct rusage usage;

    if (getrusage(RUSAGE_SELF, &usage) == -1)
        fail("getrusage");
    return usage;
}

static void show_delta(const char *phase, struct rusage before, struct rusage after)
{
    printf("%s: minor=%ld major=%ld\n", phase,
           after.ru_minflt - before.ru_minflt,
           after.ru_majflt - before.ru_majflt);
}

static unsigned char *map_region(size_t length, int sharing)
{
    void *addr = mmap(NULL, length, PROT_READ | PROT_WRITE,
                      sharing | MAP_ANONYMOUS, -1, 0);

    if (addr == MAP_FAILED)
        fail("mmap");
    return addr;
}

static void check_first_touch(size_t page_size)
{
    const size_t length = 8U * 1024U * 1024U;
    struct rusage before = snapshot();
    volatile unsigned char *region = map_region(length, MAP_PRIVATE);
    struct rusage mapped = snapshot();

    /* 保留实际逐页写指令，便于观察两轮访问的缺页差异。 */
    for (size_t offset = 0; offset < length; offset += page_size)
        region[offset] = 'A';
    struct rusage first = snapshot();
    for (size_t offset = 0; offset < length; offset += page_size)
        region[offset] = 'B';
    struct rusage second = snapshot();

    printf("长度=%zu 步长=%zu\n", length, page_size);
    show_delta("映射阶段", before, mapped);
    show_delta("第一次写", mapped, first);
    show_delta("第二次写", first, second);
    if (munmap((void *)region, length) == -1)
        fail("munmap");
}

static void check_fork(size_t page_size)
{
    unsigned char *private = map_region(page_size, MAP_PRIVATE);
    unsigned char *shared = map_region(page_size, MAP_SHARED);

    private[0] = 'A';
    shared[0] = 'A';

    pid_t child = fork();
    if (child == -1)
        fail("fork");
    if (child == 0) {
        private[0] = 'B';
        shared[0] = 'B';
        _exit(0);
    }

    /* 子进程退出以后再读取，固定观测顺序。 */
    int status;
    if (waitpid(child, &status, 0) == -1)
        fail("waitpid");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fputs("子进程异常结束\n", stderr);
        exit(EXIT_FAILURE);
    }
    printf("父进程读回 private=%c shared=%c\n", private[0], shared[0]);
    if (munmap(private, page_size) == -1 || munmap(shared, page_size) == -1)
        fail("munmap");
}

int main(void)
{
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0)
        fail("sysconf");

    /* 在三个采样窗口开始前先调用一次计数接口。 */
    (void)snapshot();
    check_first_touch((size_t)page_size);
    check_fork((size_t)page_size);
    return EXIT_SUCCESS;
}
