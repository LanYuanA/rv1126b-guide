#define _XOPEN_SOURCE 700
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

static pthread_barrier_t after_read;
static atomic_int split_counter;
static atomic_int rmw_counter;

static void check(int ok)
{
    if (!ok)
        exit(EXIT_FAILURE);
}

static void *increment(void *unused)
{
    (void)unused;
    int before = atomic_load(&split_counter);

    // 确保两个线程都读完才开始写，稳定复现更新被覆盖。
    int rc = pthread_barrier_wait(&after_read);
    check(rc == 0 || rc == PTHREAD_BARRIER_SERIAL_THREAD);
    atomic_store(&split_counter, before + 1);
    atomic_fetch_add(&rmw_counter, 1);
    return NULL;
}

int main(void)
{
    pthread_t workers[2];
    check(pthread_barrier_init(&after_read, NULL, 2) == 0);
    for (size_t i = 0; i < 2; ++i)
        check(pthread_create(&workers[i], NULL, increment, NULL) == 0);
    for (size_t i = 0; i < 2; ++i)
        check(pthread_join(workers[i], NULL) == 0);

    int split = atomic_load(&split_counter);
    int rmw = atomic_load(&rmw_counter);
    printf("分开的原子读和写：%d\n一次原子读改写：%d\n", split, rmw);
    check(pthread_barrier_destroy(&after_read) == 0);
    return split == 1 && rmw == 2 ? EXIT_SUCCESS : EXIT_FAILURE;
}
