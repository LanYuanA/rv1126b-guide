# 把一次 open 接到自己的字符驱动

这次用同一套内核构建树处理两个例子。IMX415 已由内核构建系统管理；便笺驱动只有一个 C 文件和一行 Kbuild。先判断编译产物在哪里，再追设备号，最后看驱动怎样为每个打开者保存消息。

<a id="kbuild"></a>

先验证构建产物和加载边界。[2.4 模块、内建驱动与 Kbuild](kbuild.md)

<a id="fops"></a>

设备号与回调切换见[2.5 字符设备号与 file_operations](char-fops.md)。

<a id="legacy"></a>

传统注册与编号区间见[2.6 传统 register_chrdev 注册法](register-chrdev.md)。

<a id="explicit"></a>

编号、发布与回退见[2.7 显式 cdev、设备类与设备节点](cdev.md)。

<a id="misc"></a>

便笺的打开与私有状态见[2.8 miscdevice 与每次打开的私有状态](miscdevice.md)。

<a id="abi"></a>

接口设计见[2.9 设计 read、write、ioctl、poll 和 mmap](io-contract.md)。

<a id="lifetime"></a>

多实例的释放与回退见[2.10 多实例、错误回退与卸载](driver-lifetime.md)。
