// ============================================================================
// Module: soc_ram
// Description: Wishbone B4 Synchronous SRAM (64 KB / 16384 x 32-bit words)
// Supports byte-level write selects
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

    reg [31:0] ram_mem [0:MEM_SIZE_WORDS-1];
    wire [13:0] word_addr = wb_adr_i[15:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= wb_cyc_i && wb_stb_i && !wb_ack_o;
            if (wb_cyc_i && wb_stb_i) begin
                if (wb_we_i) begin
                    if (wb_sel_i[0]) ram_mem[word_addr][7:0]   <= wb_dat_i[7:0];
                    if (wb_sel_i[1]) ram_mem[word_addr][15:8]  <= wb_dat_i[15:8];
                    if (wb_sel_i[2]) ram_mem[word_addr][23:16] <= wb_dat_i[23:16];
                    if (wb_sel_i[3]) ram_mem[word_addr][31:24] <= wb_dat_i[31:24];
                end
                wb_dat_o <= ram_mem[word_addr];
            end
        end
    end

endmodule
