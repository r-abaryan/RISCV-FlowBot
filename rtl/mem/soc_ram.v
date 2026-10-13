// ============================================================================
// Module: soc_ram
// Description: Wishbone B4 Synchronous SRAM (64 KB / 16384 x 32-bit words)
// Supports byte-level write selects
// Synthesis: 4 byte-wide memories for proper BRAM inference without register bloat
// Simulation: ram_mem array preserved for testbench hierarchical probing
// ============================================================================

`timescale 1ns / 1ps

module soc_ram #(
    parameter MEM_SIZE_WORDS = 16384
) (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone Slave
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output reg         wb_ack_o
);

    wire [13:0] word_addr = wb_adr_i[15:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= wb_cyc_i && wb_stb_i && !wb_ack_o;
        end
    end

`ifdef SYNTHESIS
    reg [7:0] mem0 [0:MEM_SIZE_WORDS-1];
    reg [7:0] mem1 [0:MEM_SIZE_WORDS-1];
    reg [7:0] mem2 [0:MEM_SIZE_WORDS-1];
    reg [7:0] mem3 [0:MEM_SIZE_WORDS-1];

    always @(posedge clk) begin
        if (wb_cyc_i && wb_stb_i) begin
            if (wb_we_i) begin
                if (wb_sel_i[0]) mem0[word_addr] <= wb_dat_i[7:0];
                if (wb_sel_i[1]) mem1[word_addr] <= wb_dat_i[15:8];
                if (wb_sel_i[2]) mem2[word_addr] <= wb_dat_i[23:16];
                if (wb_sel_i[3]) mem3[word_addr] <= wb_dat_i[31:24];
            end
            wb_dat_o <= {mem3[word_addr], mem2[word_addr], mem1[word_addr], mem0[word_addr]};
        end
    end
`else
    reg [31:0] ram_mem [0:MEM_SIZE_WORDS-1];

    integer ram_init_idx;
    initial begin
        for (ram_init_idx = 0; ram_init_idx < MEM_SIZE_WORDS; ram_init_idx = ram_init_idx + 1) begin
            ram_mem[ram_init_idx] = 32'h0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_dat_o <= 32'h0;
        end else if (wb_cyc_i && wb_stb_i) begin
            if (wb_we_i) begin
                if (wb_sel_i[0]) ram_mem[word_addr][7:0]   <= wb_dat_i[7:0];
                if (wb_sel_i[1]) ram_mem[word_addr][15:8]  <= wb_dat_i[15:8];
                if (wb_sel_i[2]) ram_mem[word_addr][23:16] <= wb_dat_i[23:16];
                if (wb_sel_i[3]) ram_mem[word_addr][31:24] <= wb_dat_i[31:24];
            end
            wb_dat_o <= ram_mem[word_addr];
        end
    end
`endif

endmodule
