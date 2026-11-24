/* 两种运行都约 400 ms，便于区分占用 CPU 和等待。 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int64_t now_ns(clockid_t clock)
{
	struct timespec now;

	if (clock_gettime(clock, &now) < 0)
		return -1;
	return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

__attribute__((noinline))
static uint64_t compute_batch(uint64_t value)
{
	for (int i = 0; i < 100000; i++)
		value = value * UINT64_C(6364136223846793005) + (value >> 8) + 1;
	return value;
}

int main(int argc, char **argv)
{
	const int64_t duration = 400000000;
	uint64_t result = 1;
	int64_t start, cpu_start, end, cpu_end;

	if (argc != 2 || (strcmp(argv[1], "cpu") && strcmp(argv[1], "wait"))) {
		fprintf(stderr, "用法：%s cpu|wait\n", argv[0]);
		return 2;
	}
	start = now_ns(CLOCK_MONOTONIC);
	cpu_start = now_ns(CLOCK_PROCESS_CPUTIME_ID);
	if (start < 0 || cpu_start < 0)
		return 1;

	if (!strcmp(argv[1], "cpu")) {
		do {
			result = compute_batch(result);
			end = now_ns(CLOCK_MONOTONIC);
			if (end < 0)
				return 1;
		} while (end - start < duration);
	} else {
		struct timespec remain = { .tv_nsec = duration };

		while (nanosleep(&remain, &remain) < 0) {
			if (errno != EINTR)
				return 1;
		}
	}
	cpu_end = now_ns(CLOCK_PROCESS_CPUTIME_ID);
	end = now_ns(CLOCK_MONOTONIC);
	if (end < 0 || cpu_end < 0)
		return 1;
	printf("mode=%s wall_ms=%.3f cpu_ms=%.3f checksum=%llu\n",
	       argv[1], (end - start) / 1e6, (cpu_end - cpu_start) / 1e6,
	       (unsigned long long)result);
	return 0;
}
