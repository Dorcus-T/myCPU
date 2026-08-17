## 项目概览

LoongArch (LA) 6级顺序流水线 CPU，FPGA 原型验证用。

| 属性 | 值 |
|------|-----|
| 流水级 | IF → ID → EX → PRE_MEM → MEM → WB |
| 前推网络 | EX/MEM/WB → ID 全旁路（PRE_MEM 参与 stall 不参与前递） |
| 冒险处理 | Load-use 停顿（EX/PRE_MEM/MEM）、CSR/ERTN 互锁 |
| 总线接口 | AXI3 Master，cache_axi_bridge 桥接 |
| Cache | 2路组相联 ICache 32KB (256组×64B) + DCache 64KB (1024组×32B)；DCache 写直通 AXI（bridge 写缓冲+挂起计数） |
| TLB | 32项全相联 MTLB + STLB，虚拟地址翻译 |
| 乘法器 | 64×64 流水线（3级，mult/unsigned/signed 三结果并行，96位输出） |
| 除法器 | 串行迭代，多拍完成，带握手停顿 |
| 当前 fmax | 待 Vivado 完整工程分析确定 |

## 目录结构（扁平项目）

```
mycpu_top.v          — 顶层 core_top，例化全部子模块
branch_predict.v     — BTB(32项)+BHT(2bit)+RAS(16CAM+8栈) 分支预测器
if_stage.v           — IF: 取指，I-Cache 接口，分支/异常重定向，pre_if 流水级+预测集成
id_stage.v           — ID: 译码（46KB，最大组合逻辑模块），前递选通
ex_stage.v           — EX: 执行，纯 ALU（mul/div 握手），前递结果
pre_mem_stage.v      — PRE_MEM: MMU 虚实翻译 + D-Cache 请求 + CACOP
mem_stage.v          — MEM: 访存，D-Cache 数据读回
wb_stage.v           — WB: 写回寄存器堆 + CSR
alu.v                — 组合逻辑 ALU（19种运算）+ 串行除法器握手
csr.v                — CSR 寄存器文件（30+ reg: CRMD/PRMD/ERA/DMW/TLB 等）
mmu.v                — 虚实地址转换顶层（DMW窗口 + TLB选择）
tlb.v                — 32项全相联 TLB，2搜索端口（MTLB + STLB）
regfile.v            — 32×32 通用寄存器堆，双读端口
icache.v             — 2路组相联 ICache 32KB（256组×64B）
dcache.v             — 2路组相联 DCache 64KB（1024组×32B），写直通 AXI
cache_axi_bridge.v   — Cache SRAM 协议 ↔ AXI3 转换
linectrl.v           — 集中式流水线控制器（7级 empty/valid/ready 集中计算）
sp_ram.v             — 单端口同步 RAM（参数化位宽/深度，字节写使能）
mymul.v              — 流水线乘法器（IDLE→STAGE1→STAGE2，96位输出）
mydiv.v / mydivu.v   — 有符号/无符号串行除法器（多拍握手）
utlb.v               — 4项全相联 μTLB（组合逻辑同拍查找+LRU替换）
timer_64bit.v        — 64位周期计数器
decoder_2_4/4_16/5_32/6_64.v — 译码辅助模块
mycpu.h              — 总线位宽、CSR 地址、异常编码宏定义
tool/                — 时序分析工具链（Yosys + OpenSTA + Vivado）
tmp/                 — 临时文件（仿真测试等）
```

## 仿真

- Verilator 综合
- iverilog lint（`.vscode/settings.json`）
- difftest 对比验证（`DIFFTEST_EN` 宏控制）

### 运行测试（WSL / 双击 bat）

| 脚本 | 用途 |
|------|------|
| `tool/run_mycpu_func.bat` | mycpu 功能测试 |
| `tool/run_nscscc_func.bat` | NSCSCC 功能测试 |
| `tool/run_random.bat` | random 测试（随机访存/TLB，lightsss） |
| `tool/run_cpu_diag.bat` | CPU 诊断测试 |
| `tool/run_perf.bat` | 性能测试（20 benchmark + allbench，`-s hex` 拨码选 bench） |
| `tool/run_linux.bat` | Linux 仿真（5.14 loongarch32 内核，`tmp_linux/run_linux.sh` 直接启动 vmlinux） |
| `tool/run_uboot.bat` | U-Boot 仿真（轮询接收输入） |

- Linux 仿真交互输入走 UARTSIM 的 stdin（testbench port 0）；当前 linux_obj 为 5.14 内核（2022 龙芯 loongarch32），无 initramfs 时启动卡在 init 之前属预期
- **编译（verilator/g++）必须在 WSL 内执行**（Git Bash 无 make），需 `export CHIPLAB_HOME=/home/dorcus_t/chiplab`；Windows 侧经 `\\wsl.localhost` 看 WSL 文件有 SMB 读缓存，实时日志用 `wsl.exe cat/tail` 直读

## 时序分析

### 工具链总览

| 工具 | 用途 | 耗时 | 命令 |
|------|------|------|------|
| Yosys + ABC | 综合 + 面积 + 多频率对比 | ~3-15min | `cd tool && yosys analyze.ys` |
| Yosys + Nangate45 | 标准单元映射 + 真实面积 | ~15min | `cd tool && yosys nangate_flat.ys` |
| OpenSTA | 静态时序分析 + 精确延迟 | ~3min | `cd tool && sta -no_splash -exit sta_real.tcl` |
| Yosys+STA 一键 | 综合 + 时序全流程 | 双击运行 | `tool/run_timing.sh` |
| Vivado | FPGA 综合 + 布线延迟 + 彩色报告 | 双击运行 | `tool/run_vivado.bat` / `tool/run_vivado_full.bat` |

详见 `tool/README.md`。

> 精确 fmax 数字以 Vivado 完整工程分析为准，Yosys/OpenSTA 的结果仅用于横比。

## 坑点

- **复位极性**：外部 `aresetn` 低有效，内部 `reset` 高有效
- **TLB 可配置**：条目数由 parameter 控制，当前 32 项
- **SRAM 协议两通道独立**：inst_sram（取指）和 data_sram（访存）各自握手
- **CSR 写后读冒险**：跟踪 CSR 写所在的流水级（EX→PRE_MEM→MEM→WB）来解决 RAW
- **STA 假路径**：除法器多拍迭代路径在 STA 中需设 false_path/multicycle，否则 WNS 虚高
- **乘法器前递**：乘结果为 3 级流水线多拍输出（mymul.v），前递时需注意流水状态。当前若前递给下条指令需检查时序
- **dcache miss 停顿**：dcache miss 时 mem_stage 一直等 data_ok，期间不能流水前进
- **CACOP way hit 需寄存**：CACOP 命中 way 存 `refill_way_hit_r` 供后续状态使用，
  `way_hit` 是 lookup 拍组合输出，之后的状态直接用会错
- **DCache 写通路**：写请求经 cache_axi_bridge 的 `dc_wr_buf` 写缓冲发 AXI（支持 burst），
  `wr_rdy = !dc_wr_buf_valid && !wr_pend_full`，缓冲满时 dcache 需等
- **debug 端口约定**：dcache/pre_mem/bridge 调试信号统一命名 `debug_*`，
  逐级引出到 mycpu_top 顶层端口供仿真观测
- **PRE_MEM 级**：MMU 翻译（va→pa）延迟在此级隐藏；若时序仍有问题可加寄存器切分 MMU→cache tag 路径
- **分支预测 0 气泡路径**：BTB/RAS 组合输出不经寄存器直连 pre_if_pc_r 的 D 端 MUX。
  若 STA 显示此路径不收敛，在 BTB target 输出后加寄存改 1 气泡方案。
- **分支预测器冷启动**：复位后 BTB/RAS CAM 全无效，首次遇到分支走原有 br_bus 路径，
  ID 级触发建项，第二次才预测。
- **RAS 栈溢出**：8 项栈，push 超过深度时静默丢弃最早项（不报错），
  pop 时栈空则忽略（不报错）。
- **mispred_bus 优先级**：ex_mispredict > id_mispredict。
  同一周期 ID 和 EX 同时发 mispredict 时（几乎不会发生），取 EX 的纠正地址。
- **ID→EX 总线扩展**：预测透传字段（pred_* + br_type + br_taken + br_target）放在总线尾部，
  保持 difftest 字段 bit 位置不变。
- **UART 读副作用（已修复，c9e9a18）**：axi2apb 对 32 位读拆 4 次 APB 读（地址递增）。
  非 burst 读若被桥强制字对齐，读 UART 偏移 1..3（IE/IIR/LC）会先命中 RB 字地址，
  第 1 次读弹走接收 FIFO 字符 → Linux 中断驱动输入几乎全丢（U-Boot 轮询只读
  LSR/RBR 不受影响）。修复：非 burst 读保留字节地址 + arsize 跟随访存宽度
  （dcache `rd_type` 按 wstrb 编码 000/001/010）。依赖从端按字对齐返回
  （ram.cpp `read32` 丢低 2 位），上板 SRAM 需确认同样行为
- **中断映射**：8 线外部中断 `intrpt[7:0]` → ESTAT[9:2]（IS92）；`has_int =
  (ESTAT[12:0] & ECFG[12:0])`；内核 `handle_cpu_irq` 读 ESTAT 低 15 位取最低置位位
  分发（irq = 位索引：DT `interrupts=<3>` ↔ 硬件 ESTAT[3] ↔ 全局 irq 18）。
  CSR 0xa4（MSGIR/AVEC）未实现，内核 avecintc 未注册不影响
- **git detached HEAD 提交丢失**：在 detached HEAD 上提交后切走，提交成孤儿
  （git log 看不到），用 `git reflog` 找回 + `git branch <名> <hash>` 挂回
  （实例：c9e9a18/d518672 → linux-success 分支）
- **定时器中断**：CSR.TVAL 递减到 0 → ESTAT[11]（TI），与外部中断位不冲突；
  CPU 空闲停在 `idle` 指令（`__arch_cpu_idle`），时钟中断唤醒后回 do_idle 循环

# Verilog 代码格式规范

## 1. 模块声明

```verilog
module module_name (
    // 分组注释（无=====）
    input  wire [ 3:0] port_name,   // 行内注释（对齐）
    output wire [31:0] port_name2,  // 行内注释（对齐）
    input  wire        port_name3   // 最后一个端口无逗号
);
```

- `module module_name (` 小括号前有空格
- 端口必须显式声明 `wire` 或 `reg`
- 端口列表用 `// 注释` 分组（不带 `==========`）
- 位宽格式：`[ 3:0]`（MSB左补到2字符位置）
- 无位宽端口：类型关键字后用空格补位，使端口名对齐
- 行内 `//` 注释对齐到一致列
- 最后一个端口不加逗号

## 2. 缩进

- 模块内容用 4 空格缩进
- `always` 块内用 4 空格再缩进

## 3. 区块分隔

- 模块内大区块：`// ============================================================`（60个=）
- 子区块：`// ========== 标题 ==========`

## 4. Always 块

```verilog
always @(posedge clk) begin
    if (reset) begin
        ...
    end
    else if (...) begin
        ...
    end
end
```

- `always @(posedge clk)` 不额外加空格
- `if (` 有空格
- `begin` 与条件同行
- `else` 与 `end` 同行，`else if` 另起

## 5. Assign 语句

```verilog
assign signal = (condition)
              | (condition2);
```

- 多行按逻辑断行，`|`/`||`/`&&` 放在行首对齐
- 操作符两侧留空格：`a & b`，`a == b`
- `~a` 取反不加空格

## 6. 模块实例化

```verilog
    module_name u_inst_name (
        .port_name_long  (signal),
        .port_name_short (signal2),
        .port            (signal3)
    );
```

## 7. 注释

- 端口注释：信息量越少越好，没必要每行都写
- 不改动原有注释文字，只修间距
- `//` 后有空格：`// 注释`（不是 `//注释`）

## 8. Generate

```verilog
generate
    for (i = 0; i < N; i = i + 1) begin : label
        assign out[i] = (in == i);
    end
endgenerate
```

- `for` 内 `=`、`<`、`+` 两侧留空格
- `begin : label` 另起一行
- `end` 和 `endgenerate` 分两行

## 9. 内部信号声明对齐

```verilog
    wire [31:0] signal_a;   // wire = 4字符 + 1空格 = 5字符占位
    reg  [31:0] signal_b;   // reg  = 3字符 + 2空格 = 5字符占位（与wire对齐）
    wire        signal_c;   // 无位宽时同理，信号名对齐到一致列
```

- `wire` 和 `reg` 关键字不等长，通过补空格使**信号名**起始列对齐
- 有/无位宽的信号之间，通过类型关键字后的空格补位，使信号名起始列一致
- **同一组内**上下行的右侧 `//` 注释必须对齐到相同列