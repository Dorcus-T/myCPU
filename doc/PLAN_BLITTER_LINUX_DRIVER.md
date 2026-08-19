# Blitter Linux 驱动实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Loongson SoC FPGA 上的 2D Blitter 实现 Linux 驱动：提供 `/dev/blitter` 命令接口，并让 VGA fbdev 的 fillrect/copyarea 透明走硬件加速。

**Architecture:** 独立 blitter 平台驱动负责寄存器、中断、cache 一致性，并暴露 misc 字符设备 ioctl；VGA fbdev 驱动通过导出 API 在满足约束时调用 blitter，否则回退软件实现。CPU 不直接写扫描显存的主路径为“CPU 写 shadow/back buffer → blitter COPY 到扫描缓冲”，同时保留 fbdev 兼容层。

**Tech Stack:** Linux kernel (LoongArch 32-bit), fbdev, miscdevice, platform driver, cached MMIO + CACOP, IRQ + completion, C.

**Spec:**
- `Z:\home\dorcus_t\chiplab\IP\myCPU\doc\HANDOFF_VGA_DOOM.md`
- `Z:\home\dorcus_t\chiplab\IP\myCPU\doc\VGA_DOOM_PLAN.md` Phase 4B
- `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\README.md`

## Global Constraints

- Blitter 物理基地址：`0x1fea0000`。
- 寄存器布局（32 位，4 字节对齐）：
  - `0x00 SRC_ADDR` / `0x04 DST_ADDR` / `0x08 SRC_STRIDE` / `0x0C DST_STRIDE`
  - `0x10 WIDTH` / `0x14 HEIGHT` / `0x18 COLOR` / `0x1C CTRL` / `0x20 STATUS`
- `CTRL`: bit0 START, bit1 OP (0=FILL, 1=COPY), bit2 IRQ_EN。
- `STATUS`: bit0 BUSY, bit1 DONE, bit2 ERR。
- WIDTH 必须偶数；SRC/DST 地址必须 4 字节对齐；stride 为字节数。
- 写 CTRL 且 bit0=1 即启动；启动自动清 DONE/ERR；完成后不会自动重启。
- 配置寄存器 `0x00~0x1C` 是一条 32B cache line，CTRL 在最高地址 `0x1C`；cached 写后必须整条写回。
- STATUS 必须 uncached 读。
- 中断接线：`blt_irq → int_out[5] → intrpt[5] → ESTAT[7]`，DTS 中断号 `<7>`。
- 当前只有单 blitter 引擎，任何时刻最多一个操作在跑；不实现命令队列。
- 驱动必须保留 fbdev 兼容：fbcon/普通 framebuffer 程序仍可用，软件回退不得破坏现有显示。

---

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `arch/loongarch/boot/dts/loongson-soc.dts` | Modify | 增加 blitter 节点 |
| `drivers/video/fbdev/loongson_soc_blitter.c` | Create | blitter 平台驱动 + misc 设备 + 导出 API |
| `drivers/video/fbdev/Kconfig` | Modify | 增加 `FB_LOONGSON_SOC_BLITTER` |
| `drivers/video/fbdev/Makefile` | Modify | 增加编译项 |
| `arch/loongarch/configs/loongson_soc_defconfig` | Modify | 打开 blitter 配置 |
| `drivers/video/fbdev/loongson_soc_vga.c` | Modify | fb_fillrect/fb_copyarea 接入 blitter |
| `integration/tools/fb_bench.c` | Modify | 增加 `blit` 模式 |
| `doc/HANDOFF_VGA_DOOM.md` | Modify | 更新 Phase 4B 状态 |

## 内核侧接口定义

### ioctl

```c
#define BLITTER_IOCTL_MAGIC 0xB1

struct blitter_op {
	__u32 op;         /* 0=FILL, 1=COPY */
	__u32 src_addr;   /* 物理地址，COPY 用 */
	__u32 dst_addr;   /* 物理地址 */
	__u32 src_stride; /* 字节 */
	__u32 dst_stride; /* 字节 */
	__u32 width;      /* 像素，必须偶数 */
	__u32 height;
	__u32 color;      /* RGB565，FILL 用 */
};

#define BLITTER_IOCTL_FILL _IOW(BLITTER_IOCTL_MAGIC, 1, struct blitter_op)
#define BLITTER_IOCTL_COPY _IOW(BLITTER_IOCTL_MAGIC, 2, struct blitter_op)
```

### 导出 API（给 VGA 驱动）

```c
bool loongson_soc_blitter_available(void);
int loongson_soc_blitter_fill(u32 dst_addr, u32 dst_stride,
			      u32 width, u32 height, u32 color);
int loongson_soc_blitter_copy(u32 src_addr, u32 src_stride,
			      u32 dst_addr, u32 dst_stride,
			      u32 width, u32 height);
```

`EXPORT_SYMBOL_GPL` 导出。全局单实例，通过 `static struct loongson_soc_blitter *g_blitter` 保存。

### 寄存器常量

```c
#define BLT_SRC_ADDR     0x00
#define BLT_DST_ADDR     0x04
#define BLT_SRC_STRIDE   0x08
#define BLT_DST_STRIDE   0x0C
#define BLT_WIDTH        0x10
#define BLT_HEIGHT       0x14
#define BLT_COLOR        0x18
#define BLT_CTRL         0x1C
#define BLT_STATUS       0x20

#define BLT_CTRL_START   BIT(0)
#define BLT_CTRL_OP_COPY BIT(1)
#define BLT_CTRL_IRQ_EN  BIT(2)

#define BLT_STATUS_BUSY  BIT(0)
#define BLT_STATUS_DONE  BIT(1)
#define BLT_STATUS_ERR   BIT(2)
```

---

### Task 1: DTS + Kconfig + Makefile + defconfig

**Files:**
- Modify: `arch/loongarch/boot/dts/loongson-soc.dts`
- Modify: `drivers/video/fbdev/Kconfig`
- Modify: `drivers/video/fbdev/Makefile`
- Modify: `arch/loongarch/configs/loongson_soc_defconfig`

**Interfaces:**
- Produces: DTS compatible string `loongson-edu,blitter`；Kconfig symbol `FB_LOONGSON_SOC_BLITTER`；defconfig `CONFIG_FB_LOONGSON_SOC_BLITTER=y`。

- [ ] **Step 1: DTS 增加 blitter 节点**

在 `loongson-soc.dts` 的 `soc { ... }` 内、`vga@1fe90000` 之后增加：

```dts
blitter@1fea0000 {
	compatible = "loongson-edu,blitter";
	reg = <0x1fea0000 0x100>;
	interrupt-parent = <&cpu_intc>;
	interrupts = <7>;
	memory-region = <&framebuffer>;
	status = "okay";
};
```

- [ ] **Step 2: Kconfig 增加配置项**

在 `drivers/video/fbdev/Kconfig` 的 `FB_LOONGSON_SOC_VGA` 之后增加：

```kconfig
config FB_LOONGSON_SOC_BLITTER
	bool "Loongson SoC 2D Blitter support"
	depends on FB_LOONGSON_SOC_VGA
	default y
	help
	  Say Y to enable the 2D Blitter driver for the Loongson Education
	  SoC FPGA platform. It exposes /dev/blitter and provides hardware
	  fill/copy acceleration to the Loongson SoC VGA framebuffer driver.
```

- [ ] **Step 3: Makefile 增加编译项**

在 `drivers/video/fbdev/Makefile` 的 `obj-$(CONFIG_FB_LOONGSON_SOC_VGA) += loongson_soc_vga.o` 后增加：

```makefile
obj-$(CONFIG_FB_LOONGSON_SOC_BLITTER) += loongson_soc_blitter.o
```

- [ ] **Step 4: defconfig 打开配置**

在 `arch/loongarch/configs/loongson_soc_defconfig` 的 `CONFIG_FB_LOONGSON_SOC_VGA=y` 后增加：

```
CONFIG_FB_LOONGSON_SOC_BLITTER=y
```

- [ ] **Step 5: 提交**

```bash
git add arch/loongarch/boot/dts/loongson-soc.dts \
        drivers/video/fbdev/Kconfig \
        drivers/video/fbdev/Makefile \
        arch/loongarch/configs/loongson_soc_defconfig
git commit -m "fbdev: add Loongson SoC blitter DT and config"
```

---

### Task 2: Blitter 驱动骨架

**Files:**
- Create: `drivers/video/fbdev/loongson_soc_blitter.c`

**Interfaces:**
- Consumes: DT node `loongson-edu,blitter`, IRQ `<7>`, `memory-region = <&framebuffer>`.
- Produces: `struct loongson_soc_blitter`, probe/remove, misc device node `/dev/blitter`, `g_blitter` singleton.

- [ ] **Step 1: 写驱动头、结构体、probe/remove**

```c
// SPDX-License-Identifier: GPL-2.0-only
/*
 * Loongson SoC 2D Blitter driver
 *
 * Registers (physical 0x1fea0000):
 *   0x00 SRC_ADDR / 0x04 DST_ADDR / 0x08 SRC_STRIDE / 0x0C DST_STRIDE
 *   0x10 WIDTH    / 0x14 HEIGHT  / 0x18 COLOR    / 0x1C CTRL
 *   0x20 STATUS
 */
#include <linux/completion.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_reserved_mem.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <asm/cacheflush.h>

#define BLT_DRV_NAME "loongson-soc-blitter"

/* register offsets */
#define BLT_SRC_ADDR     0x00
#define BLT_DST_ADDR     0x04
#define BLT_SRC_STRIDE   0x08
#define BLT_DST_STRIDE   0x0C
#define BLT_WIDTH        0x10
#define BLT_HEIGHT       0x14
#define BLT_COLOR        0x18
#define BLT_CTRL         0x1C
#define BLT_STATUS       0x20

#define BLT_CTRL_START   BIT(0)
#define BLT_CTRL_OP_COPY BIT(1)
#define BLT_CTRL_IRQ_EN  BIT(2)

#define BLT_STATUS_BUSY  BIT(0)
#define BLT_STATUS_DONE  BIT(1)
#define BLT_STATUS_ERR   BIT(2)

#define BLT_CFG_SIZE     0x20
#define BLT_STATUS_SIZE  0x04
#define BLT_TIMEOUT_MS   1000

#define BLITTER_IOCTL_MAGIC 0xB1

struct blitter_op {
	__u32 op;
	__u32 src_addr;
	__u32 dst_addr;
	__u32 src_stride;
	__u32 dst_stride;
	__u32 width;
	__u32 height;
	__u32 color;
};

#define BLITTER_IOCTL_FILL _IOW(BLITTER_IOCTL_MAGIC, 1, struct blitter_op)
#define BLITTER_IOCTL_COPY _IOW(BLITTER_IOCTL_MAGIC, 2, struct blitter_op)

struct loongson_soc_blitter {
	void __iomem *cfg;      /* ioremap_cache, 0x00~0x1C */
	void __iomem *status;   /* ioremap, 0x20 */
	struct device *dev;
	struct miscdevice misc;
	int irq;
	struct completion done;
	spinlock_t lock;        /* protects config window */

	void __iomem *fb_va;    /* cached mapping for cache maintenance */
	phys_addr_t fb_phys;
	size_t fb_size;
};

static struct loongson_soc_blitter *g_blitter;
```

probe 逻辑：

```c
static int loongson_soc_blitter_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct resource *res;
	struct loongson_soc_blitter *blt;
	struct resource fb_res;
	int ret;

	blt = devm_kzalloc(dev, sizeof(*blt), GFP_KERNEL);
	if (!blt)
		return -ENOMEM;

	blt->dev = dev;
	spin_lock_init(&blt->lock);
	init_completion(&blt->done);

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res)
		return -ENODEV;

	blt->cfg = devm_ioremap_cache(dev, res->start, BLT_CFG_SIZE);
	if (!blt->cfg)
		return -ENOMEM;

	blt->status = devm_ioremap(dev, res->start + BLT_STATUS, BLT_STATUS_SIZE);
	if (!blt->status)
		return -ENOMEM;

	blt->irq = platform_get_irq(pdev, 0);
	if (blt->irq < 0)
		return blt->irq;

	ret = devm_request_irq(dev, blt->irq, loongson_soc_blitter_irq, 0,
			       BLT_DRV_NAME, blt);
	if (ret)
		return ret;

	ret = of_reserved_mem_region_to_resource(dev->of_node, 0, &fb_res);
	if (ret)
		return ret;

	blt->fb_phys = fb_res.start;
	blt->fb_size = resource_size(&fb_res);
	blt->fb_va = devm_ioremap_cache(dev, blt->fb_phys, blt->fb_size);
	if (!blt->fb_va)
		return -ENOMEM;

	blt->misc.minor = MISC_DYNAMIC_MINOR;
	blt->misc.name = "blitter";
	blt->misc.fops = &loongson_soc_blitter_fops;
	blt->misc.parent = dev;

	ret = misc_register(&blt->misc);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, blt);
	g_blitter = blt;

	dev_info(dev, "Loongson SoC blitter at 0x%llx, irq %d\n",
		 (u64)res->start, blt->irq);
	return 0;
}
```

remove 逻辑：

```c
static void loongson_soc_blitter_remove(struct platform_device *pdev)
{
	struct loongson_soc_blitter *blt = platform_get_drvdata(pdev);

	misc_deregister(&blt->misc);
	if (g_blitter == blt)
		g_blitter = NULL;
}
```

- [ ] **Step 2: 空 ioctl 先能编译**

先写最小 file_operations：

```c
static long loongson_soc_blitter_ioctl(struct file *file, unsigned int cmd,
				       unsigned long arg)
{
	return -ENOTTY;
}

static const struct file_operations loongson_soc_blitter_fops = {
	.owner = THIS_MODULE,
	.unlocked_ioctl = loongson_soc_blitter_ioctl,
};
```

加上 of_match 和 platform_driver：

```c
static const struct of_device_id loongson_soc_blitter_of_match[] = {
	{ .compatible = "loongson-edu,blitter" },
	{ }
};
MODULE_DEVICE_TABLE(of, loongson_soc_blitter_of_match);

static struct platform_driver loongson_soc_blitter_driver = {
	.probe = loongson_soc_blitter_probe,
	.remove = loongson_soc_blitter_remove,
	.driver = {
		.name = BLT_DRV_NAME,
		.of_match_table = loongson_soc_blitter_of_match,
	},
};
module_platform_driver(loongson_soc_blitter_driver);

MODULE_AUTHOR("Loongson Education FPGA Lab");
MODULE_DESCRIPTION("Loongson SoC 2D Blitter driver");
MODULE_LICENSE("GPL v2");
```

注意：此时 ISR 还未实现，`loongson_soc_blitter_irq` 先放一个返回 `IRQ_NONE` 的桩，保证能编译。

- [ ] **Step 3: 构建验证**

```bash
cd /home/dorcus_t/la32r-upstream-integration/src/linux
make ARCH=loongarch CROSS_COMPILE=loongarch32-linux-gnusf- loongson_soc_defconfig
make ARCH=loongarch CROSS_COMPILE=loongarch32-linux-gnusf- -j$(nproc)
```

Expected: 编译通过，无 `loongson_soc_blitter` 相关错误。

- [ ] **Step 4: 提交**

```bash
git add drivers/video/fbdev/loongson_soc_blitter.c
git commit -m "fbdev: add Loongson SoC blitter driver skeleton"
```

---

### Task 3: 核心执行路径（cached 配置 + 中断 + 超时回退）

**Files:**
- Modify: `drivers/video/fbdev/loongson_soc_blitter.c`

**Interfaces:**
- Consumes: `struct loongson_soc_blitter` from Task 2.
- Produces: `blt_flush_line()`, `blt_exec()`, ISR `loongson_soc_blitter_irq()`.

- [ ] **Step 1: 实现 cache line 写回**

```c
static void loongson_soc_blitter_flush_line(void __iomem *addr)
{
	unsigned long a = (unsigned long)addr;

	cache_op(Hit_Writeback_Inv_LEAF1, a);
	asm volatile("dbar 0" ::: "memory");
}
```

- [ ] **Step 2: 实现 framebuffer 区间 cache 同步**

```c
static void loongson_soc_blitter_sync_range(struct loongson_soc_blitter *blt,
					    phys_addr_t phys, size_t size)
{
	unsigned long addr;
	unsigned long end;

	if (phys < blt->fb_phys || phys + size > blt->fb_phys + blt->fb_size)
		return;

	addr = (unsigned long)blt->fb_va + (phys - blt->fb_phys);
	end = addr + size;
	addr &= ~0xful;
	for (; addr < end; addr += 16)
		cache_op(Hit_Writeback_Inv_LEAF1, addr);

	asm volatile("dbar 0" ::: "memory");
}
```

- [ ] **Step 3: 实现 ISR**

```c
static irqreturn_t loongson_soc_blitter_irq(int irq, void *data)
{
	struct loongson_soc_blitter *blt = data;
	u32 status = readl(blt->status);

	if (status & (BLT_STATUS_DONE | BLT_STATUS_ERR)) {
		writel(status & (BLT_STATUS_DONE | BLT_STATUS_ERR), blt->status);
		complete(&blt->done);
		return IRQ_HANDLED;
	}

	return IRQ_NONE;
}
```

- [ ] **Step 4: 实现 `blt_exec`**

```c
static int loongson_soc_blitter_exec(struct loongson_soc_blitter *blt,
				     const struct blitter_op *op)
{
	u32 __iomem *cfg = blt->cfg;
	unsigned long flags;
	u32 ctrl;
	u32 status;
	int ret = 0;

	if (op->width == 0 || op->height == 0)
		return -EINVAL;
	if (op->width & 1)
		return -EINVAL;
	if ((op->dst_addr & 3) || (op->op == 1 && (op->src_addr & 3)))
		return -EINVAL;

	/* source must be visible to the device before COPY */
	if (op->op == 1)
		loongson_soc_blitter_sync_range(blt, op->src_addr,
						op->height * op->src_stride);
	loongson_soc_blitter_sync_range(blt, op->dst_addr,
					op->height * op->dst_stride);

	/*
	 * Config window: mask all local IRQs and disable preemption so no
	 * interrupt can evict/write back a partially written config line.
	 * This is a short, non-sleeping critical section.
	 */
	spin_lock_irqsave(&blt->lock, flags);

	/* Clear stale DONE/ERR and arm the completion before START. */
	writel(BLT_STATUS_DONE | BLT_STATUS_ERR, blt->status);
	reinit_completion(&blt->done);

	ctrl = BLT_CTRL_START | BLT_CTRL_IRQ_EN;
	if (op->op == 1)
		ctrl |= BLT_CTRL_OP_COPY;

	/* cfg is u32 __iomem *, so register indices are byte_offset / 4. */
	writel(op->src_addr,   cfg + 0);	/* BLT_SRC_ADDR   */
	writel(op->dst_addr,   cfg + 1);	/* BLT_DST_ADDR   */
	writel(op->src_stride, cfg + 2);	/* BLT_SRC_STRIDE */
	writel(op->dst_stride, cfg + 3);	/* BLT_DST_STRIDE */
	writel(op->width,      cfg + 4);	/* BLT_WIDTH      */
	writel(op->height,     cfg + 5);	/* BLT_HEIGHT     */
	writel(op->color,      cfg + 6);	/* BLT_COLOR      */
	writel(ctrl,           cfg + 7);	/* BLT_CTRL, last: parameters then START */

	loongson_soc_blitter_flush_line(cfg);

	spin_unlock_irqrestore(&blt->lock, flags);

	if (!wait_for_completion_timeout(&blt->done,
					 msecs_to_jiffies(BLT_TIMEOUT_MS))) {
		/* IRQ not wired/failed: fall back to polling STATUS */
		ret = readl_poll_timeout(blt->status, status,
					status & (BLT_STATUS_DONE | BLT_STATUS_ERR),
					100, BLT_TIMEOUT_MS * 1000);
		if (ret)
			return -ETIMEDOUT;
	}

	status = readl(blt->status);
	if (status & BLT_STATUS_ERR)
		return -EIO;

	return 0;
}
```

- [ ] **Step 5: 构建验证**

```bash
make ARCH=loongarch CROSS_COMPILE=loongarch32-linux-gnusf- -j$(nproc)
```

Expected: 编译通过。

- [ ] **Step 6: 提交**

```bash
git add drivers/video/fbdev/loongson_soc_blitter.c
git commit -m "fbdev: blitter: implement cached config, irq and poll fallback"
```

---

### Task 4: ioctl 与导出 API

**Files:**
- Modify: `drivers/video/fbdev/loongson_soc_blitter.c`

**Interfaces:**
- Consumes: `blt_exec()` from Task 3.
- Produces: `/dev/blitter` FILL/COPY ioctl；`loongson_soc_blitter_available/fill/copy` 导出符号。

- [ ] **Step 1: 实现 ioctl**

```c
static long loongson_soc_blitter_ioctl(struct file *file, unsigned int cmd,
				       unsigned long arg)
{
	struct loongson_soc_blitter *blt = file->private_data;
	struct blitter_op op;
	int ret;

	if (copy_from_user(&op, (void __user *)arg, sizeof(op)))
		return -EFAULT;

	switch (cmd) {
	case BLITTER_IOCTL_FILL:
		op.op = 0;
		break;
	case BLITTER_IOCTL_COPY:
		op.op = 1;
		break;
	default:
		return -ENOTTY;
	}

	ret = loongson_soc_blitter_exec(blt, &op);
	return ret;
}

static int loongson_soc_blitter_open(struct inode *inode, struct file *file)
{
	struct loongson_soc_blitter *blt =
		container_of(file->private_data, struct loongson_soc_blitter, misc);

	file->private_data = blt;
	return 0;
}

static const struct file_operations loongson_soc_blitter_fops = {
	.owner = THIS_MODULE,
	.open = loongson_soc_blitter_open,
	.unlocked_ioctl = loongson_soc_blitter_ioctl,
};
```

- [ ] **Step 2: 实现导出 API**

```c
bool loongson_soc_blitter_available(void)
{
	return g_blitter != NULL;
}
EXPORT_SYMBOL_GPL(loongson_soc_blitter_available);

int loongson_soc_blitter_fill(u32 dst_addr, u32 dst_stride,
			      u32 width, u32 height, u32 color)
{
	struct blitter_op op = {
		.op = 0,
		.dst_addr = dst_addr,
		.dst_stride = dst_stride,
		.width = width,
		.height = height,
		.color = color,
	};

	if (!g_blitter)
		return -ENODEV;

	return loongson_soc_blitter_exec(g_blitter, &op);
}
EXPORT_SYMBOL_GPL(loongson_soc_blitter_fill);

int loongson_soc_blitter_copy(u32 src_addr, u32 src_stride,
			      u32 dst_addr, u32 dst_stride,
			      u32 width, u32 height)
{
	struct blitter_op op = {
		.op = 1,
		.src_addr = src_addr,
		.src_stride = src_stride,
		.dst_addr = dst_addr,
		.dst_stride = dst_stride,
		.width = width,
		.height = height,
	};

	if (!g_blitter)
		return -ENODEV;

	return loongson_soc_blitter_exec(g_blitter, &op);
}
EXPORT_SYMBOL_GPL(loongson_soc_blitter_copy);
```

- [ ] **Step 3: 构建验证**

```bash
make ARCH=loongarch CROSS_COMPILE=loongarch32-linux-gnusf- -j$(nproc)
```

Expected: 编译通过。

- [ ] **Step 4: 提交**

```bash
git add drivers/video/fbdev/loongson_soc_blitter.c
git commit -m "fbdev: blitter: add ioctl and exported fill/copy API"
```

---

### Task 5: VGA fbdev 加速钩子

**Files:**
- Modify: `drivers/video/fbdev/loongson_soc_vga.c`

**Interfaces:**
- Consumes: `loongson_soc_blitter_available/fill/copy` from Task 4.
- Produces: `.fb_fillrect = loongson_soc_vga_fillrect`, `.fb_copyarea = loongson_soc_vga_copyarea`。

- [ ] **Step 1: 实现约束判断与回退**

```c
static bool loongson_soc_vga_blit_can_accel(const struct fb_info *info,
					    unsigned int x, unsigned int y,
					    unsigned int width, unsigned int height,
					    bool copy)
{
	if (!loongson_soc_blitter_available())
		return false;
	if (in_interrupt() || in_atomic())
		return false;
	if (width == 0 || height == 0)
		return false;
	if (width & 1)
		return false;
	if (x & 1)
		return false;
	if (y + height > info->var.yres_virtual)
		return false;
	return true;
}
```

- [ ] **Step 2: 实现 fillrect**

```c
static void loongson_soc_vga_fillrect(struct fb_info *info,
				      const struct fb_fillrect *rect)
{
	u32 dst_addr;
	u32 color;

	if (!loongson_soc_vga_blit_can_accel(info, rect->dx, rect->dy,
					     rect->width, rect->height, false)) {
		sys_fillrect(info, rect);
		return;
	}

	dst_addr = info->fix.smem_start +
		   rect->dy * info->fix.line_length + rect->dx * 2;
	color = ((u32)rect->color & 0xffff);

	if (loongson_soc_blitter_fill(dst_addr, info->fix.line_length,
				      rect->width, rect->height, color))
		sys_fillrect(info, rect);
}
```

- [ ] **Step 3: 实现 copyarea**

```c
static void loongson_soc_vga_copyarea(struct fb_info *info,
				      const struct fb_copyarea *area)
{
	u32 src_addr;
	u32 dst_addr;

	if (!loongson_soc_vga_blit_can_accel(info, area->dx, area->dy,
					     area->width, area->height, true)) {
		sys_copyarea(info, area);
		return;
	}

	/* Blitter 不保证重叠 COPY 正确，重叠时回退软件 */
	if (area->sx < area->dx + area->width &&
	    area->dx < area->sx + area->width &&
	    area->sy < area->dy + area->height &&
	    area->dy < area->sy + area->height) {
		sys_copyarea(info, area);
		return;
	}

	src_addr = info->fix.smem_start +
		   area->sy * info->fix.line_length + area->sx * 2;
	dst_addr = info->fix.smem_start +
		   area->dy * info->fix.line_length + area->dx * 2;

	if (loongson_soc_blitter_copy(src_addr, info->fix.line_length,
				      dst_addr, info->fix.line_length,
				      area->width, area->height))
		sys_copyarea(info, area);
}
```

- [ ] **Step 4: 替换 fb_ops**

在 `loongson_soc_vga_ops` 中：

```c
	.fb_fillrect	= loongson_soc_vga_fillrect,
	.fb_copyarea	= loongson_soc_vga_copyarea,
```

- [ ] **Step 5: 坐标语义**

已确认：`sys_fillrect`/`sys_copyarea` 使用 `screen_buffer` 起始地址，坐标中不包含 `var.yoffset`；因此硬件地址同样不添加 `var.yoffset`。

- [ ] **Step 6: 构建验证**

```bash
make ARCH=loongarch CROSS_COMPILE=loongarch32-linux-gnusf- -j$(nproc)
```

Expected: 编译通过。

- [ ] **Step 7: 提交**

```bash
git add drivers/video/fbdev/loongson_soc_vga.c
git commit -m "fbdev: loongson-soc-vga: use blitter for fillrect/copyarea"
```

---

### Task 6: 用户态验证工具

**Files:**
- Modify: `integration/tools/fb_bench.c`

**Interfaces:**
- Consumes: `/dev/blitter`, `BLITTER_IOCTL_FILL`, `BLITTER_IOCTL_COPY`, `/dev/fb0` 的 `FBIOGET_FSCREENINFO`。

- [ ] **Step 1: 增加 `blit` 模式**

在 `enum mode` 增加 `MODE_BLIT`，解析 `argv[1] == "blit"`。打开 `/dev/blitter`：

```c
int blt_fd = open("/dev/blitter", O_RDWR);
if (blt_fd < 0) { perror("open /dev/blitter"); return 1; }
```

每帧用 ioctl 做 FILL 和 COPY，测量 FPS：

```c
struct blitter_op op = {
	.op = 0,
	.dst_addr = fix.smem_start + 480 * fix.line_length, /* back buffer */
	.dst_stride = fix.line_length,
	.width = 640,
	.height = 480,
	.color = 0xF800,
};
if (ioctl(blt_fd, BLITTER_IOCTL_FILL, &op) < 0) { perror("FILL"); break; }
```

- [ ] **Step 2: 构建并放到 rootfs**

按集成仓库现有 `fb_bench` 构建方式编译，放入 rootfs overlay。

- [ ] **Step 3: 提交**

```bash
git add integration/tools/fb_bench.c
git commit -m "fb_bench: add blit mode using /dev/blitter"
```

---

### Task 7: 上板验证

- [ ] **Step 1: 确认 bitstream 包含 IRQ 接线**

检查 `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\2023.2\system_run.runs\impl_1\soc_top.bit` 是否存在且由最新 RTL 生成；必要时重跑 `tmp/run_blitter_build.tcl`。

- [ ] **Step 2: 验证 `/dev/blitter` 存在**

```sh
ls -l /dev/blitter
```

- [ ] **Step 3: FILL/COPY 正确性**

```sh
fb_bench blit
```

并配合 U-Boot 或直接写显存图案确认屏幕矩形正确。

- [ ] **Step 4: 与 VGA DMA 共存**

- 让 VGA 控制台/`fb_bench display` 持续运行；
- 同时反复跑 `fb_bench blit`；
- 确认无花屏、无闪屏、无卡死、无超时。

- [ ] **Step 5: 长时间稳定性**

连续运行 10 分钟以上，观察无中断风暴、无 `-ETIMEDOUT`、无 ERR。

---

### Task 8: 文档更新

**Files:**
- Modify: `doc/HANDOFF_VGA_DOOM.md`
- Modify: `doc/VGA_DOOM_PLAN.md`

- [ ] **Step 1: 更新 Phase 4B 状态**

把状态从“未开始”改为“已实现/验证中”，记录驱动路径、DTS、ioctl、fb 钩子、验证结果。

- [ ] **Step 2: 提交**

```bash
git add doc/HANDOFF_VGA_DOOM.md doc/VGA_DOOM_PLAN.md
git commit -m "docs: update blitter Linux driver status"
```

---

## 风险与对策

| 风险 | 对策 |
|---|---|
| 当前 bitstream 未包含 IRQ 接线 | 驱动有超时轮询回退，仍可工作；上板前确认 bitstream |
| cached 配置写回顺序不被硬件正确接收 | 若 FILL/COPY 不启动，临时把 `blt->cfg` 改为 uncached 单拍写定位 |
| fb_fillrect/fb_copyarea 在原子上下文被调用 | `in_interrupt() || in_atomic()` 时回退软件实现 |
| COPY 重叠导致花屏 | 检测重叠并回退 `sys_copyarea` |
| VGA DMA 与 Blitter 争带宽 | 上板压测；必要时限制单次矩形大小或加延时 |
| `/dev/blitter` 用户态无法获得物理地址 | 通过 `/dev/fb0` 的 `FBIOGET_FSCREENINFO` 获取 `smem_start`；DOOM 使用双缓冲中的 back buffer 作为 shadow |

## 执行方式

计划完成后，两种执行方式：

1. **Subagent-Driven（推荐）**：每个 Task 派发独立 subagent，任务间做 review。
2. **Inline Execution**：在当前会话按 Task 顺序执行，checkpoint 处暂停确认。
