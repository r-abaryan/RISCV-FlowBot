// ============================================================================
// Module: soc_uart
// Description: Wishbone B4 UART transmitter (8N1), fixed compile-time divider.
// Base Address: 0x5000_0100
//
// Register map (D-B, approved 2026-10-17):
//   0x00 TXDATA  W : bits[7:0] = byte to send. If TX is busy the write is
//                    acknowledged, the byte is DISCARDED and sticky OVERRUN
//                    (STATUS bit 2) is set. R : reads 0.
//   0x04 RXDATA  R : reads 0 (no receiver). Writes ignored.
//   0x08 STATUS  R : bit0 TX_BUSY, bit1 reserved (RX_VALID, always 0),
//                    bit2 TX_OVERRUN (sticky). W : writing 1 to bit2 clears
//                    TX_OVERRUN (W1C); other bits ignored. If a clear and a
//                    dropped TXDATA write ever coincide, OVERRUN stays set.
//   0x0C BAUD    R : reads 0. Writes ignored (divider is fixed at compile time).
// Reset (async, active low) aborts any frame in progress, line returns high,
// OVERRUN is cleared.
// Status: implemented + simulated only. Not synthesised/board-tested here.
// ============================================================================

`timescale 1ns / 1ps

module soc_uart #(
    // Clock cycles per serial bit. 217 ~ 115200 baud @ 25 MHz (ULX3S oscillator).
    parameter UART_CLKS_PER_BIT = 217
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
    output reg         wb_ack_o,

    // Physical Serial Tx
    output reg         uart_tx
);

    localparam integer CNT_W = (UART_CLKS_PER_BIT > 1) ? $clog2(UART_CLKS_PER_BIT) : 1;

    reg             busy;
    reg [9:0]       shreg;     // {stop, data[7:0], start}; LSB is sent first
    reg [3:0]       bit_idx;   // 0..9
    reg [CNT_W-1:0] clk_cnt;
    reg             overrun;

    wire bus_req   = wb_cyc_i && wb_stb_i && !wb_ack_o;
    wire wr_txdata = bus_req && wb_we_i && (wb_adr_i[7:0] == 8'h00);
    wire wr_status = bus_req && wb_we_i && (wb_adr_i[7:0] == 8'h08);
    wire drop_wr   = wr_txdata && busy;
    wire clr_ovr   = wr_status && wb_dat_i[2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
            uart_tx  <= 1'b1;
            busy     <= 1'b0;
            shreg    <= 10'h3FF;
            bit_idx  <= 4'd0;
            clk_cnt  <= {CNT_W{1'b0}};
            overrun  <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;

            // ---- serializer ----
            if (busy) begin
                if (clk_cnt == UART_CLKS_PER_BIT - 1) begin
                    clk_cnt <= {CNT_W{1'b0}};
                    if (bit_idx == 4'd9) begin
                        busy    <= 1'b0;
                        uart_tx <= 1'b1;
                    end else begin
                        bit_idx <= bit_idx + 4'd1;
                        uart_tx <= shreg[bit_idx + 4'd1];
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end

            // ---- bus ----
            if (bus_req) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    if (wr_txdata && !busy) begin
                        shreg   <= {1'b1, wb_dat_i[7:0], 1'b0};
                        busy    <= 1'b1;
                        bit_idx <= 4'd0;
                        clk_cnt <= {CNT_W{1'b0}};
                        uart_tx <= 1'b0;     // start bit
`ifndef SYNTHESIS
                        $write("%c", wb_dat_i[7:0]);
                        $fflush();
`endif
                    end
                end else begin
                    case (wb_adr_i[7:0])
                        8'h08:   wb_dat_o <= {29'h0, overrun, 1'b0, busy};
                        default: wb_dat_o <= 32'h0;
                    endcase
                end
            end

            // sticky overrun: set wins over clear
            if (drop_wr)       overrun <= 1'b1;
            else if (clr_ovr)  overrun <= 1'b0;
        end
    end

endmodule
