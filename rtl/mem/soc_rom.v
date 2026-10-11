// ============================================================================
// Module: soc_rom
// Description: Wishbone B4 Synchronous Boot ROM (8 KB / 2048 x 32-bit words)
// ============================================================================

`timescale 1ns / 1ps

module soc_rom #(
    parameter MEM_SIZE_WORDS = 2048,
    parameter INIT_FILE      = ""
) (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone B4 Slave
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output reg         wb_ack_o
);

    reg [31:0] rom_mem [0:MEM_SIZE_WORDS-1];
    integer i;

    initial begin
        for (i = 0; i < MEM_SIZE_WORDS; i = i + 1) begin
            rom_mem[i] = 32'h00000013; // NOP (addi x0, x0, 0)
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, rom_mem);
        end
    end

    wire [10:0] word_addr = wb_adr_i[12:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= wb_cyc_i && wb_stb_i && !wb_ack_o;
            if (wb_cyc_i && wb_stb_i) begin
                wb_dat_o <= rom_mem[word_addr];
            end
        end
    end

endmodule
