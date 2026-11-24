/* 只检查调用入口与当前用户创建单元素 map 的能力。成功后马上关闭。 */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/bpf.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void)
{
#ifdef SYS_bpf
	union bpf_attr attr = {0};

	attr.map_type = BPF_MAP_TYPE_ARRAY;
	attr.key_size = 4;
	attr.value_size = 8;
	attr.max_entries = 1;
	long fd = syscall(SYS_bpf, BPF_MAP_CREATE, &attr, sizeof(attr));

	if (fd >= 0) {
		puts("bpf MAP_CREATE: 成功");
		return close((int)fd) < 0;
	}
	int error = errno;
	printf("bpf MAP_CREATE: errno=%d, %s\n", error, strerror(error));
	if (error == ENOSYS)
		puts("此运行环境没有向调用者提供 bpf 系统调用");
	else if (error == EPERM || error == EACCES)
		puts("当前调用受到权限或运行环境策略限制");
	else
		puts("需要核对内核、map 类型与属性");
	return 1;
#else
	puts("编译所用的用户态头文件没有 SYS_bpf");
	return 2;
#endif
}
