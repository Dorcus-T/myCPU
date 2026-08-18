`include "mycpu.h"

module dcache (
    // 时钟与复位
    input  wire                       clk,
    input  wire                       resetn,

    // CPU 流水线接口
    input  wire                       cpu_req,
    input  wire                       cpu_op,
    input  wire [`D_INDEX_WIDTH-1:0]  cpu_index,
    input  wire [19:0]                mmu_tag,         
    input  wire [`D_OFFSET_WIDTH-1:0] cpu_offset,
    input  wire [ 3:0]                cpu_byte_enable,
    input  wire [31:0]                cpu_wdata,
    input  wire                       mmu_cache,
    input  wire                       mmu_cancel,
    output wire                       cpu_addr_ok,
    output wire                       cpu_data_ok,
    output wire [31:0]                cpu_rdata,
    input  wire                       cpu_accept,
    input  wire                       preld,

    // AXI 总线接口
    output wire                       rd_req,
    output wire [ 2:0]                rd_type,
    output wire [31:0]                rd_addr,
    input  wire                       rd_rdy,
    input  wire                       return_valid,
    input  wire                       return_last,
    input  wire [31:0]                return_data,
    output wire                       wr_req,
    output wire [ 2:0]                wr_type,
    output wire [31:0]                wr_addr,
    output wire [ 3:0]                wr_wstrb,
    output wire [32*`D_LINE_WORDS-1:0]wr_data,
    input  wire                       wr_rdy,
    input  wire                       wr_done,

    // CACOP 接口
    input  wire                       cacop_en,
    input  wire [ 4:0]                cacop_code,
    input  wire [31:0]                cacop_va,
    output wire                       cacop_rdy,

    // debug
    output wire [7:0]                 debug_main_state,
    output wire                       debug_rd_req,
    output wire [19:0]                debug_mmu_tag,   
    output wire [`D_INDEX_WIDTH-1:0]  debug_cpu_index,
    output wire                       debug_refill_cached,
    output wire [`D_INDEX_WIDTH-1:0]  debug_req_index,

    // perf 计数器（仿真统计用）
    output wire [31:0]                debug_perf_total_req,
    output wire [31:0]                debug_perf_access_cnt,
    output wire [31:0]                debug_perf_miss_cnt,
    output wire [31:0]                debug_perf_real_miss_cnt,
    output wire [31:0]                debug_perf_relookup_cnt
);

    // ============================================================
    // 局部参数
    // ============================================================
    localparam INDEX_DEPTH = 1 << `D_INDEX_WIDTH;
    localparam BANK_NUM    = `D_LINE_WORDS;
    localparam BANK_IDX_W  = $clog2(BANK_NUM);
    localparam WAY_IDX_W   = $clog2(`D_WAY_NUM);
    localparam PLRU_W      = `D_WAY_NUM - 1;
    localparam TAGV_BYTES  = (`D_TAG_WIDTH + 1 + 7) / 8;
    localparam MMU_TAG_WD  = 20;

    localparam MAIN_IDLE         = 8'b00000001;
    localparam MAIN_LOOKUP       = 8'b00000010;
    localparam MAIN_REREAD       = 8'b00000100;
    localparam MAIN_WAITWR       = 8'b00001000;
    localparam MAIN_WAIT_WR_DONE = 8'b00010000;
    localparam MAIN_WAITRD       = 8'b00100000;
    localparam MAIN_REFILL       = 8'b01000000;
    localparam MAIN_RELOOKUP     = 8'b10000000;

    localparam WB_IDLE  = 1'd0;
    localparam WB_WRITE = 1'd1;

    // ============================================================
    // RAM 存储阵列
    // ============================================================
    wire [`D_TAG_WIDTH:0]     tagv_rdata [0:`D_WAY_NUM-1];
    reg                       d_rdata    [0:`D_WAY_NUM-1];
    wire [31:0]               bank_rdata [0:`D_WAY_NUM-1][0:BANK_NUM-1];
    reg                       d_ram      [0:`D_WAY_NUM-1][0:INDEX_DEPTH-1];

    // ============================================================
    // 状态机有关，主状态机和wb状态机
    // ============================================================
    // 状态寄存器
    reg  [7:0] main_state;
    reg  [7:0] main_next;
    reg        wb_state;
    reg        wb_next;
    
    // 状态机节点
    wire main_idle         = (main_state == MAIN_IDLE);
    wire main_lookup       = (main_state == MAIN_LOOKUP);
    wire main_reread       = (main_state == MAIN_REREAD);
    wire main_waitwr       = (main_state == MAIN_WAITWR);
    wire main_wait_wr_done = (main_state == MAIN_WAIT_WR_DONE);
    wire main_waitrd       = (main_state == MAIN_WAITRD);
    wire main_refill       = (main_state == MAIN_REFILL);
    wire main_relookup     = (main_state == MAIN_RELOOKUP);
    wire wb_idle           = (wb_state == WB_IDLE);
    wire wb_write          = (wb_state == WB_WRITE);

    // ============================================================
    // 各个buffer的声明
    // ============================================================
    // Request Buffer — accept_new_req 时更新，miss 处理期间稳定
    reg                        req_op;
    reg  [`D_INDEX_WIDTH-1:0]  req_index;
    reg  [`D_OFFSET_WIDTH-1:0] req_offset;
    reg  [ 3:0]                req_byte_enable;
    reg  [31:0]                req_wdata;
    reg                        req_preld;

    // cacop buffer - 存cacop有关信号
    reg                        cacop_en_r;
    reg  [4:0]                 cacop_code_r;
    reg  [WAY_IDX_W-1:0]       cacop_way_r;
    reg  [`D_INDEX_WIDTH-1:0]  cacop_index_r;

    // Refill Buffer — 总线读上下文 + REFILL 拼装（6 信号）
    reg  [`D_TAG_WIDTH-1:0]    refill_tag;
    reg                        refill_cached;
    reg  [WAY_IDX_W-1:0]       refill_replace_way;
    reg  [BANK_IDX_W-1:0]      refill_cnt;
    reg  [31:0]                refill_line [0:BANK_NUM-1];
    reg  [`D_WAY_NUM-1:0]      refill_way_hit_r;

    // 命名问题buffer
    reg                        mmu_index_cancel_r;
    reg                        mmu_index_cancel_cacop_r;

    // Write Buffer — 命中 store 时写入，延迟写入 bank RAM
    reg  [`D_WAY_NUM-1:0]      wb_way_hit;
    reg  [`D_INDEX_WIDTH-1:0]  wb_index;
    reg  [BANK_IDX_W-1:0]      wb_bank;
    reg  [ 3:0]                wb_byte_enable;
    reg  [31:0]                wb_wdata;

    // ============================================================
    // CACOP 组合译码
    // ============================================================
    wire [`D_INDEX_WIDTH-1:0] cacop_index = cacop_va[`D_OFFSET_WIDTH +: `D_INDEX_WIDTH];
    wire [WAY_IDX_W-1:0]      cacop_way   = cacop_va[WAY_IDX_W-1:0];
     
    // ============================================================
    // 一些重要信号生成
    // ============================================================
    // 统一 RAM 读控制
    wire ram_read_en = accept_new_req || main_reread || ((mmu_index_cancel || mmu_index_cancel_cacop) && wb_idle);

    wire [`D_INDEX_WIDTH-1:0] reread_addr = cacop_en_r ? cacop_index_r : req_index;

    wire [`D_INDEX_WIDTH-1:0] index_cancel_addr = mmu_index_cancel ? {mmu_tag[MMU_TAG_WD - `D_TAG_WIDTH - 1 : 0], req_index[`D_INDEX_WIDTH - MMU_TAG_WD + `D_TAG_WIDTH -1 :0]} 
                                                : {mmu_tag[MMU_TAG_WD - `D_TAG_WIDTH - 1 : 0], cacop_index_r[`D_INDEX_WIDTH - MMU_TAG_WD + `D_TAG_WIDTH -1 :0]};
   
    wire [`D_INDEX_WIDTH-1:0] ram_raddr = main_reread ? reread_addr 
                                        : ((mmu_index_cancel || mmu_index_cancel_cacop) && wb_idle) ? index_cancel_addr
                                        : cacop_en    ? cacop_index
                                        : cpu_index;

    // accept_new_req — (IDLE || LOOKUP hit) && !冲突 && accept_ok
    wire accept_new_req = accept_ok && (cpu_req || cacop_en) && (main_idle || ((main_lookup || main_relookup) && cache_hit))
                                    && !(wb_write && !cpu_op && (wb_bank == cpu_offset[`D_OFFSET_WIDTH-1:2]));

    // REFILL 节拍
    wire refill_last = main_refill && return_valid && return_last;

    // VIPT 别名检测 — index 高位越界进页号时与物理 tag 低位比较
    wire mmu_index_cancel = main_lookup && !cacop_en_r && (req_index[`D_INDEX_WIDTH-1 : 12 - `D_OFFSET_WIDTH] != mmu_tag[MMU_TAG_WD - `D_TAG_WIDTH - 1 : 0]);
    wire mmu_index_cancel_cacop = main_lookup && cacop_en_r && (cacop_code_r[4:3] == 2'b10) && (cacop_index_r[`D_INDEX_WIDTH-1 : 12 - `D_OFFSET_WIDTH] != mmu_tag[MMU_TAG_WD - `D_TAG_WIDTH - 1 : 0]);

    //lookup以后阶段判定是否是uncache store指令
    wire is_uncached_store = !refill_cached && req_op && !cacop_en_r;

    // 写回需求 — WAITWR 拍组合判定
    wire wr_needs_write = cacop_en_r ? (cacop_code_r[4:3]==2'b00 || cacop_code_r[4:3]==2'b01 || (cacop_code_r[4:3]==2'b10 && |refill_way_hit_r)) && tagv_rdata[refill_replace_way][0] && d_rdata[refill_replace_way]
                                     : ((refill_cached && tagv_rdata[refill_replace_way][0] && d_rdata[refill_replace_way]) || is_uncached_store);

    // ============================================================
    // Tag 比较与命中判断 — XOR 树实现（强制 LUT，避免 CARRY4 减法器）
    // ============================================================
    wire                    lookup_cache  = main_relookup ? refill_cached :
                                            cacop_en_r    ? 1'b1 : mmu_cache;
    wire [`D_TAG_WIDTH-1:0] lookup_tag    = main_relookup ? refill_tag :
                                            mmu_tag[MMU_TAG_WD-1 : MMU_TAG_WD - `D_TAG_WIDTH];
    wire                    lookup_cancel = mmu_cancel && main_lookup;

    wire [`D_TAG_WIDTH-1:0] tag_diff     [0:`D_WAY_NUM-1];
    wire                    tag_match    [0:`D_WAY_NUM-1];
    wire [`D_WAY_NUM-1:0]   way_hit;

    genvar gh;
    generate
        for (gh = 0; gh < `D_WAY_NUM; gh = gh + 1) begin : way_hit_gen
            assign tag_diff[gh]  = tagv_rdata[gh][`D_TAG_WIDTH:1] ^ lookup_tag;
            assign tag_match[gh] = ~(|tag_diff[gh]);
            assign way_hit[gh]   = tagv_rdata[gh][0] && tag_match[gh];
        end
    endgenerate

    wire cache_hit = (|way_hit) && lookup_cache && !cacop_en_r && !lookup_cancel && !(mmu_index_cancel || mmu_index_cancel_cacop);

    // ============================================================
    // 命中路号编码
    // ============================================================
    wire [WAY_IDX_W-1:0] hit_way_idx;

    genvar hb, hw;
    generate
        for (hb = 0; hb < WAY_IDX_W; hb = hb + 1) begin : hit_enc
            wire [`D_WAY_NUM-1:0] hit_term;
            for (hw = 0; hw < `D_WAY_NUM; hw = hw + 1) begin : hit_bit
                if ((hw >> hb) & 1'b1)
                    assign hit_term[hw] = way_hit[hw];
                else
                    assign hit_term[hw] = 1'b0;
            end
            assign hit_way_idx[hb] = |hit_term;
        end
    endgenerate

    // ============================================================
    // 替换路号计算
    // ============================================================   
    // 无效路计算
    wire [`D_WAY_NUM-1:0] way_invalid;

    genvar iw;
    generate
        for (iw = 0; iw < `D_WAY_NUM; iw = iw + 1) begin : inv_flag
            assign way_invalid[iw] = !tagv_rdata[iw][0];
        end
    endgenerate
    wire has_invalid = |way_invalid;

    // 高于当前路号的 V 位全有效检测（自顶向下前缀 AND）
    wire [`D_WAY_NUM-1:0] higher_valid;
    
    genvar hv;
    generate
        for (hv = 0; hv < `D_WAY_NUM - 1; hv = hv + 1) begin : hv_chain
            assign higher_valid[hv] = higher_valid[hv+1] && tagv_rdata[hv+1][0];
        end
    endgenerate
    assign higher_valid[`D_WAY_NUM-1] = 1'b1;

    // 每位由符合条件的路号 OR 产生
    wire [WAY_IDX_W-1:0]  invalid_way;

    genvar ib;
    generate
        for (ib = 0; ib < WAY_IDX_W; ib = ib + 1) begin : inv_enc
            wire [`D_WAY_NUM-1:0] inv_term;
            for (iw = 0; iw < `D_WAY_NUM; iw = iw + 1) begin : inv_bit
                if ((iw >> ib) & 1'b1)
                    assign inv_term[iw] = way_invalid[iw] && higher_valid[iw];
                else
                    assign inv_term[iw] = 1'b0;
            end
            assign invalid_way[ib] = |inv_term;
        end
    endgenerate

    // PLRU 预计算
    reg  [PLRU_W-1:0]  plru [0:INDEX_DEPTH-1];
    reg  [WAY_IDX_W:0] plru_node_pre;

    integer plv_pre;
    always @(*) begin
        plru_node_pre = 1;
        for (plv_pre = 0; plv_pre < WAY_IDX_W; plv_pre = plv_pre + 1)
            plru_node_pre = (plru_node_pre << 1) + plru[ram_raddr][plru_node_pre-1];
    end
    wire [WAY_IDX_W-1:0] plru_victim_pre = plru_node_pre - `D_WAY_NUM;


    reg  [WAY_IDX_W-1:0] plru_victim_r;

    always @(posedge clk) begin
        if (~resetn)
            plru_victim_r <= {WAY_IDX_W{1'b0}};
        else if (accept_new_req)
            plru_victim_r <= plru_victim_pre;
    end

    // 替换路号
    wire [WAY_IDX_W-1:0] replace_way = cacop_en_r ? ((cacop_code_r[4:3] == 2'b10) ? hit_way_idx : cacop_way_r) :
                                                    (has_invalid ? invalid_way : plru_victim_r);

    // ============================================================
    // 各状态机变化 — 时序
    // ============================================================
    // 主状态机时序变化
    always @(posedge clk) begin
        if (~resetn)
            main_state <= MAIN_IDLE;
        else
            main_state <= main_next;
    end

    // ============================================================
    // 主状态机 — 下一状态逻辑（并行 assign，消除 case 级联延迟）
    // ============================================================ 
    wire main_idle_lookup   = main_idle && accept_new_req;

    wire main_lookup_recheck_1     = main_lookup && (mmu_index_cancel || mmu_index_cancel_cacop) && !lookup_cancel && wb_idle;
    wire main_lookup_recheck_2     = main_lookup && (mmu_index_cancel || mmu_index_cancel_cacop) && !lookup_cancel && wb_write;
    wire main_lookup_cancel        = main_lookup && lookup_cancel;
    wire main_lookup_reread        = (main_lookup || main_relookup) && !cache_hit && !(mmu_index_cancel || mmu_index_cancel_cacop) && (lookup_cache || cacop_en_r) && !lookup_cancel;
    wire main_lookup_uncached_st_miss = (main_lookup || main_relookup) && !cache_hit && !(mmu_index_cancel || mmu_index_cancel_cacop) && !lookup_cache && !cacop_en_r && !lookup_cancel && req_op;
    wire main_lookup_uncached_ld_miss = (main_lookup || main_relookup) && !cache_hit && !(mmu_index_cancel || mmu_index_cancel_cacop) && !lookup_cache && !cacop_en_r && !lookup_cancel && !req_op;
    wire main_lookup_lookup        = (main_lookup || main_relookup) && cache_hit && accept_new_req;

    wire main_reread_relookup = main_reread && (mmu_index_cancel_r || mmu_index_cancel_cacop_r);
    wire main_reread_waitwr   = main_reread && !(mmu_index_cancel_r || mmu_index_cancel_cacop_r);
   
    wire main_waitwr_waitdone  = main_waitwr && is_uncached_store && wr_rdy;
    wire main_waitwr_refill    = main_waitwr && !is_uncached_store
                               && (!wr_needs_write || wr_rdy) && cacop_en_r;
    wire main_waitwr_waitrd    = main_waitwr && !is_uncached_store
                               && (!wr_needs_write || wr_rdy) && !cacop_en_r;
    wire main_waitwr_stay      = main_waitwr && (is_uncached_store ? !wr_rdy : wr_needs_write && !wr_rdy);

    wire main_waitdone_idle   = main_wait_wr_done && wr_done;
    wire main_waitdone_stay   = main_wait_wr_done && !wr_done;

    wire main_waitrd_refill   = main_waitrd && rd_rdy;
    wire main_waitrd_stay     = main_waitrd && !rd_rdy;

    wire main_refill_idle     = main_refill && (refill_last || cacop_en_r);
    wire main_refill_stay     = main_refill && !refill_last && !cacop_en_r;

    always @(*) begin
        main_next = MAIN_IDLE;
        if (main_idle_lookup)                              main_next = MAIN_LOOKUP;
        if (main_lookup_lookup)                            main_next = MAIN_LOOKUP;
        if (main_lookup_recheck_1)                         main_next = MAIN_RELOOKUP;
        if (main_lookup_recheck_2)                         main_next = MAIN_REREAD;
        if (main_lookup_uncached_st_miss)                  main_next = MAIN_WAITWR;
        if (main_lookup_uncached_ld_miss)                  main_next = MAIN_WAITRD;
        if (main_lookup_reread)                            main_next = MAIN_REREAD;
        if (main_reread_relookup)                          main_next = MAIN_RELOOKUP;
        if (main_reread_waitwr)                            main_next = MAIN_WAITWR;
        if (main_waitwr_refill)                            main_next = MAIN_REFILL;
        if (main_waitwr_waitrd)                            main_next = MAIN_WAITRD;
        if (main_waitwr_waitdone)                          main_next = MAIN_WAIT_WR_DONE;
        if (main_waitwr_stay)                              main_next = MAIN_WAITWR;
        if (main_waitdone_idle)                            main_next = MAIN_IDLE;
        if (main_waitdone_stay)                            main_next = MAIN_WAIT_WR_DONE;
        if (main_waitrd_refill)                            main_next = MAIN_REFILL;
        if (main_waitrd_stay)                              main_next = MAIN_WAITRD;
        if (main_refill_idle)                              main_next = MAIN_IDLE;
        if (main_refill_stay)                              main_next = MAIN_REFILL;
    end

    // Write Buffer 状态机 — 时序
    always @(posedge clk) begin
        if (~resetn)
            wb_state <= WB_IDLE;
        else
            wb_state <= wb_next;
    end

    wire wb_new_store_hit = (main_lookup || main_relookup) && cache_hit && req_op;

    always @(*) begin
        case (wb_state)
            WB_IDLE:   wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            WB_WRITE:  wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            default:   wb_next = WB_IDLE;
        endcase
    end

    // ============================================================
    // PLRU 更新
    // ============================================================
    wire                      plru_upd_en    = ((main_lookup || main_relookup) && cache_hit) || refill_tagv_we;
    wire [WAY_IDX_W-1:0]      plru_upd_way   = ((main_lookup || main_relookup)&& cache_hit) ? hit_way_idx : refill_replace_way;
    wire [`D_INDEX_WIDTH-1:0] plru_upd_index = refill_tagv_we && cacop_en_r ? cacop_index_r : req_index;

    integer pnode, pparent, pui, prst;
    always @(posedge clk) begin
        if (~resetn) begin
            for (prst = 0; prst < INDEX_DEPTH; prst = prst + 1)
                plru[prst] = {PLRU_W{1'b0}};
        end
        else if (plru_upd_en) begin
            pnode = `D_WAY_NUM + plru_upd_way;
            for (pui = 0; pui < WAY_IDX_W; pui = pui + 1) begin
                pparent = pnode >> 1;
                plru[plru_upd_index][pparent-1] <= ~pnode[0];
                pnode = pparent;
            end
        end
    end

    // ============================================================
    // 各个buffer的更新
    // ============================================================
    // request buffer
    always @(posedge clk) begin
        if (~resetn) begin
            req_op           <= 1'b0;
            req_index        <= {`D_INDEX_WIDTH{1'b0}};
            req_offset       <= {`D_OFFSET_WIDTH{1'b0}};
            req_byte_enable  <= 4'd0;
            req_wdata        <= 32'd0;
            req_preld        <= 1'b0;
        end
        else if (accept_new_req) begin
            req_op           <= cpu_op;
            req_index        <= cpu_index;
            req_offset       <= cpu_offset;
            req_byte_enable  <= cpu_byte_enable;
            req_wdata        <= cpu_wdata;
            req_preld        <= preld;
        end
        else if (mmu_index_cancel) begin
            req_index <= {mmu_tag[MMU_TAG_WD - `D_TAG_WIDTH - 1 : 0],req_index[`D_INDEX_WIDTH - MMU_TAG_WD + `D_TAG_WIDTH -1 :0]};
        end
    end

    // cacop buffer
    always @(posedge clk) begin
        if (~resetn) begin
            cacop_en_r       <= 1'b0;
            cacop_code_r     <= 5'b0;
            cacop_way_r      <= {WAY_IDX_W{1'b0}};
            cacop_index_r    <= {`D_INDEX_WIDTH{1'b0}};
        end
        else if (accept_new_req) begin
            cacop_en_r       <= cacop_en;
            cacop_code_r     <= cacop_code;
            cacop_way_r      <= cacop_way;
            cacop_index_r    <= cacop_index;
        end
        else if (mmu_index_cancel_cacop) begin
            cacop_index_r <= {mmu_tag[MMU_TAG_WD - `D_TAG_WIDTH - 1 : 0],cacop_index_r[`D_INDEX_WIDTH - MMU_TAG_WD + `D_TAG_WIDTH -1 :0]};
        end
        else if (main_refill) begin
            cacop_en_r <= 1'b0;
        end
    end

    // Write Buffer — 时序更新
    always @(posedge clk) begin
        if (wb_new_store_hit) begin
            wb_way_hit     <= way_hit;
            wb_index       <= req_index;
            wb_bank        <= req_offset[`D_OFFSET_WIDTH-1:2];
            wb_byte_enable <= req_byte_enable;
            wb_wdata       <= req_wdata;
        end
    end

    // Refill Buffer — LOOKUP miss 锁存，REFILL 拼装
    always @(posedge clk) begin
        // LOOKUP miss: 锁存总线读上下文 + 牺牲路号
        if (main_lookup && !cache_hit) begin
            refill_tag         <= lookup_tag;
            refill_cached      <= lookup_cache;
            refill_replace_way <= replace_way;
            refill_cnt         <= {BANK_IDX_W{1'b0}};
            refill_way_hit_r   <= way_hit;
        end
        else if (main_relookup && !cache_hit) begin
            refill_replace_way  <= replace_way;
            refill_way_hit_r    <= way_hit;
        end
        // REFILL 计数
        if (main_refill && return_valid) begin
            refill_cnt <= refill_cnt + 2'd1;
            if (refill_cached)
                refill_line[refill_cnt] <= refill_merged_word;
        end
    end
    
    // 命名问题buffer
    always @(posedge clk) begin
        if (main_lookup && !cache_hit) begin
            mmu_index_cancel_r       <= mmu_index_cancel;
            mmu_index_cancel_cacop_r <= mmu_index_cancel_cacop;
        end
        if (main_relookup) begin
            mmu_index_cancel_r <= 1'b0;
            mmu_index_cancel_cacop_r <= 1'b0;
        end
    end
    // ============================================================
    // 数据处理
    // ============================================================
    // lookup返回数据
    wire [31:0] lookup_bank_data = bank_rdata[hit_way_idx][req_offset[`D_OFFSET_WIDTH-1:2]];

    wire [31:0] wb_byte_mask  = {{8{wb_byte_enable[3]}}, {8{wb_byte_enable[2]}}, {8{wb_byte_enable[1]}}, {8{wb_byte_enable[0]}}};

    wire [31:0] lookup_rdata = ((main_lookup || main_relookup) && wb_write && !req_op && (wb_index == req_index) && wb_way_hit[hit_way_idx] && (wb_bank == req_offset[`D_OFFSET_WIDTH-1:2])) ?
                               ((wb_wdata & wb_byte_mask) | (lookup_bank_data & ~wb_byte_mask)) : lookup_bank_data;

    // REFILL 合并写数据
    wire [31:0] req_byte_mask = {{8{req_byte_enable[3]}}, {8{req_byte_enable[2]}}, {8{req_byte_enable[1]}}, {8{req_byte_enable[0]}}};
    wire        req_byte_half = (req_byte_enable == 4'b0011) || (req_byte_enable == 4'b1100);
    wire [31:0] refill_merged_word = (req_op && (refill_cnt == req_offset[`D_OFFSET_WIDTH-1:2])) 
                                     ? ((req_wdata & req_byte_mask) | (return_data & ~req_byte_mask)) 
                                     : return_data;
   
    // 输出 FIFO
    reg  [31:0] cpu_fifo_mem [0:3];
    reg  [ 1:0] cpu_fifo_wptr;
    reg  [ 1:0] cpu_fifo_rptr;
    reg  [ 2:0] cpu_fifo_cnt;

    wire cpu_fifo_empty = (cpu_fifo_cnt == 3'd0);
    wire cpu_fifo_we = (lookup_read_hit_done || refill_read_miss_done) && (!cpu_accept || !cpu_fifo_empty) && !req_preld;
    wire cpu_fifo_re = cpu_accept && !cpu_fifo_empty && !req_preld;

    wire lookup_read_hit_done  = (main_lookup || main_relookup) && cache_hit && !req_op;
    wire lookup_write_done     = (main_lookup || main_relookup) && req_op;
    wire lookup_preld_done     = (main_lookup || main_relookup) && req_preld;
    wire refill_read_miss_done = main_refill && return_valid && !req_op && (refill_cnt == req_offset[`D_OFFSET_WIDTH-1:2] || !refill_cached);

    wire [31:0] live_rdata = lookup_read_hit_done  ? lookup_rdata :
                             refill_read_miss_done ? return_data  : 32'd0;

    wire accept_ok = cpu_op || (cpu_fifo_cnt < 3'd3) || (cpu_fifo_cnt == 3'd3 && req_op);

    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy   = accept_new_req && cacop_en;
    assign cpu_data_ok = (lookup_read_hit_done || refill_read_miss_done || !cpu_fifo_empty) || lookup_write_done || lookup_preld_done;
    assign cpu_rdata   = cpu_fifo_empty ? live_rdata : cpu_fifo_mem[cpu_fifo_rptr];

    integer oi;
    always @(posedge clk) begin
        if (~resetn) begin
            cpu_fifo_wptr <= 2'd0;
            cpu_fifo_rptr <= 2'd0;
            cpu_fifo_cnt  <= 3'd0;
            for (oi = 0; oi < 4; oi = oi + 1)
                cpu_fifo_mem[oi] <= 32'b0;
        end
        else begin
            case ({cpu_fifo_we, cpu_fifo_re})
                2'b10: begin
                    cpu_fifo_mem[cpu_fifo_wptr] <= live_rdata;
                    cpu_fifo_wptr <= cpu_fifo_wptr + 2'd1;
                    cpu_fifo_cnt  <= cpu_fifo_cnt  + 3'd1;
                end
                2'b01: begin
                    cpu_fifo_rptr <= cpu_fifo_rptr + 2'd1;
                    cpu_fifo_cnt  <= cpu_fifo_cnt  - 3'd1;
                end
                2'b11: begin
                    cpu_fifo_mem[cpu_fifo_wptr] <= live_rdata;
                    cpu_fifo_wptr <= cpu_fifo_wptr + 2'd1;
                    cpu_fifo_rptr <= cpu_fifo_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ============================================================
    // 存储数据管理
    // ============================================================
    // TagV相关逻辑
    wire                      refill_tagv_we = main_refill && ((return_valid && return_last && refill_cached) || (cacop_en_r && ((cacop_code_r[4:3] == 2'b00)|| (cacop_code_r[4:3] == 2'b01) || ((cacop_code_r[4:3] == 2'b10) && (|refill_way_hit_r)))));
    wire [`D_INDEX_WIDTH-1:0] tagv_waddr_sel = cacop_en_r ? cacop_index_r : req_index;
    wire [ 3:0]               tagv_wmask_sel = (cacop_en_r && (cacop_code_r[4:3] == 2'b01 || cacop_code_r[4:3] == 2'b10)) ? 4'b0001 : {TAGV_BYTES{1'b1}};
    wire [`D_TAG_WIDTH:0]     tagv_wdata_sel = cacop_en_r ? {(`D_TAG_WIDTH+1){1'b0}} : {refill_tag, 1'b1};

    genvar gt;
    generate
        for (gt = 0; gt < `D_WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire         tagv_wr  = (refill_tagv_we && (refill_replace_way == gt));
            wire         tagv_en  = tagv_wr || ram_read_en;
            wire [ 3:0]  tagv_wen = tagv_wr ? tagv_wmask_sel : 4'b0;
            wire [`D_INDEX_WIDTH-1:0] tagv_addr = tagv_wr ? tagv_waddr_sel : ram_raddr;

            sp_ram #(
                .WIDTH (`D_TAG_WIDTH + 1),
                .DEPTH (INDEX_DEPTH),
                .ADDRW (`D_INDEX_WIDTH)
            ) u_tagv_ram (
                .clk   (clk),
                .en    (tagv_en),
                .wen   (tagv_wen),
                .addr  (tagv_addr),
                .wdata ({ {32-(`D_TAG_WIDTH+1){1'b0}}, tagv_wdata_sel }),
                .rdata (tagv_rdata[gt])
            );
        end
    endgenerate

    // D RAM相关逻辑
    integer d_wi;
    integer d_idx;
    always @(posedge clk) begin
        if (~resetn) begin
            for (d_wi = 0; d_wi < `D_WAY_NUM; d_wi = d_wi + 1) begin
                for (d_idx = 0; d_idx < INDEX_DEPTH; d_idx = d_idx + 1)
                    d_ram[d_wi][d_idx] = 1'b0;
            end
        end
        else begin
            for (d_wi = 0; d_wi < `D_WAY_NUM; d_wi = d_wi + 1) begin
                if ((main_refill && return_valid && return_last && refill_cached) && (refill_replace_way == d_wi))
                    d_ram[d_wi][req_index] <= req_op;
                else if (wb_write && wb_way_hit[d_wi])
                    d_ram[d_wi][wb_index] <= 1'b1;
            end
            if (ram_read_en) begin
                for (d_wi = 0; d_wi < `D_WAY_NUM; d_wi = d_wi + 1)    
                    d_rdata[d_wi] <= d_ram[d_wi][ram_raddr];
            end
        end
    end

    // Data Bank RAM 例化
    genvar gw, gb;
    generate
        for (gw = 0; gw < `D_WAY_NUM; gw = gw + 1) begin : bank_ram_way
            for (gb = 0; gb < BANK_NUM; gb = gb + 1) begin : bank_ram_col
                wire bank_wr_refill = main_refill && return_valid && return_last && (refill_replace_way == gw) && refill_cached;
                wire bank_wr_hit    = wb_write && wb_way_hit[gw] && (wb_bank == gb);

                wire bank_en  = bank_wr_refill || bank_wr_hit || ram_read_en;
                wire [ 3:0] bank_wen = bank_wr_refill ? 4'b1111 :
                                       bank_wr_hit    ? wb_byte_enable :
                                                        4'b0;
                wire [`D_INDEX_WIDTH-1:0] bank_addr = bank_wr_refill ? req_index :
                                                      bank_wr_hit    ? wb_index :
                                                                       ram_raddr;

                wire [31:0] bank_wdata = bank_wr_refill ? ((refill_cnt == gb) ? refill_merged_word : refill_line[gb]) :
                                         bank_wr_hit    ? wb_wdata :
                                                          32'd0;

                sp_ram #(
                    .WIDTH (32),
                    .DEPTH (INDEX_DEPTH),
                    .ADDRW (`D_INDEX_WIDTH)
                ) u_bank_ram (
                    .clk   (clk),
                    .en    (bank_en),
                    .wen   (bank_wen),
                    .addr  (bank_addr),
                    .wdata (bank_wdata),
                    .rdata (bank_rdata[gw][gb])   // 读输出保持外层数组索引
                );
            end
        end
    endgenerate

    // ============================================================
    // AXI 交互
    // ============================================================
    // AXI读请求
    assign rd_req = main_waitrd;

    wire [1:0] rd_size = (&req_byte_enable) ? 2'b10 :
                          req_byte_half     ? 2'b01 :
                                              2'b00 ;
    assign rd_type = refill_cached ? 3'b100 : {1'b0, rd_size};

    assign rd_addr = refill_cached ?
                    {refill_tag, req_index, {`D_OFFSET_WIDTH{1'b0}}} :
                    {refill_tag, req_index, req_offset};

    // AXI 写请求 — 仅 WAITWR 状态
    assign wr_req = main_waitwr && wr_needs_write;

    assign wr_type = !is_uncached_store   ? 3'b100
                     : (&req_byte_enable) ? 3'b010
                     : req_byte_half      ? 3'b001
                                          : 3'b000;

    assign wr_addr = is_uncached_store ? {refill_tag, req_index, req_offset}
                   : cacop_en_r        ? {tagv_rdata[refill_replace_way][`D_TAG_WIDTH:1], cacop_index_r, {`D_OFFSET_WIDTH{1'b0}}} 
                   :{tagv_rdata[refill_replace_way][`D_TAG_WIDTH:1], req_index, {`D_OFFSET_WIDTH{1'b0}}}; 
                     
    assign wr_wstrb = !is_uncached_store ? 4'b1111 : req_byte_enable;

    // 写回数据 — 整行 bank 拼接
    wire [32*BANK_NUM-1:0] wr_data_cached;
    genvar gwb;
    generate
        for (gwb = 0; gwb < BANK_NUM; gwb = gwb + 1) begin : wr_data_pack
            assign wr_data_cached[gwb*32 +: 32] = bank_rdata[refill_replace_way][gwb];
        end
    endgenerate

    wire [32*BANK_NUM-1:0] wr_data_uncached = {{32*(BANK_NUM-1){1'b0}}, req_wdata};

    assign wr_data = !is_uncached_store ? wr_data_cached : wr_data_uncached;

    // ============================================================
    // 性能计数器
    // ============================================================
    reg [31:0] perf_total_req       /*verilator public*/;   // 访存指令总数（load+store，不含 cacop）
    reg [31:0] perf_access_cnt      /*verilator public*/;   // cache 指令总数
    reg [31:0] perf_miss_cnt        /*verilator public*/;   // cache 指令中 L1 miss
    reg [31:0] perf_real_miss_cnt   /*verilator public*/;   // L1 miss  （真实 miss）
    reg [31:0] perf_relookup_cnt    /*verilator public*/;   // VIPT 别名重查次数

    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req        <= 32'd0;
            perf_access_cnt       <= 32'd0;
            perf_miss_cnt         <= 32'd0;
            perf_real_miss_cnt    <= 32'd0;
            perf_relookup_cnt     <= 32'd0;
        end
        else begin
            if (accept_new_req && !cacop_en)
                perf_total_req <= perf_total_req + 32'd1;
            if ((main_lookup || main_relookup) && mmu_cache && !cacop_en_r && !lookup_cancel && !(mmu_index_cancel || mmu_index_cancel_cacop)) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit) begin
                    perf_miss_cnt      <= perf_miss_cnt      + 32'd1;
                    perf_real_miss_cnt <= perf_real_miss_cnt + 32'd1;
                end
            end
            if (main_reread_relookup)
                perf_relookup_cnt <= perf_relookup_cnt + 32'd1;
        end
    end
    assign debug_main_state    = main_state;
    assign debug_rd_req        = rd_req;
    assign debug_mmu_tag       = mmu_tag;
    assign debug_cpu_index     = cpu_index;
    assign debug_refill_cached = refill_cached;
    assign debug_req_index     = req_index;

    assign debug_perf_total_req     = perf_total_req;
    assign debug_perf_access_cnt    = perf_access_cnt;
    assign debug_perf_miss_cnt      = perf_miss_cnt;
    assign debug_perf_real_miss_cnt = perf_real_miss_cnt;
    assign debug_perf_relookup_cnt = perf_relookup_cnt;

endmodule
