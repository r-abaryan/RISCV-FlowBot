// ============================================================================
// Module: soc_uart
// Description: Wishbone B4 Simple UART / Simulation Diagnostic Console
// Base Address: 0x5000_0100
// ============================================================================

`timescale 1ns / 1ps

module soc_uart (
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
    output reg         wb_ack_o,

    // Physical Serial Tx (for FPGA synthesis)
    output reg         uart_tx
);

    reg [7:0] tx_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
            uart_tx  <= 1'b1;
        end else begin
            wb_ack_o <= 1'b0;

            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (wb_adr_i[7:0])
                        8'h00: begin
                            tx_byte <= wb_dat_i[7:0];
                            // In simulation: stream directly to stdout
                            $write("%c", wb_dat_i[7:0]);
                            $fflush();
                        end
                        default: ;
                    endcase
                end else begin
                    case (wb_adr_i[7:0])
                        8'h00: wb_dat_o <= {24'h0, tx_byte};
                        8'h04: wb_dat_o <= 32'h0000_0001; // TX ready bit
                        default: wb_dat_o <= 32'h0;
                    endcase
                end
            end
        end
    end

endmodule
