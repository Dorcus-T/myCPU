# VGA 显示 + DOOM 移植实施计划

> 目标：在当前 chiplab Loongson FPGA 工程上增加 VGA 显示通路，写出 Linux framebuffer 驱动，最终移植 DOOM。
> 前提：允许修改 FPGA 工程（RTL + XDC + IP），不要求保持 bitstream 不变。

---

## 关键工程与文件位置

### 1. FPGA 侧（Windows 路径）

> 注意：Vivado 工程里 CPU 的 myCPU 文件是通过绝对路径 `Z:\home\dorcus_t\chiplab\IP\myCPU` 引用的；而 `soc_top.v`、XDC、AMBA/APB 等 IP 是通过工程相对路径引用 `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab` 下的文件。改文件前先打开 `system_run.xpr` 搜索 `File Path` 确认实际引用的是哪一份。
>
> WSL 下访问上述 C 盘路径时使用：`/c/Users/16622.DESKTOP-5S661OC/.claude/tmp/chiplab/...`。

| 作用 | 路径 |
|---|---|
| Vivado 工程入口 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\2023.2\system_run.xpr` |
| SoC 顶层 RTL | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\chip\soc_demo\loongson\soc_top.v` |
| FPGA 引脚约束 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\soc_up.xdc` |
| AXI 地址译码/从端口 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\AMBA\axi_mux_syn.v` |
| DDR3 AXI 互联 IP | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\axi_interconnect_0\axi_interconnect_0.xci` |
| PLL IP（产生 VGA 像素时钟） | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\clk_pll_33\clk_pll_33.xci` |
| 现有 DMA 控制器参考 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\DMA\dma.v` |
| 通用 IP 目录 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\` |
| 建议新增 RTL 目录 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\VGA\` |
| 2D Blitter RTL | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\blitter.v` |

### 2. Linux 内核侧（Windows UNC / WSL 路径）

| 作用 | Windows UNC 路径 | WSL 路径 |
|---|---|---|
| 内核源码根目录 | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\src\linux` | `/home/dorcus_t/la32r-upstream-integration/src/linux` |
| 平台设备树 | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\src\linux\arch\loongarch\boot\dts\loongson-soc.dts` | `/home/dorcus_t/la32r-upstream-integration/src/linux/arch/loongarch/boot/dts/loongson-soc.dts` |
| LoongArch defconfig | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\src\linux\arch\loongarch\configs\loongson_soc_defconfig` | `/home/dorcus_t/la32r-upstream-integration/src/linux/arch/loongarch/configs/loongson_soc_defconfig` |
| 建议新增 framebuffer 驱动 | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\src\linux\drivers\video\fbdev\loongson_soc_vga.c` | `/home/dorcus_t/la32r-upstream-integration/src/linux/drivers/video/fbdev/loongson_soc_vga.c` |
| Buildroot rootfs overlay | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\integration\buildroot\rootfs-overlay` | `/home/dorcus_t/la32r-upstream-integration/integration/buildroot/rootfs-overlay` |
| 内核构建脚本 | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\integration\scripts\build-kernel.sh` | `/home/dorcus_t/la32r-upstream-integration/integration/scripts/build-kernel.sh` |
| 版本锁定文件 | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\integration\versions.env` | `/home/dorcus_t/la32r-upstream-integration/integration/versions.env` |
| DOOM 可执行/资源建议位置 | `\\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\integration\buildroot\rootfs-overlay\usr\share\doom` | `/home/dorcus_t/la32r-upstream-integration/integration/buildroot/rootfs-overlay/usr/share/doom` |

---

## 总体架构

```text
CPU (myCPU)
   │
   ├── AXI 从端口：配置 VGA/DMA 寄存器
   │
   └── DDR3
          ▲
          │ AXI 读突发
   ┌──────┴──────┐
   │ 显示 DMA    │
   │ (FPGA 内)   │
   └──────┬──────┘
          │ 像素 FIFO
   ┌──────┴──────┐
   │ VGA 控制器  │
   └──────┬──────┘
          │ RGB + hsync + vsync
        VGA 显示器
```

---

## Phase 0：硬件摸底

**目标**：确认 VGA 引脚、像素时钟、显存地址。

### 任务

1. 查板卡原理图或 EGO1 官方 XDC，确认 VGA 引脚名：
   - `vga_r[3:0]` / `vga_g[3:0]` / `vga_b[3:0]`
   - `vga_hsync`
   - `vga_vsync`
2. 把 VGA 引脚加入：

   ```text
   C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\soc_up.xdc
   ```

   示例：

   ```tcl
   set_property PACKAGE_PIN xxx [get_ports {vga_r[0]}]
   set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[*]}]
   ...
   ```

3. 确定 VGA 像素时钟：
   - 先选 640×480@60Hz，像素时钟约 25.175 MHz。
   - 扩展 `clk_pll_33` 或使用 100 MHz 四分频得到 25 MHz。
4. 预留显存：
   - 建议 DDR3 地址 `0x06000000`，大小 8 MiB。
   - 后续在 Linux DTS 里用 `reserved-memory` 排除。

### 涉及文件

- `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\soc_up.xdc`
- `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\clk_pll_33\clk_pll_33.xci`

### 验收

- Vivado 能识别 VGA 端口；
- XDC 无语法错误。

---

## Phase 1：VGA 控制器 + 彩色条纹（不接 CPU）

**目标**：先让显示器显示彩色条纹。

### 任务

1. 新建 `vga_ctrl.v`：
   - 生成 `hsync`、`vsync`、`de`；
   - 内部计数器生成彩色条纹；
   - 不读内存。
2. 在 `soc_top.v` 例化 VGA 控制器，把端口引到顶层。
3. 像素时钟先用 25 MHz。
4. 综合、生成 bitstream、上板。

### 涉及文件

- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\VGA\vga_ctrl.v`
- 修改：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\chip\soc_demo\loongson\soc_top.v`
- 修改：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\soc_up.xdc`

### 验收

- 显示器出现稳定彩色条纹；
- 无花屏、无滚动、无偏移。

---

## Phase 2：显示 DMA + DDR3 通路

**目标**：验证“内存 → DMA → VGA”。

### 任务

1. 新建 `vga_dma.v`：
   - AXI 读主端口，从 DDR3 读显存；
   - FIFO 缓存像素；
   - 固定读地址 `0x06000000`，暂不接 CPU 控制。
2. 把显示 DMA 的 AXI 主端口接入 DDR3 AXI 互联：
   - 修改 `axi_interconnect_0.xci`，增加 S03 从端口；
   - 或在 `soc_top.v` 中把显示 DMA 接到现有互联。
3. 先在 Verilator 仿真验证，再上板。
4. 用 U-Boot 或仿真往 `0x06000000` 写已知颜色数据。

### 涉及文件

- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\VGA\vga_dma.v`
- 修改：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\chip\soc_demo\loongson\soc_top.v`
- 修改：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\axi_interconnect_0\axi_interconnect_0.xci`
- 参考：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\DMA\dma.v`

### 验收

- 显示器显示 DDR3 中写入的图案；
- 修改显存内容，画面变化。

---

## Phase 3：VGA/DMA 寄存器接入 CPU

**目标**：CPU 能配置 VGA/DMA。

### 任务

1. 给 VGA/DMA 增加 AXI-Lite / APB 从端口，寄存器建议：

   ```text
   0x00  FB_ADDR    显存基地址
   0x04  FB_STRIDE  每行字节数
   0x08  CTRL       使能/分辨率选择
   0x0C  STATUS     状态/中断
   ```

2. 地址分配建议：
   - 避开现有 `0x1fe0xxxx`、`0x1fd0xxxx`、`0x1ff0xxxx`；
   - 建议映射到 `0x1fe90000`。
3. 修改 AXI 地址译码：

   ```text
   C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\AMBA\axi_mux_syn.v
   ```

   增加 VGA 从端口和地址命中。
4. 修改 `soc_top.v` 例化寄存器控制模块。
5. U-Boot 验证：

   ```text
   mw.l 0x9fe90000 0x06000000
   mw.l 0x9fe90008 1
   ```

### 涉及文件

- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\VGA\vga_regs.v`
- 修改：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\AMBA\axi_mux_syn.v`
- 修改：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\chip\soc_demo\loongson\soc_top.v`

### 验收

- CPU 写寄存器能启动/停止显示；
- 改显存地址后画面切换。

---

## Phase 3B：2D Blitter 硬件集成（2dbitter）

> 状态：🔄 接近完成（截至 2026-08-19 v2）。RTL 新布局 + 仿真全 PASS；bitstream 曾成功生成，当前需重新确认。

### 目标

在 FPGA 中增加 2D Blitter（Fill + Copy）硬件加速器，CPU 可通过寄存器配置，加速 framebuffer 矩形填充/拷贝。

### 当前已完成

1. `IP\BLITTER\blitter.v`：Fill + Copy，寄存器物理 `0x1fea0000`，**新布局**：
   - `0x00 SRC_ADDR` / `0x04 DST_ADDR` / `0x08 SRC_STRIDE` / `0x0C DST_STRIDE`
   - `0x10 WIDTH` / `0x14 HEIGHT` / `0x18 COLOR` / `0x1C CTRL` / `0x20 STATUS`
   - 约束：WIDTH 偶数；地址 4 字节对齐；strides 为字节数
   - 启动语义：写 CTRL 且 bit0=1 即启动，自动清 DONE/ERR
2. `axi_mux_syn.v`：从口 6→7，s6 decode `0x1fea`，写响应 round-robin
3. `soc_top.v`：例化 blitter，寄存器接 s6，AXI master 接 `axi_interconnect_0` S04
4. `axi_interconnect_0.xci`：`NUM_SLAVE_PORTS=5`，`S04_AXI_IS_ACLK_ASYNC=1`
5. `system_run.xpr` 已注册 `blitter.v`
6. 仿真：`tmp/blitter_wlast_tb.v` 本次复核在 WSL 重新编译运行，输出 **`PASS: blitter_wlast_tb all ok`**；旧 `tmp/blitter_tb.v` 也 PASS
7. 软件适配参考：`IP\BLITTER\README.md`（寄存器、cached 写流程、中断、fbdev 钩子、ioctl 建议、U-Boot 命令）
8. 显示偏移已解决（硬件帧同步修复，见 HANDOFF 2.5）

### 待办（接近完成，剩收尾）

1. 确认/重新生成 bitstream：03:09 曾 `write_bitstream completed successfully`，但当前 `impl_1` 无 `.bit`；09:19 新一轮实现未完成，需重跑 `tmp/run_blitter_build.tcl` 或确认该轮产物
2. 上板验证 Blitter FILL/COPY（新布局命令见 `tmp/blitter_uboot_cmds.txt`）
3. 确认时序满足（09:19 route 后 WNS=0.978 / TNS=0；60MHz 配置仍在）
4. 验证与 VGA DMA 同时工作的带宽/稳定性

### 涉及文件

- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\blitter.v`
- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\README.md`
- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\tmp\blitter_wlast_tb.v`
- 新增：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\tmp\blitter_uboot_cmds.txt`
- 修改：`...\IP\AMBA\axi_mux_syn.v`
- 修改：`...\chip\soc_demo\loongson\soc_top.v`
- 修改：`...\IP\xilinx_ip\2023.2\axi_interconnect_0\axi_interconnect_0.xci`

### 验收

- 生成含 blitter 的 bitstream；
- U-Boot 用 `0x9fea0000` 新布局配置 Fill/Copy，显存图案正确变化。

---

## Phase 4：Linux framebuffer 驱动

**目标**：Linux 启动后出现 `/dev/fb0`，VGA 显示控制台。

### 任务

1. 修改设备树：

   ```text
   \\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\src\linux\arch\loongarch\boot\dts\loongson-soc.dts
   ```

   增加：

   ```dts
   reserved-memory {
       #address-cells = <1>;
       #size-cells = <1>;
       ranges;

       framebuffer@06000000 {
           reg = <0x06000000 0x00800000>;
           no-map;
       };
   };

   vga@1fe90000 {
       compatible = "loongson-edu,vga";
       reg = <0x1fe90000 0x1000>;
       interrupts = <...>;
       status = "okay";
   };
   ```

2. 驱动二选一：
   - 简单：`simple-framebuffer`，只改 DTS。
   - 完整：新增 `loongson_soc_vga.c`，注册 `struct fb_info`，配置 DMA 寄存器。
3. 修改 defconfig：

   ```text
   \\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\src\linux\arch\loongarch\configs\loongson_soc_defconfig
   ```

   打开：

   ```text
   CONFIG_FB=y
   CONFIG_FB_LOONGSON_SOC_VGA=y
   CONFIG_FRAMEBUFFER_CONSOLE=y
   CONFIG_LOGO=y
   ```

4. 注意 Cache 一致性：当前驱动已实现 cached 映射（ioremap_cache）+ 每帧 CACOP 写回 + 双缓冲（FBIOPAN_DISPLAY）；备选方案是 uncached / write-combine 映射。

### 涉及文件

- 修改：`...\src\linux\arch\loongarch\boot\dts\loongson-soc.dts`
- 修改：`...\src\linux\arch\loongarch\configs\loongson_soc_defconfig`
- 新增：`...\src\linux\drivers\video\fbdev\loongson_soc_vga.c`
- 修改：`...\src\linux\drivers\video\fbdev\Kconfig`
- 修改：`...\src\linux\drivers\video\fbdev\Makefile`

### 验收

- 启动时 VGA 出现 Linux logo 或控制台；
- `ls /dev/fb0` 存在；
- `cat /dev/urandom > /dev/fb0` 屏幕出现噪点。

---

## Phase 4B：2D Blitter 软件适配

> 状态：✅ 代码/构建完成（2026-08-19），待上板验证。依赖 Phase 3B 硬件 bitstream。
> 权威软件适配参考：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\README.md`。
> 实施计划：`Z:\home\dorcus_t\chiplab\IP\myCPU\doc\PLAN_BLITTER_LINUX_DRIVER.md`。

### 目标

让 Linux 软件层能使用 2D Blitter 加速 framebuffer 的矩形填充/拷贝，最终为 DOOM 的 320×200→640×480 放大和画面绘制提供硬件加速。

### 任务

1. **设备树**（✅ 已实现）
   - 在 `loongson-soc.dts` 增加：
     ```dts
     blitter@1fea0000 {
         compatible = "loongson-edu,blitter";
         reg = <0x1fea0000 0x100>;
         status = "okay";
     };
     ```
2. **内核驱动（✅ 已实现：独立驱动 + VGA fb 加速钩子）**
   - 方案 A（推荐先做）：扩展 `loongson_soc_vga.c`，实现 `fb_fillrect` / `fb_copyarea` / `fb_imageblit` 中的 Fill/Copy 走 blitter；软件回退保留。
   - 方案 B：新增 `loongson_soc_blitter.c`，注册 misc/char 设备 `/dev/blitter`，提供 ioctl：`BLITTER_IOCTL_FILL` / `BLITTER_IOCTL_COPY`。
   - 寄存器布局按 README：`0x00 SRC_ADDR` / `0x04 DST_ADDR` / `0x08 SRC_STRIDE` / `0x0C DST_STRIDE` / `0x10 WIDTH` / `0x14 HEIGHT` / `0x18 COLOR` / `0x1C CTRL` / `0x20 STATUS`。
   - 启动语义：写 CTRL 且 bit0=1 即启动，自动清 DONE/ERR；提交路径不要忙等，用中断或 `fb_sync` 异步等待。
3. **Cache 一致性**（✅ 已实现 cached+cacop + 区间 flush）
   - 配置寄存器可 cached 写：`0x00~0x1C` 是一条 32B cache line，CTRL 在最高地址，配置后 `cacop 0x2` 写回整条 line；STATUS 在 `0x20` 用 uncached 读。
   - FILL/COPY 前：源区域若由 CPU 写入，需 `flush_dcache_range` / `dma_sync_single_for_device`；
   - FILL/COPY 后：CPU 读目标区域前需 `invalidate_dcache_range`。
4. **用户态工具 / 基准**（✅ 已实现 `fb_bench blit`）
   - 扩展 `fb_bench` 增加 `blit` 模式：Fill/Copy 吞吐测试；
   - 可选新增 `blit_test` 小工具。
5. **DOOM 后端接入**
   - 在 doomgeneric 的 framebuffer 后端中，对清屏、矩形填充、整块拷贝（如放大/翻页）优先调用 blitter ioctl 或 fb 加速钩子。
6. **验收**
   - `fb_bench blit` 能正确 Fill/Copy 且比逐像素快；
   - DOOM 画面矩形操作正确、无明显撕裂/错位；
   - 长时间运行无缓存一致性问题。

### 涉及文件

- 参考：`...\IP\BLITTER\README.md`
- 修改：`...\src\linux\arch\loongarch\boot\dts\loongson-soc.dts`
- 新增：`...\src\linux\drivers\video\fbdev\loongson_soc_blitter.c` / `loongson_soc_blitter.h`\n- 修改：`...\src\linux\drivers\video\fbdev\loongson_soc_vga.c`
- 修改：`...\src\linux\drivers\video\fbdev\Kconfig` / `Makefile`
- 修改：`...\src\linux\arch\loongarch\configs\loongson_soc_defconfig`
- 修改：`...\integration\tools\fb_bench.c`

### 验收

- `/dev/fb0` 的 fillrect/copyarea 被 blitter 加速（可通过 fb_bench 或 ftrace 确认）；
- 或 `/dev/blitter` ioctl 可用；
- DOOM 使用加速后帧率提升或至少不劣化。

---

## Phase 5：键盘输入（DOOM 必需）

**目标**：DOOM 能用键盘操作。

### 任务

1. 优先使用现有 4×4 矩阵键盘。
2. 在 CONFREG 驱动中把矩阵键盘上报为 Linux input 事件：

   ```text
   /dev/input/event0
   ```

3. 映射 WASD、方向键、空格、Ctrl、Shift、Enter。
4. 如要真实 PS/2 键盘，再在 FPGA 加 PS/2 控制器，Linux 开 `CONFIG_SERIO_I8042`。

### 涉及文件

- 新增：`...\src\linux\drivers\input\keyboard\loongson_soc_matrix_keypad.c`（或并入 CONFREG 驱动）
- 修改：`...\src\linux\arch\loongarch\boot\dts\loongson-soc.dts`
- 修改：`...\src\linux\arch\loongarch\configs\loongson_soc_defconfig`

### 验收

- `evtest /dev/input/event0` 能看到按键事件。

---

## Phase 6：DOOM 移植

**目标**：在 LA32 Linux 上跑 DOOM。

### 任务

1. 选 DOOM 版本：
   - 首选 `doomgeneric`；
   - 备选 `chocolate-doom` / `prboom-plus`。
2. 视频后端：输出到 `/dev/fb0`，320×200 放大 2 倍到 640×480。
3. 输入后端：读 `/dev/input/eventX`。
4. 交叉编译：

   ```text
   loongarch32-linux-gnusf-gcc
   ```

5. 放入 Buildroot initramfs：

   ```text
   \\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\integration\buildroot\rootfs-overlay\usr\share\doom\
   \\wsl.localhost\Ubuntu-22.04\home\dorcus_t\la32r-upstream-integration\integration\buildroot\rootfs-overlay\usr\bin\doom
   ```

6. 加启动脚本。

### 涉及文件

- 修改：`...\integration\buildroot\rootfs-overlay\etc\init.d\S99doom`
- 新增：`...\integration\buildroot\rootfs-overlay\usr\bin\doom`
- 新增：`...\integration\buildroot\rootfs-overlay\usr\share\doom\doom.wad`

### 验收

- 运行 `doom` 后出现游戏画面；
- 键盘操作正常；
- 帧率可接受。

---

## Phase 7：集成与回归

**目标**：固化所有改动。

### 任务

1. FPGA 侧：
   - 确认 `soc_top.v`、`soc_up.xdc`、新增 IP 纳入版本管理；
   - 完整综合、实现、生成 bitstream。
2. Linux 侧：
   - 提交内核改动；
   - 更新 `integration/versions.env` 中内核 commit；
   - 重新跑 `build-kernel.sh`。
3. 回归验证：
   - 串口登录正常；
   - VGA 控制台正常；
   - 网卡正常；
   - DOOM 可玩。

### 涉及文件

- `...\integration\versions.env`
- `...\integration\scripts\build-kernel.sh`

---

## 关键风险

| 风险 | 应对 |
|---|---|
| VGA 引脚定义找不到 | 查板卡原理图/官方 XDC，不要猜引脚 |
| 像素时钟不标准导致黑屏 | 先 640×480@60，25 MHz |
| DMA 带宽不够导致闪屏 | AXI burst + FIFO，一次读多行 |
| CPU Cache 和 DMA 不一致 | 当前用 cached+CACOP 写回；备选 uncached/write-combine 映射 |
| Linux framebuffer 格式不匹配 | 统一 RGB565 |
| DOOM 在软浮点上太慢 | 320×200 + 硬件 2× 放大 |
| 键盘不够用 | 先矩阵键盘，不行再加 PS/2 |
| Blitter 与 CPU cache 不一致 | 软件适配时对源/目标区间做 CACOP flush/invalidate |
| Blitter 与 VGA DMA 争带宽 | 上板压测，必要时限制 burst/FIFO 深度 |
| Blitter bitstream 未生成 | 重新跑 run_blitter_build.tcl，先确认综合/实现/写 bitstream |

---

## 里程碑顺序

1. **M1**：VGA 彩条点亮。
2. **M2**：DMA 从 DDR3 读显存并显示。
3. **M3**：CPU 能配置 VGA/DMA。
4. **M4**：Linux `/dev/fb0` + 控制台显示。
5. **M5**：键盘输入可用。
6. **M5B**：Blitter bitstream 生成并上板 Fill/Copy 验证。
7. **M5C**：Linux 软件层可使用 Blitter（fb 加速或 /dev/blitter）。
8. **M6**：DOOM 可运行。

