# 调试报告：UART 输入异常与 bootelf 无输出问题

> 日期：2026-08-13
> 状态：UART 输入问题**已解决**；bootelf 问题**已定位到关键机制，根因待最终确认**
> 环境：LoongArch 6 级流水线 CPU（myCPU），Verilator 仿真 + FPGA 上板（chiplab）

---

## 1. 问题总览

| # | 问题 | 状态 |
|---|------|------|
| 1 | uboot 串口输入丢字符（1234567890 → 只生效 24680）、缓存堆积、偶发丢/多字符 | ✅ 已修复（AXI 桥地址对齐） |
| 2 | uboot 空行回车重复执行上一条命令 | ℹ️ 非 bug（U-Boot 标准行为） |
| 3 | bootelf 0xa3000000 无输出立即返回命令行 | 🔍 机制已确认，根因待最终定位 |
| 4 | go 0xa08dd000 能启动内核但 initramfs 解压失败（panic） | 🔍 定位为 memcpy 写丢失导致数据损坏 |

---

## 2. 问题 1：UART 输入丢字符（已解决）

### 2.1 现象

uboot 命令行输入异常：
- 按一个键小概率无效果
- 连按只生效偶数位（1234567890 → 24680）
- 输入像"缓存堆积"，前面的不吐出后面的不生效
- 偶发误判长按、丢/多字符

### 2.2 根因（完整链路）

uboot 的 ns16550 驱动是**轮询**接收（读 LSR 检查 DR 位），未开中断。问题在 CPU 的 AXI 桥与 SoC 层 APB 桥的接口不兼容：

```
CPU 读 LSR（ld.bu 0x9fe00005）
  → cache_axi_bridge.v：所有读固定 arsize=010（32 位）+ 地址非对齐（0x9fe00005）
  → axi2apb.v（官方）：32 位读拆成 4 次 APB 读（地址 05、06、07、08 递增）
  → 第 4 次读地址 0x9fe00008 的低 3 位 = 0 → 回绕到 RB（接收 FIFO）→ 弹走字符！
```

**致命点**：读 LSR 的"多余 APB 读"（地址 08 回绕到 RB）把刚收到的字符弹出了 FIFO。于是：
- tstc 读到 DR=1（0x61）→ getc 再读 LSR 确认时 DR 已是 0（FIFO 被弹空）→ 返回 -EAGAIN → 字符无声丢失
- 连续输入 → 间隔丢失（24680 模式）

### 2.3 修复（cache_axi_bridge.v）

非 burst 读地址对齐到 4 字节（AXI 字读规范）：

```verilog
wire [31:0] dc_axi_rd_addr = is_dc_rd_burst_buf ? dc_rd_buf_addr
                                                 : {dc_rd_buf_addr[31:2], 2'b00};
wire [31:0] ic_axi_rd_addr = is_ic_rd_burst_buf ? ic_rd_buf_addr
                                                 : {ic_rd_buf_addr[31:2], 2'b00};
assign araddr  = dc_rd_buf_win ? dc_axi_rd_addr : ic_axi_rd_addr;
```

修复后：LSR 读（0x9fe00005）→ AXI 读 0x9fe00004 → APB 读 MCR/LSR/MSR/SCR（无副作用）→ 不再碰 RB。

### 2.4 验证

- 仿真：注入 `1234567890\r` → **10/10 完整回显**，识别为命令；help/version 正常
- trace：字符读取 0x30-0x39 各 1 次全部正确；load 返回 PC 异常从 6 次降为 0
- 注意事项：官方 axi2apb.v 不应修改（其 rdata 组装是按"32 位读 + 对齐地址"设计的），正确做法是适配自己的桥

---

## 3. 问题 2：空行回车重复执行上条命令

**非 bug**。U-Boot `cli_simple_loop` 的标准行为：

```c
if (len > 0)
    strlcpy(lastcommand, console_buffer, ...);
else if (len == 0)
    flag |= CMD_FLAG_REPEAT;      // 空行回车 → 重复上条命令
rc = run_command_repeatable(lastcommand, flag);
```

修复 UART 问题前 getc 全失败掩盖了该行为。如不需要可改 cli_simple_loop（空行跳过执行）。

---

## 4. 问题 3+4：bootelf 无输出 + initramfs 解压失败

### 4.1 现象

```
=> tftpboot 0xa3000000 vmlinux     # 下载 vmlinux（ELF，14MB）
=> bootelf 0xa3000000              # 无任何输出，立即返回命令行
=> go 0xa08dd000                   # 能启动内核（18 秒输出），但最后：
[ 18.66] Kernel panic - not syncing: uncompression error   # initramfs 解压失败
```

### 4.2 vmlinux 关键信息（readelf）

| 项 | 值 |
|----|-----|
| 入口（e_entry） | 0xa08dd000 |
| LOAD 段 | Vaddr=PhysAddr=0xa0200000，FileSiz=0xc7ec00（13MB） |
| 内置 initramfs | gzip 压缩的 rootfs.cpio（9.2MB），CONFIG_INITRAMFS_SOURCE |
| 配置 | CONFIG_32BIT_REDUCED=y，CONFIG_CMDLINE_FORCE=y |

### 4.3 上板调查（bootelf 无输出）

| 实验 | 结果 | 结论 |
|------|------|------|
| md 0xa3000000（ELF 头） | magic 正确、e_entry=0xa08dd000 | 下载完好 |
| bootelf 0xa3000000 | 无输出立即返回 | 复现 |
| 仿真 bootelf | **同样无输出返回** | 仿真复现（与上板一致） |
| trace 里内核入口 0xa08dd000 | **0 次** | 内核从未执行 |
| 异常向量 0xbc001000 | **0 次** | 不是标准异常路径 |
| bootelf_exec 反汇编（0xa0201524） | a0=0/a1=物理cmdline/a2=0, jirl entry | 传参代码正确 |
| 3.4ms 执行流 | 执行 uboot 启动序列（cache_init + 复制循环 + 跳 c_main 0xa02012d0） | 执行流被带进启动代码 |

**仿真 trace 还原的 bootelf 行为**：

```
0-1.5ms     uboot 引导（提示符，tstc 轮询 0xa7fcdef0）
1.5-12.5ms  bootelf 执行（memcpy 13MB + flush_cache 169 万 CACOP）
3.4ms       （CACOP 中途）执行流进入 uboot 启动序列
            0x1c0023bc cache 操作循环 → 0x1c0022a4 复制循环
            → 0x1c0022cc 跳转 c_main（0xa02012d0）
跳转后      设 DMW1/设栈/清内存 → 0xa02209xx（u-boot lmb 区域）死循环 142 万次
12.7ms      返回命令行
```

**关键疑点**：跳转目标 0xa02012d0（c_main）处的内容是 **u-boot 代码**（0x1500000d），而 vmlinux 该处应为 0x03400000（NOP）—— 即 bootelf 的 memcpy 可能**没有正确覆盖 0xa0200000 区域**（或执行流跳转被破坏）。

### 4.4 上板调查（initramfs 解压失败 = memcpy 写丢失）

| 实验 | 结果 | 结论 |
|------|------|------|
| crc32 0xa0944d78 0x3a8124（initramfs） | 0x1ffdb4a1 ≠ 基准 0x43d3a38f | **内存数据损坏** |
| 下载源多处 md | = vmlinux 文件 | tftp 传输完好 |
| 加载目标 md（62.5%/68.75%/71.9%） | = vmlinux 文件 | memcpy 前段正确 |
| 加载目标 md（75%） | ≠ 文件 | **损坏窗口：约 71.9%-75%（~107KB）** |
| gzip 流尾 md | = 文件 | 损坏是**局部**的（之后恢复） |
| 损坏内容 8/12/16 字节片段 | 不在 vmlinux 任何位置 | 排除错位拷贝 → **写丢失**（目标保留旧内容） |

**结论**：bootelf 的 memcpy（13MB）在写 ~10MB 处时有一段窗口写丢失（局部损坏），导致：
- initramfs 数据损坏 → go 后内核解压失败（uncompression error）
- 入口区域/数据被写坏 → bootelf 跳转异常（执行流进入 uboot 启动序列）

### 4.5 当前假设与待确认

1. **CPU 写路径（DCache 写直通 → bridge dc_wr_buf → wr_pend → AXI）在 13MB 大拷贝时局部丢写** —— 代码审查未发现明显 bug（握手/stall 自洽），需仿真/波形复现
2. **bootelf 跳转目标被写坏**（0xa02012d0 处是 uboot 代码而非 vmlinux）→ 执行流跳进启动序列
3. 仿真复现的"写丢失"未完全验证（cp.b 13MB 拷贝仿真太慢，未跑完）

### 4.6 下一步建议

| 优先级 | 实验 | 目的 |
|--------|------|------|
| A | 上板 `crc32 0xa0200000 0xc7ec00`（LOAD 段全量，期望 0x0b73c2a9） | 确认 memcpy 是否写全（含入口） |
| B | 仿真 stub 直跳内核（带参数跳 0xa08dd000） | 确认"内核+参数"本身能否启动（排除内核侧） |
| C | 追 trace 里 3.4ms 执行流进入启动序列的精确跳转指令 | 定位跳转目标破坏点 |
| D | 写路径代码深挖（wr_pend/wr_rdy stall 的边界情况） | 找写丢失的 RTL bug |

---

## 5. 仿真基础设施注意事项（踩坑记录）

| 坑 | 说明 |
|----|------|
| ram.dat 16 字节行 | 官方 ram.cpp/emu.cpp 只支持单字节行（每行 2 hex）；16 字节行会按 8 字节反转字节序（conv_hex2int64 大端解析 + 小端写入）→ 数据全错 |
| ram.dat 加载慢 | 单字节行 44MB 文本 fscanf 逐字节解析 → 约 15 分钟；vmlinux 14MB → 43MB 文本 |
| simu_trace 拖慢 | 每指令写一行，bootelf 加载（memcpy+169 万 CACOP）→ 数 GB trace；SIMU_TRACE=n 可关 |
| difftest 拖慢 | TRACE_COMP=y 时 NEMU 逐指令同步 + CACOP 打印（169 万行）→ 极慢；--disable-trace-comp 是运行时参数但 TRACE_COMP 是编译宏 |
| FIFO 注入 | Windows 侧 mkfifo 在 SMB（\\wsl.localhost）上是普通文件；须在 WSL 内 mkfifo + `exec 3<>fifo_in` 保持写端 |

---

## 6. git 仓库问题（顺带修复记录）

- VSCode git 树刷新报错：packed-refs 有 3 个指向不存在对象的 refs（worktree-pre_mem_stage / loongson_team/axi / loongson_team/tlb）+ 坏 worktree + 无效 reflog
- 修复：移除坏 refs/worktree、清理 reflog
- `git fetch --all` 报 "object a753ccad not found"：**与本地无关**，是远程 loongson_team 仓库 axi 分支指向的对象缺失（本地已删引用仍报错）
- 注：本仓库在 \\wsl.localhost（Z: 盘 = WSL 文件系统），Windows/WSL 双端 git 操作易产生引用损坏，建议固定一端

---

## 7. 关键符号/地址速查

| 符号 | 地址 | 说明 |
|------|------|------|
| vmlinux 入口（kernel_entry） | 0xa08dd000 | 内核入口（从未被执行） |
| vmlinux LOAD 段 | 0xa0200000（13MB） | bootelf memcpy 目标 |
| vmlinux 内置 DTB | 0xa0943120 | 完好（损坏窗口之前） |
| __initramfs_start | 0xa0944d78 | gzip 数据起始（CRC 基准 0x43d3a38f） |
| fw_arg0/1/2 | 0xa0e840bc/b8/b4 | 内核 head.S 保存 a0/a1/a2（探针） |
| u-boot c_main | 0xa02012d0（ELF）/ bin 0x1c0022d0 | bootelf 跳转实际目标 |
| u-boot bootelf_exec | 0xa0201524（ELF） | 传参正确 |
| u-boot 复制循环 | 0x1c0022a4 | 启动序列（cache_init + 复制 + 跳 c_main） |
| u-boot cache_init | 0x1c0023bc | 启动序列的 cache 操作 |
