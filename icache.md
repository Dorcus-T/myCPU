# ICache 设计文档

## 1. 架构概览

| 参数 | 值 | 说明 |
|------|-----|------|
| 组相联 | 2-way | `I_WAY_NUM = 2` |
| 索引位宽 | 8 bit | `I_INDEX_WIDTH = 8`，共 256 组 |
| Tag 位宽 | 18 bit | `I_TAG_WIDTH = 18` |
| 偏移位宽 | 6 bit | `I_OFFSET_WIDTH = 6`，64 字节 cache line |
| 每行 Bank 数 | 16 | 每 Bank 32-bit，16 Bank = 512-bit |
| 替换策略 | 树状 PLRU | `I_WAY_NUM-1 = 1` bit/组 |
| RAM 类型 | 单端口同步 | `tagv_ram`（按位写使能）、`data_bank_ram`（bank），读延迟 1 拍 |
| 读写 | 只读分配 | fetch miss 填 cache，无写回、无脏位 |

**地址划分（32-bit 物理/虚地址）：**

```
|  TAG [31:14]  |  INDEX [13:6]  |  OFFSET [5:0]  |
|    18 bit      |     8 bit      |     6 bit       |
```

**Cache 行结构（每 way × 每 index）：**

```
|  V (1b)  |  TAG (18b)  |  Data Bank0..15 (16×32b)  |
```

tagv 条目 = `{TAG[18:1], V[0]}`，单独存储于 `tagv_ram`；数据存于 `data_bank_ram`。

---

## 2. Buffer 设计

### 2.1 Request Buffer

`accept_new_req` 时更新，miss 处理期间保持稳定。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `req_index` | 8 | 请求 index（别名时当拍修正，见 §5） |
| `req_offset` | 6 | 请求 offset |

### 2.2 CACOP Buffer

CACOP 上下文独立缓冲，`accept_new_req` 时与 Request Buffer 同拍锁存。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `cacop_en_r` | 1 | CACOP 使能（REFILL 结束清零） |
| `cacop_code_r` | 5 | CACOP 操作码（组合译码用 `[4:3]`） |
| `cacop_way_r` | 1 | CACOP 目标路号（index 类操作） |
| `cacop_index_r` | 8 | CACOP 目标 index（别名时当拍修正） |

### 2.3 Refill Buffer

LOOKUP miss 拍锁存总线读上下文，REFILL 期间不变。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_tag` | 18 | 新行 tag（miss 拍 `lookup_tag` 快照，RELOOKUP 比对也用此值） |
| `refill_cached` | 1 | 是否 cached 访问 |
| `refill_replace_way` | 1 | 替换路号（`replace_way` 快照） |
| `refill_cnt` | 4 | 已接收数据拍数（0..15） |
| `refill_line[0:15]` | 16×32 | cache line 拼装缓冲区 |
| `refill_way_hit_r` | 2 | miss 拍 `way_hit` 快照（hit 型 cacop 判定用） |

> **注**：原 Refill Buffer 的 `refill_index`/`refill_offset` 已删除——miss 处理期间 `req_index`/`req_offset` 稳定，消费点直接使用 request buffer 值。

---

## 3. RAM 设计

### 3.1 tagv_ram（按位写使能）

单端口同步 RAM，条目 = `{tag[TAG_WIDTH:1], V[0]}`，写使能**按位**独立：

| 操作 | wen 编码 | 效果 |
|------|----------|------|
| refill 填行 | `{tag 全 1, V=1}` | 写 `{refill_tag, 1'b1}` |
| cacop 01/10（invalidate） | `{tag 全 0, V=1}` | 只清 V |
| cacop 00（store-tag） | `{tag 全 1, V=0}` | 只写 tag，V 保留 |

> 位级使能解决「V 与 tag 低 7 位共用字节 0」无法独立写的问题；代价是无法推断进 BRAM，实现为 LUTRAM——tag 阵列容量小，可接受。

### 3.2 data_bank_ram（字节写使能）

通用 32-bit 单端口 RAM（4-bit 字节写使能，BRAM 推断优化），数据 bank 使用。

---

## 4. 状态机

### 4.1 状态编码

```
IDLE(00001) LOOKUP(00010) WAITRD(00100) REFILL(01000) RELOOKUP(10000)
```

### 4.2 状态跳转

```
IDLE ──accept_new_req──▶ LOOKUP
LOOKUP ──hit + accept──▶ LOOKUP（连续处理）
LOOKUP ──别名──▶ RELOOKUP（当拍重读，见 §5）
LOOKUP ──cacop_en_r──▶ REFILL（无总线读，直接写 tagv）
LOOKUP ──miss + rd_rdy──▶ REFILL
LOOKUP ──miss + !rd_rdy──▶ WAITRD
RELOOKUP ──hit + accept──▶ LOOKUP / miss──▶ WAITRD / cacop──▶ REFILL
WAITRD ──rd_rdy──▶ REFILL
REFILL ──refill_last / cacop_en_r──▶ IDLE
```

### 4.3 各状态详述

#### IDLE
- 退出：`accept_new_req` → LOOKUP
- RAM 动作：`ram_read_en`，读 tagv + bank
- PLRU：accept 时锁存 `plru_victim_r`

#### LOOKUP
- 分支（优先级）：
  1. 别名（`mmu_index_cancel[_cacop]`）→ RELOOKUP（当拍 `ram_raddr` 已用修正地址重读）
  2. `lookup_cancel`（`mmu_cancel && main_lookup`）→ IDLE（请求丢弃）
  3. `cacop_en_r` → REFILL
  4. miss + `rd_rdy` → REFILL；miss + `!rd_rdy` → WAITRD
  5. hit + `accept_new_req` → LOOKUP；hit 无新请求 → IDLE

#### WAITRD
- 发 `rd_req`（= `main_waitrd`），等 `rd_rdy` → REFILL

#### REFILL
- 逐拍接收 `return_data` 拼装 `refill_line`，`refill_cnt++`
- `refill_read_miss_done`：`return_valid && (refill_cnt == req_offset[5:2] || !refill_cached)`
- `refill_last` 拍：tagv + bank 写回，PLRU 更新
- 退出：`refill_last || cacop_en_r` → IDLE

#### RELOOKUP
- 进入：别名后重查
- 用物理索引读出的 tagv/bank 数据重新比对（`lookup_tag = refill_tag`、`lookup_cache = refill_cached`——miss 拍快照，不依赖当时 `mmu_tag` 输入）
- 命中 → 完成；miss → WAITRD / REFILL（cacop）

### 4.4 隐式 IDLE（默认转移）

`main_next` 默认 = IDLE。依赖默认的情况均正确：
- LOOKUP/RELOOKUP 遇 `lookup_cancel` → IDLE（请求丢弃）
- LOOKUP/RELOOKUP 命中但无新请求 → IDLE
- IDLE 无请求 → IDLE（显式声明 `main_idle_idle`，仅可读性用）
- REFILL 结束 → IDLE（显式声明 `main_refill_idle`，仅可读性用）

> **注意**：`lookup_cancel` 目前只定义在 `main_lookup`。RELOOKUP 期间 `mmu_cancel` 不生效——行为无害但语义不严格，如要严格丢弃需扩展定义。

---

## 5. VIPT 别名处理（命名问题）

### 5.1 别名检测

index 高位越界进页号（4KB 页，页内 12 bit）时，VA 索引与 PA 索引在高位不同：

```
mmu_index_cancel        = main_lookup && !cacop_en_r && (req_index[7:6] != mmu_tag[1:0])
mmu_index_cancel_cacop  = main_lookup && cacop_en_r && (code[4:3]==2'b10)
                          && (cacop_index_r[7:6] != mmu_cacop_tag[1:0])
```

（`12 - I_OFFSET_WIDTH = 6`，索引越界位为 `[7:6]`；mmu_tag 低 2 位 `[1:0]` 对应。）

### 5.2 修正与重查

icache 无 REREAD 状态（纯读、无写回数据依赖），别名处理全部走**当拍重读**：

```
ram_raddr = mmu_index_cancel      ? {mmu_tag[19:2], req_index[1:0]}
          : mmu_index_cancel_cacop? {mmu_cacop_tag[19:2], cacop_index_r[1:0]}
          : (cacop_en ? cacop_index : cpu_index);
```

- 别名拍 `ram_read_en = 1`，RAM 以组合重建的**物理索引**重读
- 同一上升沿 `req_index`（或 `cacop_index_r`）修正为物理索引（request/cacop buffer 的 `mmu_index_cancel[_cacop]` 分支），后续消费点（rd_addr / tagv 写地址）直接用修正值
- 下拍 RELOOKUP 以物理索引数据比对（`lookup_tag = refill_tag` 快照）
- 别名标志不锁存（无 REREAD 需求），RELOOKUP 拍自然完成

---

## 6. 数据通路

### 6.1 数据来源

```
live_rdata =
  1. lookup_read_hit_done  → lookup_rdata    （L1 命中：bank_rdata[hit_way][offset]）
  2. refill_read_miss_done → return_data     （miss：AXI 返回数据）
  3. 其他                  → 0
```

### 6.2 输出 FIFO

- 深度 4，解耦数据生产和 CPU 消费
- FIFO 空且数据就绪时数据直通（bypass）
- 先 accept 先返回，顺序不乱；IF 阶段冲刷不影响 cache 侧

### 6.3 CPU 接口契约

- 一次 `cpu_addr_ok` 握手 → 一次 `cpu_data_ok` + 对应数据
- `cpu_addr_ok = accept_new_req && !cacop_en`

---

## 7. uncached 访问

`mmu_cache = 0` 时（IO/外设取指）：

- LOOKUP 必然 miss → WAITRD → REFILL
- `rd_type = 3'b010`（单字读），`rd_addr = {refill_tag, req_index, req_offset}` 精确地址
- REFILL 不写 tagv/bank（`refill_cached = 0`）
- `refill_read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）

---

## 8. CACOP 处理

### 8.1 操作码（`code[4:3]`）

| code[4:3] | 类型 | wen 编码 | 效果 |
|-----------|------|----------|------|
| 00 | store-tag | `{tag 全 1, V=0}` | 只写 tag（清 0），V 保留 |
| 01 | index 类失效 | `{tag 全 0, V=1}` | 只清 V（index 指定路） |
| 10 | hit 失效 | `{tag 全 0, V=1}` | 只清 V（命中路，`refill_tagv_we` 需 `\|refill_way_hit_r`） |
| 11 | — | — | 未处理（无分支） |

> **注意**：00 的语义（只写 tag 保 V）与软件实际用法需确认；`mmu_cacop_tag` 输入提供 cacop 的物理 tag（hit 型比对与别名修正用）。

### 8.2 流程

```
accept_new_req (cacop_en=1)
  → CACOP Buffer 锁存上下文
  → LOOKUP（读 tagv，cache_hit 被 !cacop_en_r 屏蔽）
  → 别名 → RELOOKUP；否则直接 → REFILL（无总线读）
  → REFILL 中 cacop_en_r 触发 tagv 按位写
  → cacop_en_r ← 0，FSM → IDLE
```

- CACOP 不产生 `cpu_data_ok`
- 替换路：code=10 用 `hit_way_idx`，否则用 `cacop_way_r`

---

## 9. PLRU 替换算法

2-way 时 1 bit/组 × 256 组。

- **Accept 拍**：组合遍历 → `plru_victim_pre` → `plru_victim_r`（锁存）
- **LOOKUP 拍**：`replace_way = cacop_en_r ? (10 ? hit_way_idx : cacop_way_r) : (has_invalid ? invalid_way : plru_victim_r)`
- **更新**：命中或 `refill_tagv_we` 时标 MRU（`plru_upd_index = cacop_en_r ? cacop_index_r : req_index`）

---

## 10. AXI 读接口

| 信号 | 说明 |
|------|------|
| `rd_req` | `main_waitrd` |
| `rd_type` | cached → `3'b100`（cache line 读），uncached → `3'b010`（单字读） |
| `rd_addr` | cached: `{refill_tag, req_index, 6'b0}`；uncached: `{refill_tag, req_index, req_offset}` |
| `rd_rdy` | AXI 总线就绪 |
| `return_valid/return_last/return_data` | AXI 读返回通道 |

---

## 11. 性能计数器

| 计数器 | 说明 |
|--------|------|
| `perf_total_req` | 总 accept 次数 |
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
| `mmu_index_cancel*` | 别名检测信号 |
| `cpu_*` | CPU 接口信号 |
| `plru_*` | PLRU 替换算法 |
| `perf_*` | 性能计数器 |

### 关键组合信号速查

| 信号 | 推导 |
|------|------|
| `accept_new_req` | `accept_ok && (cpu_req \| cacop_en) && (IDLE \| (LOOKUP/RELOOKUP && cache_hit))` |
| `cache_hit` | `(\|way_hit) && lookup_cache && !cacop_en_r && !lookup_cancel && !别名` |
| `lookup_cancel` | `(cacop_en_r ? mmu_cacop_cancel : mmu_cancel) && main_lookup` |
| `lookup_tag` | RELOOKUP:`refill_tag` / cacop:`mmu_cacop_tag[19:2]` / 普通:`mmu_tag[19:2]` |
| `ram_read_en` | `accept_new_req \| ((别名) && !lookup_cancel)` |
| `rd_addr` | cached:`{refill_tag, req_index, 6'b0}` / unc:`{refill_tag, req_index, req_offset}` |
| `cpu_addr_ok` | `accept_new_req && !cacop_en` |
| `cpu_data_ok` | `lookup_read_hit_done \| refill_read_miss_done \| !fifo_empty` |
