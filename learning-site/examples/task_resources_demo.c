#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static void require(int ok, const char *message)
{
    if (!ok) {
        fprintf(stderr, "%s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void *close_from_thread(void *argument)
{
    int fd = *(const int *)argument;
    printf("工作线程: TGID=%ld TID=%ld\n", (long)getpid(), (long)gettid());
    require(close(fd) == 0, "工作线程关闭 fd 失败");
    return NULL;
}

static void observe_thread(void)
{
    pthread_t thread;
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    require(fd >= 0, "打开 /dev/null 失败");
    printf("主线程: TGID=%ld TID=%ld\n", (long)getpid(), (long)gettid());
    require(pthread_create(&thread, NULL, close_from_thread, &fd) == 0, "创建线程失败");
    require(pthread_join(thread, NULL) == 0, "等待工作线程失败");
    require(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "线程应共享同一 fd 槽位");
    puts("工作线程关闭共享 fd，主线程查该槽得到 EBADF");
}

static void observe_process(int keep_writer)
{
    int ends[2];
    require(pipe2(ends, O_NONBLOCK | O_CLOEXEC) == 0, "创建管道失败");
    pid_t child = fork();
    require(child >= 0, "fork 失败");
    if (child == 0) {
        if (close(ends[0]) == -1 || write(ends[1], "F", 1) != 1)
            _exit(1);
        _exit(0);
    }

    if (!keep_writer)
        require(close(ends[1]) == 0, "关闭父进程写端失败");

    // 确认子进程已经退出，保留它的退出状态供接下来的 waitpid 回收。
    siginfo_t exit_info = {0};
    require(waitid(P_PID, (id_t)child, &exit_info, WEXITED | WNOWAIT) == 0,
            "查询子进程退出状态失败");
    require(exit_info.si_code == CLD_EXITED && exit_info.si_status == 0,
            "子进程运行失败");

    char byte;
    require(read(ends[0], &byte, 1) == 1 && byte == 'F', "未读到子进程的标记");
    ssize_t n = read(ends[0], &byte, 1);
    if (keep_writer) {
        require(n == -1 && errno == EAGAIN, "父进程仍可写时应暂时无数据");
        puts("父进程保留写端，子进程已退出但未回收，读返回 EAGAIN");
        require(close(ends[1]) == 0, "关闭父进程写端失败");
    } else {
        require(n == 0, "无写端且数据读尽时应为 EOF");
        puts("父进程关闭写端，子进程已退出但未回收，读返回 EOF");
    }

    require(waitpid(child, NULL, 0) == child, "回收子进程失败");
    require(close(ends[0]) == 0, "关闭读端失败");
}

int main(void)
{
    observe_thread();
    observe_process(0);
    observe_process(1);
    return EXIT_SUCCESS;
}
