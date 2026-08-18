# DCache 设计文档

## 1. 架构概览

| 参数 | 值 | 说明 |
|------|-----|------|
| 组相联 | 2-way | `D_WAY_NUM = 2` |
| 索引位宽 | 10 bit | `D_INDEX_WIDTH = 10`，共 1024 组 |
| Tag 位宽 | 17 bit | `D_TAG_WIDTH = 17` |
| 偏移位宽 | 5 bit | `D_OFFSET_WIDTH = 5`，32 字节 cache line |
| 每行 Bank 数 | 8 | 每 Bank 32-bit，8 Bank = 256-bit |
| 替换策略 | 树状 PLRU | `D_WAY_NUM-1 = 1` bit/组 |
| RAM 类型 | 单端口同步 | `tagv_ram`（按位写使能）、`data_bank_ram`（bank）、寄存器阵列（d_ram） |
| 读写 | 读分配 + 写回 + 写分配 | load miss 填 cache；store miss 先填再写；命中 store 经 WB 延迟写 |

**地址划分（32-bit 物理/虚地址）：**

```
|  TAG [31:15]  |  INDEX [14:5]  |  OFFSET [4:0]  |
|    17 bit      |    10 bit      |     5 bit       |
```

**Cache 行结构（每 way × 每 index）：**

```
|  V (1b)  |  TAG (17b)  |  D (1b)  |  Data Bank0..7 (8×32b)  |
```

tagv 条目 = `{TAG[17:1], V[0]}`，单独存储于 `tagv_ram`；D 位存于 `d_ram`（寄存器阵列）。

---

## 2. Buffer 设计

### 2.1 Request Buffer

`accept_new_req` 时更新，miss 处理期间保持稳定。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `req_op` | 1 | 0=load, 1=store |
| `req_index` | 10 | 请求 index（别名时当拍修正，见 §5） |
| `req_offset` | 5 | 请求 offset |
| `req_byte_enable` | 4 | CPU 原始字节使能（每字节 1 bit） |
| `req_wdata` | 32 | 请求写数据 |
| `req_preld` | 1 | 预取请求 |

### 2.2 CACOP Buffer

CACOP 上下文独立缓冲，`accept_new_req` 时与 Request Buffer 同拍锁存，miss 处理期间稳定。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `cacop_en_r` | 1 | CACOP 使能（REFILL 结束清零） |
| `cacop_code_r` | 5 | CACOP 操作码（组合译码用 `[4:3]`） |
| `cacop_way_r` | 1 | CACOP 目标路号（index 类操作） |
| `cacop_index_r` | 10 | CACOP 目标 index（别名时当拍修正） |

### 2.3 Refill Buffer

LOOKUP miss 拍锁存总线读上下文，REFILL 期间不变。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_tag` | 17 | 新行 tag（miss 拍 `lookup_tag` 快照） |
| `refill_cached` | 1 | 是否 cached 访问 |
| `refill_replace_way` | 1 | 替换路号（`replace_way` 快照） |
| `refill_cnt` | 3 | 已接收数据拍数（0..7） |
| `refill_line[0:7]` | 8×32 | 新行拼装缓冲区 |
| `refill_way_hit_r` | 2 | miss 拍 `way_hit` 快照（hit 型 cacop 判定用） |

> **注**：原设计中 Refill Buffer 内的 `refill_index`/`refill_offset`/`refill_mmu_tag` 已删除——miss 处理期间 `req_index`/`req_offset` 稳定（`accept_new_req` 不可能在 miss 状态发生），消费点直接使用 request buffer 值。

### 2.4 命名问题（VIPT 别名）Buffer

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `mmu_index_cancel_r` | 1 | 普通请求别名标志（LOOKUP miss 拍锁存，RELOOKUP 拍清零） |
| `mmu_index_cancel_cacop_r` | 1 | CACOP 别名标志（同上） |

### 2.5 Write Buffer（WB）

独立两状态 FSM（`WB_IDLE` / `WB_WRITE`），处理命中 store 的延迟写。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `wb_way_hit` | 2 | store 命中的路位图 |
| `wb_index` | 10 | store 目标 index |
| `wb_bank` | 3 | store 目标 bank |
| `wb_byte_enable` | 4 | 原始字节使能（bank RAM 写使能直接用） |
| `wb_wdata` | 32 | 写数据 |

store 只写一个 bank（`wb_bank`），但命中多路时所有命中路的同 bank 都更新。

---

## 3. RAM 设计

### 3.1 tagv_ram（按位写使能）

单端口同步 RAM，条目 = `{tag[TAG_WIDTH:1], V[0]}`，写使能**按位**独立：

| 操作 | wen 编码 | 效果 |
|------|----------|------|
| refill 填行 | `{tag 全 1, V=1}` | 写 `{refill_tag, 1'b1}` |
| cacop 01/10（invalidate） | `{tag 全 0, V=1}` | 只清 V |
| cacop 00（store-tag） | `{tag 全 1, V=0}` | 只写 tag，V 保留 |

> 位级使能解决了字节使能下「V 与 tag 低 7 位共用字节 0」无法独立写的问题；代价是无法推断进 BRAM（BRAM 仅字节级 WE），实现为 LUTRAM——tag 阵列容量小，可接受。

### 3.2 data_bank_ram（字节写使能）

通用 32-bit 单端口 RAM（4-bit 字节写使能，BRAM 推断优化），数据 bank 使用。

### 3.3 d_ram（D 位寄存器阵列）

`reg [WAY-1:0][INDEX-1:0]` 寄存器阵列，与 tagv 同写使能（refill 填行时写 `req_op`，WB 命中写回时置 1）。

---

## 4. 状态机

### 4.1 双状态机

| 状态机 | 状态数 | 说明 |
|--------|--------|------|
| Main FSM | 8 | IDLE / LOOKUP / REREAD / WAITWR / WAIT_WR_DONE / WAITRD / REFILL / RELOOKUP |
| WB FSM | 2 | WB_IDLE / WB_WRITE |

### 4.2 状态编码

```
IDLE(00000001) LOOKUP(00000010) REREAD(00000100) WAITWR(00001000)
WAIT_WR_DONE(00010000) WAITRD(00100000) REFILL(01000000) RELOOKUP(10000000)
```

### 4.3 状态跳转

```
IDLE ──accept_new_req──▶ LOOKUP
LOOKUP ──hit + accept──▶ LOOKUP（连续处理）
LOOKUP ──别名 + wb_idle──▶ RELOOKUP（当拍重读，见 §5）
LOOKUP ──别名 + wb_write──▶ REREAD（等 WB 空出 RAM 端口再读）
LOOKUP ──cached miss / cacop──▶ REREAD
LOOKUP ──uncached store──▶ WAITWR
LOOKUP ──uncached load──▶ WAITRD（跳过 WAITWR，省 1 拍）
RELOOKUP ──hit + accept──▶ LOOKUP（别名标志本拍清零）
RELOOKUP ──miss──▶ REREAD / WAITWR / WAITRD
REREAD ──别名标志──▶ RELOOKUP / 否则 WAITWR
WAITWR ──uncached store + wr_rdy──▶ WAIT_WR_DONE
WAITWR ──写回握手完成 + cacop──▶ REFILL
WAITWR ──写回握手完成 + cached──▶ WAITRD
WAIT_WR_DONE ──wr_done──▶ IDLE
WAITRD ──rd_rdy──▶ REFILL
REFILL ──refill_last / cacop_en_r──▶ IDLE
```

### 4.4 各状态详述

#### IDLE
- 进入：复位 / 各状态无后续请求
- 退出：`accept_new_req` → LOOKUP
- RAM 动作：`ram_read_en`，读 tagv + bank + d_ram
- PLRU：accept 时锁存 `plru_victim_r`

#### LOOKUP
- tagv_rdata 有效：上一拍 `ram_read_en` 产生
- 分支（优先级）：
  1. 别名（`mmu_index_cancel[_cacop]`）+ `wb_idle` → RELOOKUP（当拍 `ram_raddr` 已用修正地址重读）
  2. 别名 + `wb_write` → REREAD（WB 占用 RAM 写口，下拍再读）
  3. `lookup_cancel`（`mmu_cancel && main_lookup`）→ IDLE（请求丢弃，CPU 重发）
  4. cached miss / cacop → REREAD
  5. uncached store miss → WAITWR
  6. uncached load miss → WAITRD
  7. hit + `accept_new_req` → LOOKUP
  8. hit 无新请求 → IDLE

#### REREAD
- 进入：cached miss / cacop miss / 别名 + wb_write
- 用途：以 `req_index`（别名时已修正）重读 victim 数据，保证写回数据不被 WB 写或新请求读污染；别名场景下同时为 RELOOKUP 提供物理索引的数据
- `main_reread_relookup`（别名标志=1）→ RELOOKUP；否则 → WAITWR

#### WAITWR
- 双重用途：
  - cached 写回（脏 victim）：`wr_needs_write = refill_cached && V && D`，发 `wr_req` 等 `wr_rdy` 握手
  - uncached store：发写等 `wr_rdy` 握手后 → WAIT_WR_DONE 等 `wr_done`
- 无写需求（干净 victim / uncached load 已跳过）时 1 拍通过

#### WAIT_WR_DONE
- uncached store 专用，等 `wr_done`（写真正完成）后回 IDLE
- cached 写回只需握手（`wr_rdy`），不等 `wr_done`

#### WAITRD
- 发 `rd_req`（= `main_waitrd`），等 `rd_rdy` → REFILL

#### REFILL
- 逐拍接收 `return_data` 拼装 `refill_line`；`refill_merged_word` 在命中拍与 `req_wdata` 按 `req_byte_enable` 合并（store miss 回填写数据）
- `refill_last` 拍：tagv + bank + d_ram 写回，PLRU 更新
- `refill_read_miss_done`：`return_valid && !req_op && (refill_cnt == req_offset[4:2] || !refill_cached)`
- 退出：`refill_last || cacop_en_r` → IDLE

#### RELOOKUP
- 进入：别名后重查（wb_idle 当拍 / REREAD 之后）
- 用物理索引读出的 tagv/bank 数据重新比对（`lookup_tag = refill_tag`）
- 命中 → 完成；miss → 按 LOOKUP 分支继续（REREAD / WAITWR / WAITRD）

### 4.5 隐式 IDLE（默认转移）

`main_next` 默认 = IDLE。依赖默认的情况均正确：
- LOOKUP/RELOOKUP 遇 `lookup_cancel` → IDLE（请求丢弃）
- LOOKUP/RELOOKUP 命中但无新请求 → IDLE
- IDLE 无请求 → IDLE

> **注意**：`lookup_cancel` 目前只定义在 `main_lookup`（`mmu_cancel && main_lookup`）。RELOOKUP 期间 `mmu_cancel` 不生效（命中会完成数据返回、miss 会继续处理）——行为无害但语义不严格，如要严格丢弃需扩展定义。

---

## 5. VIPT 别名处理（命名问题）

### 5.1 别名检测

index 高位越界进页号（4KB 页，页内 12 bit）时，VA 索引与 PA 索引在高位不同：

```
mmu_index_cancel        = main_lookup && !cacop_en_r && (req_index[9:7] != mmu_tag[2:0])
mmu_index_cancel_cacop  = main_lookup && cacop_en_r && (code[4:3]==2'b10)
                          && (cacop_index_r[9:7] != mmu_cacop_tag[2:0])
```

（`12 - D_OFFSET_WIDTH = 7`，索引越界位为 `[9:7]`；mmu_tag 低 3 位 `[2:0]` 对应。）

### 5.2 修正与重查

- **当拍重读（wb_idle）**：`ram_raddr = index_cancel_addr = {mmu_tag 高位, index 低位}`——组合重建物理索引，当拍用修正地址重读 tagv/bank，下拍 RELOOKUP 比对
- **修正锁存**：同一上升沿 `req_index`（或 `cacop_index_r`）被修正为物理索引（request buffer / cacop buffer 的 `mmu_index_cancel[_cacop]` 分支），后续所有消费点（rd_addr / wr_addr / tagv 写地址）直接用修正后的 `req_index`
- **wb_write 时**：当拍无法重读（RAM 写口被占），进入 REREAD 拍读物理索引数据，再 RELOOKUP
- **标志清除**：RELOOKUP 拍 `mmu_index_cancel_r[_cacop_r]` 清零

---

## 6. 数据通路

### 6.1 数据来源

```
live_rdata =
  1. lookup_read_hit_done  → lookup_rdata    （L1 命中：bank_rdata + WB 前推合并）
  2. refill_read_miss_done → return_data     （miss：AXI 返回数据）
  3. 其他                  → 0
```

`lookup_rdata` 在 WB 有未写入的同 index/way/bank 数据时，用 `wb_wdata & wb_byte_mask` 与 `bank_rdata` 字节合并。

### 6.2 字节使能展开

request buffer 存 CPU 原始 4-bit `req_byte_enable`，消费点按需展开：

```
req_byte_mask = {8{be[3]}, 8{be[2]}, 8{be[1]}, 8{be[0]}}   // 32-bit 掩码（合并用）
rd_size       = 字(1111) ? 10 : 半字(0011/1100) ? 01 : 00   // 读宽度编码
```

`wr_wstrb = req_byte_enable`（uncached store 透传原始使能），burst 写恒 `4'b1111`。

### 6.3 输出 FIFO

- 深度 4，解耦数据生产和 CPU 消费
- `accept_ok = cpu_op || (fifo_cnt < 3) || (fifo_cnt == 3 && req_op)`：store 无条件接受
- FIFO 空且数据就绪时数据直通（bypass）

---

## 7. uncached 访问

| 类型 | 路径 | 说明 |
|------|------|------|
| uncached load | LOOKUP → **WAITRD** → REFILL | 跳过 WAITWR（原为空泡拍）；`rd_addr` 用 `{refill_tag, req_index, req_offset}` 精确地址，`rd_type` 按访存宽度编码（字 010 / 半字 001 / 字节 000） |
| uncached store | LOOKUP → WAITWR → WAIT_WR_DONE → IDLE | 发写等 `wr_rdy` 握手 + `wr_done` 完成 |

- REFILL 中不写 tagv/bank（`refill_cached = 0`）
- `refill_read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）
- 非缓存读宽度必须按真实访存宽度下发：若整字读降为字节读会丢高字节；字节/半字读若按整字下发，读 UART 偏移 1..3 的寄存器会被对齐回 RB 字地址弹走接收 FIFO

---

## 8. CACOP 处理

### 8.1 操作码（`code[4:3]`）

| code[4:3] | 类型 | wen 编码 | 效果 |
|-----------|------|----------|------|
| 00 | store-tag | `{tag 全 1, V=0}` | 只写 tag（清 0），V 保留 |
| 01 | index 类失效 | `{tag 全 0, V=1}` | 只清 V（index 指定路） |
| 10 | hit 失效 | `{tag 全 0, V=1}` | 只清 V（命中路，`refill_tagv_we` 需 `\|refill_way_hit_r`） |
| 11 | — | — | 未处理（无分支） |

> **注意**：00 的语义（只写 tag 保 V）是近期从「tag+V 全清」改过来的，需与软件确认实际用法（若软件用 00 做全 cache 清无效，旧 V 会残留）。`wr_needs_write` 中 00/01 都会触发写回，若 00 确为 store-tag 语义，该分支待确认。

### 8.2 流程

```
accept_new_req (cacop_en=1)
  → CACOP Buffer 锁存上下文
  → LOOKUP（读 tagv，cache_hit 被 !cacop_en_r 屏蔽）
  → 别名 → RELOOKUP / REREAD；否则 REREAD → WAITWR → REFILL（无总线读）
  → REFILL 中 cacop_en_r 触发 tagv 按位写
  → 若有脏行需写回（wr_needs_write）→ WAITWR 发写
  → cacop_en_r ← 0（REFILL 拍），FSM → IDLE
```

- CACOP 不产生 `cpu_data_ok`
- 替换路：code=10 用 `hit_way_idx`，否则用 `cacop_way_r`

---

## 9. 写回机制

```
wr_needs_write = cacop_en_r ? (00 || 01 || (10 && |refill_way_hit_r)) && V && D
                            : (refill_cached && V && D) || is_uncached_store
```

- cached 脏 victim 写回：WAITWR 等 `wr_rdy` 握手（数据 `wr_data_cached` 从 `bank_rdata[refill_replace_way]` 整行拼装）
- uncached store：等 `wr_rdy` + `wr_done`
- `wr_type`/`wr_wstrb`/`wr_addr` 从 refill/request buffer 组合推导

---

## 10. PLRU 替换算法

2-way 时 1 bit/组 × 1024 组。

- **Accept 拍**：组合遍历 → `plru_victim_pre` → `plru_victim_r`（锁存）
- **LOOKUP 拍**：`replace_way = cacop_en_r ? (10 ? hit_way_idx : cacop_way_r) : (has_invalid ? invalid_way : plru_victim_r)`
- **更新**：命中或 `refill_tagv_we` 时标 MRU（`plru_upd_index = cacop_en_r ? cacop_index_r : req_index`）

---

## 11. 性能计数器

| 计数器 | 说明 |
|--------|------|
| `perf_total_req` | 总 accept 次数（不含 cacop） |
| `perf_access_cnt` | cached 访问进入 LOOKUP 的次数（不含 cacop） |
| `perf_miss_cnt` | cached miss 次数 |
| `perf_real_miss_cnt` | 真实 miss |
| `perf_relookup_cnt` | 别名重查次数 |

---

## 12. 信号命名约定

| 前缀 | 含义 |
|------|------|
| `req_*` | Request Buffer |
| `cacop_*` | CACOP 接口/上下文 |
| `refill_*` | Refill Buffer |
| `mmu_index_cancel*` | 别名检测/缓冲 |
| `wb_*` | Write Buffer |
| `wr_*` | AXI 写接口 |
| `cpu_*` | CPU 接口 |
| `plru_*` | PLRU 替换算法 |
| `perf_*` | 性能计数器 |

### 关键组合信号速查

| 信号 | 推导 |
|------|------|
| `accept_new_req` | `accept_ok && (cpu_req \| cacop_en) && (IDLE \| (LOOKUP/RELOOKUP && cache_hit)) && !(wb_write 冲突)` |
| `cache_hit` | `(\|way_hit) && lookup_cache && !cacop_en_r && !lookup_cancel && !别名` |
| `lookup_cancel` | `mmu_cancel && main_lookup` |
| `rd_type` | `refill_cached ? 100 : {0, rd_size}` |
| `rd_addr` | cached:`{refill_tag, req_index, 5'd0}` / unc:`{refill_tag, req_index, req_offset}` |
| `wr_req` | `main_waitwr && wr_needs_write` |
| `wr_addr` | unc:`{refill_tag, req_index, req_offset}` / cacop:`{tagv高位, cacop_index_r, 0}` / burst:`{tagv高位, req_index, 0}` |
| `cpu_addr_ok` | `accept_new_req && !cacop_en` |
| `cpu_data_ok` | `lookup_read_hit_done \| refill_read_miss_done \| !fifo_empty \| lookup_write_done \| lookup_preld_done` |
