// ============================================================================
// 单端口同步 TagV RAM（按位写使能，位宽随 tag 位宽参数化）
//   - 条目布局 = {tag[TAG_WIDTH:1], V[0]}，wen 按位独立：[0] 控 V，[TAG_WIDTH:1] 控 tag
//   - 位级使能支持三类独立写：只清 V（cacop invalidate 01/10）、只写 tag（cacop store-tag 00）、
//     全写（refill 填行 {refill_tag, 1'b1}）
//   - 注：位级写使能无法推断进 BRAM（BRAM 仅字节级 WE），实现为 LUTRAM；tag 阵列容量小，可接受
//   - rdata 同步输出（读延迟一拍）
// ============================================================================
module tagv_ram #(
    parameter TAG_WIDTH = 12,   // tag 位宽（不含 V）
    parameter DEPTH     = 256,  // 组数
    parameter ADDRW     = 8     // 地址位宽
) (
    input  wire                     clk,
    input  wire                     en,
    input  wire [TAG_WIDTH:0]       wen,    // 按位写使能 [TAG_WIDTH:1]=tag, [0]=V
    input  wire [ADDRW-1:0]         addr,
    input  wire [TAG_WIDTH:0]       wdata,  // 写数据 {tag, V}
    output wire [TAG_WIDTH:0]       rdata
);

    reg [TAG_WIDTH:0] mem [0:DEPTH-1];
    reg [TAG_WIDTH:0] rdata_r;

    // 仿真初始化
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1)
            mem[init_i] = {TAG_WIDTH+1{1'b0}};
        rdata_r = {TAG_WIDTH+1{1'b0}};
    end

    // 单端口同步读写 — 按位写使能
    integer wb;
    always @(posedge clk) begin
        if (en) begin
            if (|wen) begin
                for (wb = 0; wb <= TAG_WIDTH; wb = wb + 1) begin
                    if (wen[wb]) mem[addr][wb] <= wdata[wb];
                end
            end
            else begin
                rdata_r <= mem[addr];
            end
        end
    end

    assign rdata = rdata_r;

endmodule
