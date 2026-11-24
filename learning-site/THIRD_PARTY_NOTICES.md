# 源码摘录来源与许可

正文标为「源码摘录」的代码块按所属文件的许可提供，保留原始路径和闭区间行号。为阅读去掉了共有的前导缩进。标为「流程示例（自写）」的代码块给出同一接口或流程的独立说明。

## 来源版本

- `kernel-6.1`，SDK Git 提交 `a04e4b3c96aaead0a6049d5d76416bc8ca3d93d1`。
- `external/rockit`，SDK Git 提交 `364083ac133e45732e3e89c239a878f8ae7bd51b`。
- `external/mpp`，SDK Git 提交 `15bf88a0455f6a49426b793ca3b9e1f8e4b7ffb9`。
- `external/camera_engine_rkaiq`，SDK Git 提交 `91dee445c13770279e3ee90cd82bd278c5306f85`。

## 许可文本

- [GPL-2.0](LICENSES/GPL-2.0.txt)
- [LGPL-2.0](LICENSES/LGPL-2.0.txt)
- [Linux-syscall-note](LICENSES/Linux-syscall-note.txt)
- [MIT](LICENSES/MIT.txt)
- [BSD-3-Clause](LICENSES/BSD-3-Clause.txt)
- [Apache-2.0](LICENSES/Apache-2.0.txt)

## 文件与版权声明

| SDK 路径 | 原文件许可 | 版权声明 |
| --- | --- | --- |
| `external/camera_engine_rkaiq/rkaiq/aiq_core_c/algo_handlers/RkAiqAwbHandler.c` | Apache-2.0 | Copyright (c) 2024 Rockchip Eletronics Co., Ltd. |
| `external/camera_engine_rkaiq/rkaiq/hwi_c/aiq_aiIspLoader.c` | Apache-2.0 | Copyright (c) 2024 Rockchip Corporation |
| `external/camera_engine_rkaiq/rkaiq/hwi_c/aiq_CamHwBase.c` | Apache-2.0 | Copyright (c) 2024 Rockchip Corporation |
| `external/camera_engine_rkaiq/rkaiq/hwi_c/aiq_sensorHw.c` | Apache-2.0 | Copyright (c) 2024 Rockchip Corporation |
| `external/mpp/test/mpi_enc_test.c` | Apache-2.0 OR MIT | Copyright (c) 2015 Rockchip Electronics Co., Ltd. |
| `external/rockit/mpi/sdk/include/rk_comm_venc.h` | GPL-2.0 WITH Linux-syscall-note OR Apache-2.0 | Copyright (c) 2021 Fuzhou Rockchip Electronics Co., Ltd |
| `external/rockit/mpi/sdk/include/rk_mpi_vpss.h` | GPL-2.0 WITH Linux-syscall-note OR Apache-2.0 | Copyright (c) 2021 Fuzhou Rockchip Electronics Co., Ltd |
| `kernel-6.1/arch/arm/mach-orion5x/dns323-setup.c` | LGPL（原文件声明版本 2 或更新版本） | Copyright (C) 2007 Herbert Valerio Riedel <hvr@gnu.org>；Copyright (C) 2010 Benjamin Herrenschmidt <benh@kernel.crashing.org> |
| `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b-alientek.dtsi` | (GPL-2.0+ OR MIT) | Copyright (c) 2025 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b-pinctrl.dtsi` | (GPL-2.0+ OR MIT) | Copyright (c) 2024 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/arch/arm64/boot/dts/rockchip/rv1126b.dtsi` | (GPL-2.0+ OR MIT) | Copyright (c) 2024 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/arch/arm64/kernel/entry-common.c` | GPL-2.0 | Copyright (C) 2019 ARM Ltd. |
| `kernel-6.1/arch/arm64/kernel/entry.S` | GPL-2.0-only | Copyright (C) 2012 ARM Ltd. |
| `kernel-6.1/arch/arm64/kernel/head.S` | GPL-2.0-only | Copyright (C) 1994-2002 Russell King；Copyright (C) 2003-2012 ARM Ltd. |
| `kernel-6.1/arch/arm64/kernel/sys.c` | GPL-2.0-only | Copyright (C) 2012 ARM Ltd. |
| `kernel-6.1/arch/arm64/kernel/syscall.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/arch/arm64/mm/fault.c` | GPL-2.0-only | Copyright (C) 1995  Linus Torvalds；Copyright (C) 1995-2004 Russell King；Copyright (C) 2012 ARM Ltd. |
| `kernel-6.1/block/blk-core.c` | GPL-2.0 | Copyright (C) 1991, 1992 Linus Torvalds；Copyright (C) 1994,      Karl Keyte: Added support for disk statistics；Elevator latency, (C) 2000  Andrea Arcangeli <andrea@suse.de> SuSE |
| `kernel-6.1/block/blk-mq.c` | GPL-2.0 | Copyright (C) 2013-2014 Jens Axboe；Copyright (C) 2013-2014 Christoph Hellwig |
| `kernel-6.1/drivers/base/core.c` | GPL-2.0 | Copyright (c) 2002-3 Patrick Mochel；Copyright (c) 2002-3 Open Source Development Labs；Copyright (c) 2006 Greg Kroah-Hartman <gregkh@suse.de>；Copyright (c) 2006 Novell, Inc. |
| `kernel-6.1/drivers/base/cpu.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/drivers/char/misc.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/drivers/char/random.c` | (GPL-2.0 OR BSD-3-Clause) | Copyright (C) 2017-2022 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.；Copyright Matt Mackall <mpm@selenic.com>, 2003, 2004, 2005；Copyright Theodore Ts'o, 1994, 1995, 1996, 1997, 1998, 1999. All rights reserved. |
| `kernel-6.1/drivers/clk/clk.c` | GPL-2.0 | Copyright (C) 2010-2011 Canonical Ltd <jeremy.kerr@canonical.com>；Copyright (C) 2011-2012 Linaro Ltd <mturquette@linaro.org> |
| `kernel-6.1/drivers/dma-buf/dma-buf.c` | GPL-2.0-only | Copyright(C) 2011 Linaro Limited. All rights reserved. |
| `kernel-6.1/drivers/gpio/gpiolib.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/drivers/i2c/busses/i2c-rk3x.c` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/drivers/i2c/i2c-boardinfo.c` | GPL-2.0-or-later | 见原文件 |
| `kernel-6.1/drivers/i2c/i2c-core-base.c` | GPL-2.0-or-later | Copyright (C) 1995-99 Simon G. Vogl；Copyright (C) 2013-2017 Wolfram Sang <wsa@kernel.org> |
| `kernel-6.1/drivers/i2c/i2c-core-of.c` | GPL-2.0-or-later | Copyright (C) 2008 Jochen Friedrich <jochen@scram.de>；Copyright (C) 2013, 2018 Wolfram Sang <wsa@kernel.org> |
| `kernel-6.1/drivers/iommu/iommu.c` | GPL-2.0-only | Copyright (C) 2007-2008 Advanced Micro Devices, Inc. |
| `kernel-6.1/drivers/irqchip/irq-gic.c` | GPL-2.0-only | Copyright (C) 2002 ARM Limited, All Rights Reserved. |
| `kernel-6.1/drivers/media/common/videobuf2/videobuf2-cma-sg.c` | GPL-2.0 | Copyright (C) 2022 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/common/videobuf2/videobuf2-core.c` | GPL（原文件声明） | Copyright (C) 2010 Samsung Electronics；(c) 2004 Gerd Knorr <kraxel@bytesex.org> [SUSE Labs] |
| `kernel-6.1/drivers/media/i2c/dw9714.c` | GPL-2.0 | Copyright (C) 2022 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/i2c/imx415.c` | GPL-2.0 | Copyright (C) 2020 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/i2c/Kconfig` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/drivers/media/i2c/Makefile` | GPL-2.0 | 见原文件 |
| `kernel-6.1/drivers/media/platform/rockchip/aiisp/aiisp.c` | GPL-2.0 | Copyright (c) 2025 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/cif/capture.c` | GPL-2.0 | Copyright (C) 2018 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/cif/dev.c` | GPL-2.0 | Copyright (C) 2018 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/cif/procfs.c` | GPL-2.0 | Copyright (c) Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/isp/capture_v35.c` | GPL-2.0 | Copyright (c) 2025 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/isp/capture.c` | GPL-2.0 | Copyright (c) 2020 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/isp/hw.c` | GPL-2.0 | Copyright (C) 2020 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/isp/isp_params_v35.c` | GPL-2.0 | Copyright (c) 2025 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/platform/rockchip/isp/isp_stats_v35.c` | GPL-2.0 | Copyright (c) 2025 Rockchip Electronics Co., Ltd. |
| `kernel-6.1/drivers/media/v4l2-core/v4l2-fwnode.c` | GPL-2.0-only | Copyright (c) 2016 Intel Corporation.；Copyright (C) 2012 - 2013 Samsung Electronics Co., Ltd.；Copyright (C) 2012 Renesas Electronics Corp. |
| `kernel-6.1/drivers/of/fdt.c` | GPL-2.0 | Copyright 2009 Benjamin Herrenschmidt, IBM Corp |
| `kernel-6.1/drivers/pinctrl/core.c` | GPL-2.0-only | Copyright (C) 2011-2012 ST-Ericsson SA；Copyright (C) 2012 NVIDIA CORPORATION. All rights reserved. |
| `kernel-6.1/drivers/pinctrl/devicetree.c` | GPL-2.0-only | Copyright (C) 2012 NVIDIA CORPORATION. All rights reserved. |
| `kernel-6.1/drivers/regulator/core.c` | GPL-2.0-or-later | Copyright 2007, 2008 Wolfson Microelectronics PLC.；Copyright 2008 SlimLogic Ltd. |
| `kernel-6.1/drivers/reset/core.c` | GPL-2.0-or-later | Copyright 2013 Philipp Zabel, Pengutronix |
| `kernel-6.1/fs/binfmt_elf.c` | GPL-2.0-only | Copyright 1993, 1994: Eric Youngdale (ericy@cais.com). |
| `kernel-6.1/fs/char_dev.c` | GPL-2.0 | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/exec.c` | GPL-2.0-only | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/ext4/file.c` | GPL-2.0 | Copyright (C) 1992, 1993, 1994, 1995；Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/ext4/fsync.c` | GPL-2.0 | Copyright (C) 1993  Stephen Tweedie (sct@redhat.com)；Copyright (C) 1992  Remy Card (card@masi.ibp.fr)；linux/fs/minix/truncate.c   Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/ext4/namei.c` | GPL-2.0 | Copyright (C) 1992, 1993, 1994, 1995；Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/file_table.c` | GPL-2.0-only | Copyright (C) 1991, 1992  Linus Torvalds；Copyright (C) 1997 David S. Miller (davem@caip.rutgers.edu) |
| `kernel-6.1/fs/file.c` | GPL-2.0 | Copyright (C) 1998-1999, Stephen Tweedie and Bill Hawes |
| `kernel-6.1/fs/namei.c` | GPL-2.0 | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/open.c` | GPL-2.0-only | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/pipe.c` | GPL-2.0 | Copyright (C) 1991, 1992, 1999  Linus Torvalds |
| `kernel-6.1/fs/proc/fd.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/fs/proc/meminfo.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/fs/proc/stat.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/fs/read_write.c` | GPL-2.0 | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/fs/select.c` | GPL-2.0 | 见原文件 |
| `kernel-6.1/include/linux/fs.h` | GPL-2.0 | 见原文件 |
| `kernel-6.1/include/linux/i2c.h` | GPL-2.0-or-later | Copyright (C) 1995-2000 Simon G. Vogl；Copyright (C) 2013-2019 Wolfram Sang <wsa@kernel.org> |
| `kernel-6.1/include/linux/module.h` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/include/linux/vermagic.h` | GPL-2.0 | 见原文件 |
| `kernel-6.1/include/media/mipi-csi2.h` | GPL-2.0-only | Copyright (C) 2022 Laurent Pinchart <laurent.pinchart@ideasonboard.com> |
| `kernel-6.1/include/trace/events/irq.h` | GPL-2.0 | 见原文件 |
| `kernel-6.1/include/trace/events/sched.h` | GPL-2.0 | 见原文件 |
| `kernel-6.1/include/uapi/linux/dma-buf.h` | GPL-2.0 WITH Linux-syscall-note | Copyright(C) 2015 Intel Ltd |
| `kernel-6.1/include/uapi/linux/i2c.h` | GPL-2.0+ WITH Linux-syscall-note | Copyright (C) 1995-2000 Simon G. Vogl |
| `kernel-6.1/init/do_mounts.c` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/init/Kconfig` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/init/main.c` | GPL-2.0-only | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/kernel/bpf/syscall.c` | GPL-2.0-only | Copyright (c) 2011-2014 PLUMgrid, http://plumgrid.com |
| `kernel-6.1/kernel/configs.c` | GPL-2.0-or-later | Copyright (C) 2002 Khalid Aziz <khalid_aziz@hp.com>；Copyright (C) 2002 Randy Dunlap <rdunlap@xenotime.net>；Copyright (C) 2002 Al Stone <ahs3@fc.hp.com>；Copyright (C) 2002 Hewlett-Packard Company |
| `kernel-6.1/kernel/events/core.c` | GPL-2.0 | Copyright (C) 2008 Thomas Gleixner <tglx@linutronix.de>；Copyright (C) 2008-2011 Red Hat, Inc., Ingo Molnar；Copyright (C) 2008-2011 Red Hat, Inc., Peter Zijlstra；Copyright  ©  2009 Paul Mackerras, IBM Corp. <paulus@au1.ibm.com> |
| `kernel-6.1/kernel/exit.c` | GPL-2.0-only | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/kernel/fork.c` | GPL-2.0-only | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/kernel/irq/chip.c` | GPL-2.0 | Copyright (C) 1992, 1998-2006 Linus Torvalds, Ingo Molnar；Copyright (C) 2005-2006, Thomas Gleixner, Russell King |
| `kernel-6.1/kernel/module/main.c` | GPL-2.0-or-later | Copyright (C) 2002 Richard Henderson；Copyright (C) 2001 Rusty Russell, 2002, 2010 Rusty Russell IBM. |
| `kernel-6.1/kernel/sched/core.c` | GPL-2.0-only | Copyright (C) 1991-2002  Linus Torvalds |
| `kernel-6.1/kernel/sched/fair.c` | GPL-2.0 | Copyright (C) 2007 Red Hat, Inc., Ingo Molnar <mingo@redhat.com>；(C) 2007 Mike Galbraith <efault@gmx.de>；(C) 2007 Dmitry Adamushko <dmitry.adamushko@gmail.com>；Copyright IBM Corporation, 2007；Copyright (C) 2007, Thomas Gleixner <tglx@linutronix.de>；Copyright (C) 2007 Red Hat, Inc., Peter Zijlstra |
| `kernel-6.1/kernel/sys.c` | GPL-2.0 | Copyright (C) 1991, 1992  Linus Torvalds |
| `kernel-6.1/kernel/time/hrtimer.c` | GPL-2.0 | Copyright(C) 2005-2006, Thomas Gleixner <tglx@linutronix.de>；Copyright(C) 2005-2007, Red Hat, Inc., Ingo Molnar；Copyright(C) 2006-2007  Timesys Corp., Thomas Gleixner |
| `kernel-6.1/kernel/trace/Kconfig` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/lib/Kconfig.debug` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/mm/cma.c` | GPL-2.0-or-later | Copyright (c) 2010-2011 by Samsung Electronics.；Copyright IBM Corporation, 2013；Copyright LG Electronics Inc., 2014 |
| `kernel-6.1/mm/memory.c` | GPL-2.0-only | Copyright (C) 1991, 1992, 1993, 1994  Linus Torvalds |
| `kernel-6.1/mm/mmap.c` | GPL-2.0-only | 见原文件 |
| `kernel-6.1/mm/page_alloc.c` | GPL-2.0-only | Copyright (C) 1991, 1992, 1993, 1994  Linus Torvalds |
| `kernel-6.1/mm/slub.c` | GPL-2.0 | (C) 2007 SGI, Christoph Lameter；(C) 2011 Linux Foundation, Christoph Lameter |
| `kernel-6.1/scripts/kconfig/Makefile` | GPL-2.0 | 见原文件 |
| `kernel-6.1/scripts/Makefile.host` | GPL-2.0 | 见原文件 |
| `kernel-6.1/scripts/mod/modpost.c` | GPL（原文件声明） | Copyright 2003       Kai Germaschewski；Copyright 2002-2004  Rusty Russell, IBM Corporation；Copyright 2006-2008  Sam Ravnborg |
