# Handoff: VGA 显示 + 2D 游戏（Snake）+ 2D Blitter（VGA_DOOM_PLAN.md）

> **本文件是当前唯一权威 handoff。** 2026-08-19 中期复核整理（v2），合并了此前散落在
> `~/.claude/tmp/chiplab/tmp/` 与 `%TEMP%` 的多份临时 handoff；那些临时文件不再维护，
> 仅作历史参考（清单见文末）。
>
> - 完整计划：`Z:\home\dorcus_t\chiplab\IP\myCPU\doc\VGA_DOOM_PLAN.md`
> - 2D Blitter 软件适配参考：`C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\README.md`
> - OpenViking：未检索到已存 VGA/blitter 记忆（本次复核 `viking_search` 无结果），关键结论以本文件为准。
> - 方案变更：2026-08-19 由 DOOM 3D 移植调整为轻量 2D 贪吃蛇（Snake），原因：60MHz LA32 顺序流水线跑 3D 不现实。

---

## 1. 当前进度总览（2026-08-19 v2 复核后）

| 阶段 | 状态 | 说明 |
|---|---|---|
| Phase 0 硬件摸底 | ✅ 完成 | 板卡 = 龙芯实验箱 FPGA-A7-PRJ-UDB（XC7A200T-FBG676-2），非 EGO1 |
| Phase 1 VGA 彩条 | ✅ 完成 | 已上板验证（依据既有记录） |
| Phase 2 DMA + DDR3 | ✅ 完成 | 已上板验证；cache 一致性用 CACOP（依据既有记录） |
| Phase 3 VGA/DMA 寄存器接入 CPU | ✅ 完成 | 已上板验证；VGA regs @ `0x1fe90000`（依据既有记录） |
| Phase 3B 2D Blitter 硬件集成 | ✅ 已验证 | 12:10 bitstream 已生成；Blitter FILL/COPY 驱动已上板验证 |
| Phase 4 Linux framebuffer 驱动 | ✅ 代码/构建完成 | 待上板最终确认 |
| Phase 5 键盘输入（矩阵 + PS/2 + USB HID） | ✅ 代码/构建完成 | 矩阵/PS2/USB 键盘驱动均已接入；待新 bitstream 上板验证 |
| Phase 6 Snake 2D 游戏 | 🔄 构建完成待上板 | `integration/tools/snake.c` → `/usr/bin/snake`，已重建 `build/linux-loongson-soc/vmlinux`（17M，含 snake）；支持三缓冲（VGA_FB_BUFFERS=3）、墙体、分数、dirty-rect、渲染线程；待上板验证 |
| Phase 7 集成回归 | ⏸️ 未开始 | Snake + VGA + 键盘 + Blitter 回归 |
| 2D Blitter 软件适配 | ✅ 已验证 | 独立驱动 + VGA fb 加速钩子已上板验证 |

**显示偏移：已解决**（硬件问题，FPGA 帧同步修复，见 2.5）。

---

## 2. 本次复核确认的真实状态

以下状态已通过文件系统 / git / 日志 / 仿真复核，可作为接续依据。

### 2.1 内核侧（WSL）

- 分支：`vga-both-keyboards`
- HEAD：`c5dacab541e285b892814d29af5fb83d09b19789`（2026-08-19，短号 `c5dacab`）
  - `bd72980` `fbdev: loongson-soc-vga: triple buffering with async flip`
  - 前序提交（本会话新增）：
    - `5594de2` defconfig 保留 fbcon/logo，默认关光标（`vt.global_cursor_default=0`）
    - `f6b6318` 移除 COPY 拆分 workaround（RTL 已修 `remain_words`）
    - `84dbcde` / `52e1c1b` blitter 风格与寄存器偏移修复
    - `3c6762d` / `92ae7a0` / `4e77e0c` VGA fb 加速钩子、blitter 驱动、DTS/config
- VGA 驱动：`drivers/video/fbdev/loongson_soc_vga.c`
  - 已实现：`ioremap_cache`、`fb_pan_display`、`fb_sync`、60Hz flush timer、**三缓冲**（`VGA_FB_BUFFERS=3`）
  - **新增**：`fb_pan_display` 异步 flip（不忙等），配合硬件单帧 pending swap；三缓冲轮转由 `fb_bench`/应用负责
- 键盘驱动：`loongson_soc_matrix_keypad.c` + `loongson_soc_ps2.c` + `loongson_soc_usb_kbd.c`
- DTS：`loongson-soc.dts` 含 `vga@1fe90000`、`blitter@1fea0000`、`usb-kbd@1feb0000`、`keyboard@1fd0f040`（PS/2）、`keyboard@1fd0f024`（矩阵）
- defconfig：`CONFIG_FB_LOONGSON_SOC_VGA=y`、`CONFIG_FB_LOONGSON_SOC_BLITTER=y`、`CONFIG_KEYBOARD_LOONGSON_SOC_USB=y`、`CONFIG_FRAMEBUFFER_CONSOLE=y`、`CONFIG_LOGO=y`，cmdline 含 `vt.global_cursor_default=0`
- **Blitter 软件适配已实现并上板验证**：DTS 含 `blitter@1fea0000`，新增 `loongson_soc_blitter.c/.h`（`/dev/blitter` + 导出 API），VGA fbdev `fb_fillrect`/`fb_copyarea` 已接入 blitter；`fb_bench` 支持 `blit`（每帧交替棋盘格）、`fill`（单次整屏 FILL）、`copy`（单次整屏 COPY）。

### 2.2 集成仓库（WSL）

- 分支：`blitter-linux-driver`
- HEAD：`9790fb9`（2026-08-19，`integration: bump LINUX_COMMIT to c5dacab`）
  - 相关提交：`3616c0b`（bump to bd72980）、`e76105a`（fb_bench blit 每帧交替棋盘格）、`e15bc45`（fill/copy 模式）、`ff274f7`（真双缓冲）、`410256b`（棋盘格）、`0f94ea2`（禁用 VGA getty + bump）
- 已包含：`BR2_PACKAGE_SCREEN=y`、`S99tty1`（已改为 no-op，VGA 不再启动 getty）、`fb_bench`、`versions.env` 指向内核 `bd72980`
- 完整 vmlinux：`/home/dorcus_t/la32r-upstream-integration/build/linux-loongson-soc/vmlinux`
  - **16 MiB**（2026-08-19 13:19 构建）
  - 含 initramfs、fb_bench（`blit`/`fill`/`copy` 模式）

### 2.3 FPGA 侧（Windows `~/.claude/tmp/chiplab`）

- `IP/VGA/vga_regs.v` / `vga_dma.v` / `vga_ctrl.v`：存在
- `IP/BLITTER/blitter.v`：存在，已注册进 `system_run.xpr`
  - **当前寄存器布局（新布局，与 `IP/BLITTER/README.md` 一致）**：
    | 偏移 | 名称 | 说明 |
    |---|---|---|
    | `0x00` | SRC_ADDR | COPY 源地址（物理，4 字节对齐） |
    | `0x04` | DST_ADDR | FILL/COPY 目标地址 |
    | `0x08` | SRC_STRIDE | 源行距（字节） |
    | `0x0C` | DST_STRIDE | 目标行距（字节） |
    | `0x10` | WIDTH | 矩形宽度（像素，**必须偶数**） |
    | `0x14` | HEIGHT | 矩形高度（像素） |
    | `0x18` | COLOR | FILL 颜色（RGB565，低 16 位有效） |
    | `0x1C` | CTRL | bit0 START / bit1 OP(0=FILL,1=COPY) / bit2 IRQ_EN |
    | `0x20` | STATUS | bit0 BUSY / bit1 DONE / bit2 ERR |
  - 启动语义：写 CTRL 且 bit0=1 即启动，启动自动清 DONE/ERR；支持 cached 配置（`0x00~0x1C` 一条 32B cache line，CTRL 在最高地址，最后写回）
  - AXI 从方写 FIFO：8 深度 write-beat FIFO，WREADY 满才反压；B 在 W 最后一拍被 FIFO 接受时即返回（写完成=写入 FIFO），寄存器后台逐拍落位
  - 中断接线已修正：`blt_irq` 原未接入 CPU 中断；现接到 `int_out[5]` → `intrpt[5]` → ESTAT[7]
  - COPY 宽行卡死修复：`remain_words` 原用 8 位，剩余 256 words 时回绕算出 burst_len=255，COPY 因 32 深读 FIFO 永远等不到而卡死；改为 32 位计算后 640px（320 words）宽 COPY 仿真通过
  - 12:10 bitstream 已包含用户最新 PS/2 修改
  - 约束：WIDTH 偶数；地址 4 字节对齐；strides 为字节数
  - 仿真：`tmp/blitter_wlast_tb.v` 在 WSL 重新编译运行，输出 **`PASS: blitter_wlast_tb all ok`**（覆盖 FILL、COPY、重复 COPY、无自动重启、burst 配置 FILL）；旧 `tmp/blitter_tb.v` 也 PASS
- `IP/AMBA/axi_mux_syn.v`：`SLV_MUX_NUM` 6→7，s6 decode `0x1fea`，写响应 round-robin（已确认）
- `chip/soc_demo/loongson/soc_top.v`：blitter 例化、PS/2 顶层端口、VGA 默认 `FB_ADDR=0x06000000` / `FB_STRIDE=1280`（已确认）
  - **新增 pending swap 相关**：`vga_regs` 增加 `frame_start` 输入并输出 `status`；`vga_frame_start` 经 toggle 同步器转到 33MHz AXI 域（`vga_frame_start_axi`）
- `IP/VGA/vga_regs.v`：**两段式 pending swap（修正同拍竞争）**：
  - CPU 写 `0x00 FB_ADDR` 更新 `fb_addr_next`，置 `swap_pending=1`、`swap_commit=0`；
  - 第 1 个 `frame_start`：`fb_addr <= fb_addr_next`，置 `swap_commit=1`；第 2 个 `frame_start` 清 `swap_pending/swap_commit`；
  - `STATUS[0] = swap_pending`；`frame_start` 先于写分支，同拍写不会丢新 swap
- `IP/VGA/vga_dma.v`：**帧首立即清 FIFO/像素解包**：`frame_start` 时直接清 `wr_ptr/rd_ptr/fifo_cnt/pair_data/pair_cnt`，避免上一帧残留导致“向左平移一段”的伪影
  - `fb_base` 使用单 `fb_base_cur` 锁存：`frame_start` 时 `fb_base_cur <= fb_base`、`rd_addr <= fb_base`；当前帧 `fb_limit` 由 `fb_base_cur` 计算，避免帧中回绕异常；`dma_en=0` 时同步更新 cur
- `IP/CONFREG/confreg_syn.v`：PS/2 接收器 + 16 字节 FIFO，`0x1fd0f040` DATA / `0x1fd0f044` STATUS（已确认）
- `fpga/loongson/soc_up.xdc`：PS/2 pins `Y2`/`AD1` LVCMOS33（已确认）
- `IP/xilinx_ip/2023.2/clk_pll_33/clk_pll_33.xci`：`CLKOUT1_REQUESTED_OUT_FREQ=60.000`（CPU 60MHz）、`CLKOUT2=33.000`（已确认）
- `IP/xilinx_ip/2023.2/axi_interconnect_0/axi_interconnect_0.xci`：`NUM_SLAVE_PORTS=5`，`S04_AXI_IS_ACLK_ASYNC=1`（已确认）
- `IP/BLITTER/README.md`：**2D Blitter 软件适配参考**，含寄存器、编程流程、cached 写流程、中断、fbdev 钩子、ioctl 建议、U-Boot 命令

### 2.4 Bitstream 现状（重要）

- **12:10 bitstream 存在**：`system_run.runs/impl_1/soc_top.bit`，包含 Blitter 新寄存器布局、cache line burst 写、8 深度写 FIFO、中断接入 `intrpt[5]`→ESTAT[7]；**不包含最新单帧 pending swap、三缓冲、vga_dma 帧首清 FIFO**。
- **含最新 RTL 的 bitstream 尚未成功生成**：上次 `tmp/run_pending_swap_build.log` 中 `synth_1` 报 `ERROR: synthesis failed`（exit 1）；后续又改单帧 + vga_dma，需要重新综合。
- 时序参考：此前 route 后 WNS=0.978、TNS=0（最新 RTL 未跑完，不能作为该版本时序结论）。

### 2.5 显示偏移（已解决，硬件问题）

- 问题：早期每次烧写后 VGA 左上角位置随机，以及“小企鹅在左边中间”的显示偏移。
- 结论：**这是硬件问题**，修复在 FPGA 侧帧同步逻辑。
- 已确认 `IP/VGA/vga_dma.v` 中实现：
  - `frame_start` 后暂停发新读请求，等旧 burst 结束再清 FIFO；
  - 每帧开始时把读地址重置回 framebuffer 基地址；
  - 避免 DMA 读指针与 VGA 帧扫描不同步导致的偏移/撕裂。
- 内核驱动已改为三缓冲（`yres_virtual=1440`），显示偏移不再归因于软件配置。

---

## 3. 关键结论 / Gotcha

1. **板卡**：龙芯实验箱 FPGA-A7-PRJ-UDB（XC7A200T-FBG676-2），不是 EGO1。
2. **VGA 寄存器**（物理 `0x1fe90000`）：
   - `0x00 FB_ADDR` / `0x04 FB_STRIDE` / `0x08 CTRL` / `0x0C STATUS`
   - `CTRL[0]=1` 切 framebuffer/DMA，`=0` 回彩条
   - **新语义**：`FB_ADDR` 为 pending swap，硬件在 `frame_start` 才真正切换；`STATUS[0]=1` 表示 swap pending，驱动 flip 后需等它清零
3. **Blitter 寄存器**（物理 `0x1fea0000`）：见 2.3 新布局。
4. **U-Boot/裸机访问必须用直接映射别名**：
   - VGA 物理 `0x1fe90000` → uncached `0x9fe90000`
   - Blitter 物理 `0x1fea0000` → uncached `0x9fea0000`
   - Blitter STATUS 物理 `0x1fea0020` → uncached `0x9fea0020`
   - AXI 译码按物理地址
5. **Cache 一致性**：
   - `0xa0000000` cached / `0x80000000` uncached
   - 写显存用 cached + CACOP 写回，或临时 uncached；不要用 uncached 大批量写（效率低）
   - Blitter 配置寄存器可 cached 写（`0x00~0x1C` 一条 line，CTRL 最后写回 + `cacop 0x2`）；STATUS 应 uncached 读
   - FILL/COPY 前后需对源/目标区间做 DCache flush/invalidate（软件适配阶段实现）
6. **Vivado 时序**：route 后 WNS=0.978、TNS=0（09:19 那轮仍如此）；60MHz 配置保留。
7. **Vivado Sources `?`**：源文件需用 `add_files/remove_files` 注册，不要只手工改 `.xpr`。
8. **Xilinx IP 改动后**：手动改 `.xci` 后需 `upgrade_ip` → `reset_target all` → `generate_target all`，否则 IP 锁定。

---

## 4. 关键文件

### FPGA 侧

| 作用 | 路径 |
|---|---|
| Vivado 工程 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\2023.2\system_run.xpr` |
| SoC 顶层 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\chip\soc_demo\loongson\soc_top.v` |
| VGA RTL | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\VGA\vga_regs.v` / `vga_dma.v` / `vga_ctrl.v` |
| Blitter RTL | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\blitter.v` |
| Blitter README | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\BLITTER\README.md` |
| Blitter 上板命令 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\tmp\blitter_uboot_cmds.txt` |
| Blitter 仿真 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\tmp\blitter_wlast_tb.v`（新，推荐） / `blitter_tb.v`（旧） |
| AXI 译码 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\AMBA\axi_mux_syn.v` |
| 引脚约束 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\fpga\loongson\soc_up.xdc` |
| DDR3 互联 IP | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\axi_interconnect_0\axi_interconnect_0.xci` |
| PLL IP | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\IP\xilinx_ip\2023.2\clk_pll_33\clk_pll_33.xci` |
| Blitter 构建脚本/日志 | `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\tmp\run_blitter_build.tcl` / `blitter_build.log` |

### Linux 侧（WSL）

| 作用 | 路径 |
|---|---|
| 内核源码 | `/home/dorcus_t/la32r-upstream-integration/src/linux` |
| VGA 驱动 | `drivers/video/fbdev/loongson_soc_vga.c` |
| Blitter 驱动 | `drivers/video/fbdev/loongson_soc_blitter.c` / `.h` |
| Blitter DTS | `arch/loongarch/boot/dts/loongson-soc.dts` `blitter@1fea0000` |
| 矩阵键盘驱动 | `drivers/input/keyboard/loongson_soc_matrix_keypad.c` |
| PS/2 驱动 | `drivers/input/keyboard/loongson_soc_ps2.c` |
| USB HID 键盘驱动 | `drivers/input/keyboard/loongson_soc_usb_kbd.c` |
| DTS | `arch/loongarch/boot/dts/loongson-soc.dts` |
| defconfig | `arch/loongarch/configs/loongson_soc_defconfig` |
| 集成仓库 | `/home/dorcus_t/la32r-upstream-integration` |
| vmlinux | `/home/dorcus_t/la32r-upstream-integration/build/linux-loongson-soc/vmlinux` |
| fb_bench | `integration/tools/fb_bench.c` |
| Blitter 驱动计划 | `doc/PLAN_BLITTER_LINUX_DRIVER.md` |

---

## 5. 上板验证命令（新 Blitter 寄存器布局）

### VGA（已确认可用）

```text
mw.l 0x86000000 0xf800f800 0x10000   # 写显存红色图案
mw.l 0x9fe90000 0x06000000           # FB_ADDR
mw.l 0x9fe90004 0x00000500           # FB_STRIDE = 1280
mw.l 0x9fe90008 0x00000001           # CTRL = framebuffer/DMA
md.l 0x9fe90000 4
```

### Blitter FILL / COPY（新布局，完整命令见 `tmp/blitter_uboot_cmds.txt`）

```text
# FILL 200x100 红色 @ (100,100)
mw.l 0x9fea0004 0x0601f4c8   # DST_ADDR
mw.l 0x9fea000c 0x00000500   # DST_STRIDE = 1280
mw.l 0x9fea0010 0x000000c8   # WIDTH = 200
mw.l 0x9fea0014 0x00000064   # HEIGHT = 100
mw.l 0x9fea0018 0x0000f800   # COLOR = red
mw.l 0x9fea001c 0x00000001   # CTRL = FILL + START
md.l 0x9fea0020 1            # STATUS

# COPY 200x100 @ (300,200)
mw.l 0x9fea0000 0x06000000   # SRC_ADDR
mw.l 0x9fea0004 0x0603ea58   # DST_ADDR
mw.l 0x9fea0008 0x00000500   # SRC_STRIDE
mw.l 0x9fea000c 0x00000500   # DST_STRIDE
mw.l 0x9fea0010 0x000000c8   # WIDTH
mw.l 0x9fea0014 0x00000064   # HEIGHT
mw.l 0x9fea001c 0x00000003   # CTRL = COPY + START
md.l 0x9fea0020 1            # STATUS
```

---

## 6. 已知问题 / 待排查

1. **显示撕裂/上一帧左移伪影**：已实现单帧 pending swap + 三缓冲异步 flip + `vga_dma` 帧首清 FIFO；**待新 bitstream 上板验证**。
2. **含最新 RTL 的 bitstream 未生成成功**：`run_pending_swap_build.log` 中 `synth_1` 报 `ERROR: synthesis failed`，需先定位 synthesis 失败原因。
3. **fb_bench 性能**：`fill` 吞吐约为 `copy` 的 2 倍；红蓝整屏切换可达约 30fps；`blit` 为每帧交替棋盘格（48 次小 FILL + flip）；已改三缓冲轮转以降低 flip 等待影响。
4. **60MHz 稳定性**：此前 route 后 WNS=0.978 但未做长时间稳定性测试；pending swap 版本尚未跑完时序。
5. **PS/2 键盘待新 bitstream 验证**：已加 PULLUP（`soc_up.xdc`）+ PS/2 初始化只发一轮（`confreg_syn.v`），需重新生成 bitstream 后验证。
6. **Blitter 驱动**：✅ 已验证（FILL/COPY 与 fb 加速钩子）；显示撕裂收尾后再接 Snake。

---

## 7. 下一步（按优先级）

1. **重新生成含最新 RTL 的 bitstream**：单帧 pending swap + `vga_dma` 帧首清 FIFO + PS/2 修复；先查 `tmp/run_pending_swap_build.log` 中 synthesis 失败原因。
2. **上板验证**：
   - `/dev/fb0`、控制台/logo、`cat /dev/urandom > /dev/fb0` 出噪点；
   - `fb_bench blit`：确认交替棋盘格无撕裂、无“上一帧左移”伪影；
   - `fb_bench fill` / `fb_bench copy`：对比单次大操作吞吐；
   - 矩阵键盘 `/dev/input/event0`；PS/2 到手后验证；
   - PS/2 键盘：U-Boot `md.l 0x9fd0f044 1` 看 FIFO 计数，Linux `evtest /dev/input/eventX` 验证按键。
3. **Phase 6 Snake 2D 游戏**：✅ 代码已完成（`integration/tools/snake.c` → `/usr/bin/snake`）：显示完全走 Blitter FILL（无 mmap/pwrite），三缓冲 `FBIOPAN_DISPLAY`，游戏区 320×200（32×20 格 ×10px），读 evdev 方向键/WASD；待上板验证。
4. **Phase 4B 2D Blitter 软件适配**（✅ 已验证；参考 `IP/BLITTER/README.md` 与 `doc/PLAN_BLITTER_LINUX_DRIVER.md`）：
   - DTS 含 `blitter@1fea0000`；
   - 内核驱动：`loongson_soc_blitter.c`（`/dev/blitter` + 导出 API），VGA fb `fb_fillrect`/`fb_copyarea` 已接入；
   - 用户态：`fb_bench blit/fill/copy`，Snake/2D 游戏后端使用矩形填充/拷贝加速；
   - 注意 CPU DCache 与 blitter 的 flush/invalidate 配合。
5. **Phase 7 集成回归**：VGA 控制台、键盘、网卡、Snake 可玩、blitter 加速正确。

---

## 8. 已合并 / 已过时的旧 handoff

以下文件的内容已合并进本文件，**不要再作为权威来源**：

| 文件 | 说明 |
|---|---|
| `C:\Users\16622.DESKTOP-5S661OC\.claude\tmp\chiplab\tmp\HANDOFF_VGA_DOOM.md` | 较新的详细 handoff，但缺少 Blitter 新布局/README；已合并 |
| `C:\Users\16622.DESKTOP-5S661OC\AppData\Local\Temp\HANDOFF_VGA_DOOM.md` | 过时：称“Phase 3 未开始”；已合并 |
| `C:\Users\16622.DESKTOP-5S661OC\AppData\Local\Temp\HANDOFF_VGA_DOOM_2026-08-19.md` | 与 chiplab/tmp 版重复；已合并 |
| `C:\Users\16622.DESKTOP-5S661OC\AppData\Local\Temp\HANDOFF_VGA_DOOM_Phase4.md` | Blitter 集成构建中状态；已合并并更新为最新状态 |

> 清理建议：确认本文件无误后，可删除或归档上述 4 份临时 handoff，避免后续 agent 读到矛盾版本。

---

## 9. 建议 skills

- `executing-plans` — 按 `VGA_DOOM_PLAN.md` 继续实施
- `systematic-debugging` / `diagnose` — 驱动/硬件问题先复现再修
- `verification-before-completion` — 上板/仿真通过后再声称完成
- `writing-plans` / `to-issues` — 拆分 Phase 4B/6/7 任务
- `using-git-worktrees` — 内核侧新阶段前隔离工作区
- `j-space` — 长周期多阶段任务保持状态与一致性
