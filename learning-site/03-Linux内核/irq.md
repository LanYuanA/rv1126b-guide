# 3.3 ARM64 中断与通用 IRQ 子系统

上篇的 SVC 来自用户程序主动执行的指令。IRQ 可以在 CPU 执行其他线程时到达。第一路 IMX415 挂在 I2C3，总线控制器完成一段传输时可以发出中断。先在 WSL 从项目根目录执行。注意在 SoC 的**控制器**节点找 interrupts。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -A7 'i2c3: i2c@' "$k/arch/arm64/boot/dts/rockchip/rv1126b.dtsi"
rg -n 'arm,gic-400' "$k/arch/arm64/boot/dts/rockchip/rv1126b.dtsi"
rg -n 'platform_get_irq|devm_request_irq' "$k/drivers/i2c/busses/i2c-rk3x.c"
~~~

本版为 `<GIC_SPI 51 IRQ_TYPE_LEVEL_HIGH>`。第一个单元说明类型是共享外设中断 SPI，第二个给出该类型内的编号，第三个描述高电平触发。GIC-400 的翻译函数对 SPI 加 32，所以控制器视角的 hwirq 是 83。irqdomain 维护从硬件编号到 Linux IRQ 描述符的映射。platform_get_irq(pdev, 0) 取设备的第一项 IRQ 资源；返回非负的 Linux IRQ 后，devm_request_irq 用它登记 rk3x_i2c_irq 和本控制器的 i2c 实例。

`drivers/irqchip/irq-gic.c:1215`

~~~c
switch (fwspec->param[0]) {
case 0:			/* SPI */
	*hwirq = fwspec->param[1] + 32;
	break;
case 1:			/* PPI */
	*hwirq = fwspec->param[1] + 16;
	break;
~~~

设备树中断说明符先转为控制器编号。驱动最终取得的是经过映射的 Linux IRQ。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:2002–2007`

~~~c
irq = platform_get_irq(pdev, 0);
if (irq < 0)
	return irq;
i2c->irq = irq;

if (IS_ENABLED(CONFIG_ROCKCHIP_THUNDER_BOOT_SERVICE) &&
~~~

~~~text
控制器 REG_IPD 置位 → 中断线有效 → GIC 将请求送到目标 CPU
 → ARM64 IRQ 入口 → gic_handle_irq 取得中断 ID
 → generic_handle_domain_irq → 通用 IRQ 流程 → 已注册的 rk3x_i2c_irq
 → 驱动读取 IPD 并按传输状态处理 → 源解除，GIC 完成相应的结束处理
~~~

读源码时把最后一行拆开。GIC 应答、优先级下降及 deactivate 的具体次序取决于该 irqchip 的工作模式。外设自己的 pending 位则由驱动按寄存器语义处理。只结束 GIC 侧的处理，外设若仍把电平拉高，就可能再次进中断。查看 rk3x 的停止状态分支，找到对 REG_IPD 写入 REG_INT_STOP 和结束传输、通知等待者的动作。[I2C 控制器中断分支](../04-设备模型与驱动子系统/i2c-irq.md)

源码摘录 `kernel-6.1/drivers/irqchip/irq-gic.c:370–375`

~~~c
static void __exception_irq_entry gic_handle_irq(struct pt_regs *regs)
{
	u32 irqstat, irqnr;
	struct gic_chip_data *gic = &gic_data[0];
	void __iomem *cpu_base = gic_data_cpu_base(gic);

~~~

控制器分派到通用 IRQ 后，已注册的设备回调才读取外设状态位。

源码摘录 `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c:918–923`

~~~c
static irqreturn_t rk3x_i2c_irq(int irqno, void *dev_id)
{
	struct rk3x_i2c *i2c = dev_id;
	unsigned int ipd;

	spin_lock(&i2c->lock);
~~~

SPI 名称中的 shared 指这种外设中断可路由到 CPU。Linux 多设备共享同一 IRQ 则需要注册者协商 IRQF_SHARED、提供可区分的 dev_id，并通过设备状态判断事件是否属于自己。本例注册参数 flags 为 0。若驱动采用 request_threaded_irq，主处理函数可快速确认来源并返回 IRQ_WAKE_THREAD，把可睡眠的工作交给线程函数。

## 通用 IRQ 层在硬件和驱动之间做什么？

### 1. CPU 先按异常类别进向量

AArch64 将当前异常级和来源用于选择向量。前文的 SVC 走 EL0 同步入口；假如同一个线程正在 EL0 时收到 IRQ，CPU 走异步 IRQ 入口。若被打断的是内核代码，入口路径也有对应的 EL1 分支。这里先看 64 位 EL0 的 IRQ 入口如何把保存的现场传到架构中断处理链。

源码摘录 `kernel-6.1/arch/arm64/kernel/entry-common.c:722–727`

~~~c
static void noinstr __el0_irq_handler_common(struct pt_regs *regs)
{
	el0_interrupt(regs, handle_arch_irq);
}

asmlinkage void noinstr el0t_64_irq_handler(struct pt_regs *regs)
~~~

handler 是架构登记的中断处理函数。GIC 的处理函数再去 CPU interface 读应答寄存器，从读回值提取 INTID。Distributor 一侧组织中断源的路由、优先级和使能等设置，CPU interface 一侧把可服务的中断呈交 CPU。这样 CPU 取得的是控制器的硬件编号。

### 2. 从 INTID 找 irq_desc，再决定怎么执行

GIC 的 domain 不只用来在注册时翻译 DTS。运行时 generic_handle_domain_irq 也根据“domain 加硬件编号”找对应描述符。irq_desc 保存通用状态、IRQ chip 操作、流程函数和已注册的 action。GIC 为普通外设中断设置 fast EOI 类型的流程函数，下面看本版通用处理的顺序。

源码摘录 `kernel-6.1/kernel/irq/chip.c:704–713`

~~~c
if (unlikely(!desc->action || irqd_irq_disabled(&desc->irq_data))) {
	desc->istate |= IRQS_PENDING;
	mask_irq(desc);
	goto out;
}

kstat_incr_irqs_this_cpu(desc);
if (desc->istate & IRQS_ONESHOT)
	mask_irq(desc);

~~~

如果描述符已禁用或没有 action，这一路会标记 pending 并屏蔽。正常分支累加当前 CPU 的计数，按条件执行屏蔽，然后交给已登记的 action。这里的统计时刻早于驱动返回，计数上涨只能说明 IRQ 流程曾进入计数分支。

### 3. action 记住了哪个驱动和哪个实例

`kernel/irq/handle.c:157`

~~~c
trace_irq_handler_entry(irq, action);
res = action->handler(irq, action->dev_id);
trace_irq_handler_exit(irq, action, res);
~~~

action 的 handler 与 dev_id 来自注册。框架迭代当前描述符中的 action，所以共享 IRQ 的处理者先检查自己的外设状态。与自己无关时应返回 IRQ_NONE。处理成功用 IRQ_HANDLED，需要线程函数时用 IRQ_WAKE_THREAD。共享注册时要提供可识别的 dev_id，驱动也必须用同一个标识撤销自己的注册。I2C3 在此使用固定的控制器实例指针交给回调。

**电平中断的检验。** 假设设备一直保持中断线为高。控制器 EOI 后，线路仍有效时，后续可能再次上报。排查连续触发要看外设待处理位是否确已清除，以及下一个新事件是否紧接着到来。屏蔽 IRQ 会影响分派，但不能代替处理设备状态。

### 怎样算 IRQ 增量？

板端从同一次启动、同一负载窗口取两份快照。下列为已选好目标设备时的 WSL 只读命令，输出留在本地；当前小节只验证离线算法。

~~~bash
out=output/textbook-check/irq
mkdir -p "$out"
adb shell cat /proc/interrupts > "$out/before.txt" &&
sleep 1 && adb shell cat /proc/interrupts > "$out/after.txt"
~~~

从相同 Linux IRQ 且控制器名称、动作名称相同的两行取 CPU 列。例如两次快照为 [18, 100] 和 [21, 107]，按 CPU 相减得 [3, 7]。跨重启、CPU 集合发生变化或中断发生重新注册时，先重新建立基线。

在 WSL 模拟两次采样，只做差分计算。不连接板端。

~~~bash
before=(18 100)
after=(21 107)
cpu0=$((after[0] - before[0]))
cpu1=$((after[1] - before[1]))
printf 'CPU0=%d CPU1=%d 合计=%d\n' "$cpu0" "$cpu1" "$((cpu0 + cpu1))"
~~~

本例总增量 10。一个 I2C 事务可能有多个控制器状态中断，一条 ISP IRQ 也可能带多个状态位。要判断有无漏帧还需帧序号、完成队列记录和对应时间。若全部 CPU 计数都不变，先核对是否选对设备以及窗口内是否发生了该类操作。

## 本节复盘

1. 按第一路 I2C3 口述 DTS 的 SPI 51、GIC 的 83、Linux IRQ 三者的来源，再指出 /proc/interrupts 最左列通常显示哪一个。
2. 如果设备有数据但驱动 ISR 从未进来，先沿供电、外设中断使能、触发类型、IRQ 注册和统计逐项找最后一个正面证据。已登记 action 也无法证明线路曾发出事件。
3. RX 完成由一个中断报告，为什么用户线程仍可能在等？下一节从资源状态发布和唤醒条件解开这一段。[3.4 延后处理、等待队列与 completion](deferred-work.md)
