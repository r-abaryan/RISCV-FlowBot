// ============================================================================
// Module: soc_uart
// Description: Wishbone B4 UART transmitter, 8N1, TX only (M8E)
// Base Address: 0x5000_0100
//
// Register map (word offsets are byte addresses, only adr[7:0] is decoded):
//   0x00 TXDATA  W : bits[7:0] = byte to send. Accepted only if the transmitter
//                    is idle; if busy the write is DROPPED (see OVERRUN).
//                R : last byte accepted (bits[7:0]), upper bits 0.
//   0x04 STATUS  R : bit0 TX_READY (1 = idle, a write will be accepted)
//                    bit1 OVERRUN  (sticky: a write was dropped while busy)
//                W : writing 1 to bit1 clears OVERRUN (write-1-to-clear).
//   0x08 TX_BUSY R : bit0 = 1 while a frame is in flight (= ~TX_READY).
//                    Legacy alias kept so existing firmware (which polls
//                    0x08 bit0 as "TX busy") works unchanged.
//   Other offsets read 0; writes ignored.
//
// Write-while-busy policy (deterministic): the byte is dropped, the frame in
// flight is not disturbed, OVERRUN is set, and the bus access is acked
// normally (no stall). Firmware must poll TX_READY / TX_BUSY before writing.
//
// Frame: idle high, start bit 0, 8 data bits LSB first, stop bit 1, no parity.
// Bit period = CLKS_PER_BIT clk cycles (default 217 = 25 MHz / 115200, which
// is 115207 baud, +0.006 percent error). TX_READY returns to 1 on the cycle
// after the stop bit has been held for a full bit period.
// Reset (async, active-low) aborts any frame: line goes high, busy clears.
// ============================================================================

`timescale 1ns / 1ps

module soc_uart #(
    parameter integer CLKS_PER_BIT = 217
) (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone B4 Slave Interface
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

    localparam integer DIV_W = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    reg [7:0]       tx_byte;     // last accepted byte (readback)
    reg [9:0]       shifter;     // {stop, data[7:0], start}, LSB goes out first
    reg [3:0]       bit_idx;     // 0..9 bit being sent
    reg [DIV_W-1:0] div_cnt;
    reg             busy;
    reg             overrun;

    wire wr_data = wb_cyc_i && wb_stb_i && !wb_ack_o && wb_we_i && (wb_adr_i[7:0] == 8'h00);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
            uart_tx  <= 1'b1;
            tx_byte  <= 8'h00;
            shifter  <= 10'h3FF;
            bit_idx  <= 4'd0;
            div_cnt  <= {DIV_W{1'b0}};
            busy     <= 1'b0;
            overrun  <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;

            // ---------------- transmit engine ----------------
            if (busy) begin
                if (div_cnt == CLKS_PER_BIT - 1) begin
                    div_cnt <= {DIV_W{1'b0}};
                    if (bit_idx == 4'd9) begin
                        busy <= 1'b0;          // stop bit fully elapsed
                    end else begin
                        bit_idx <= bit_idx + 4'd1;
                        uart_tx <= shifter[bit_idx + 4'd1];
                    end
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end

            // ---------------- bus ----------------
            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (wb_adr_i[7:0])
                        8'h00: begin
                            if (!busy) begin
                                tx_byte <= wb_dat_i[7:0];
                                shifter <= {1'b1, wb_dat_i[7:0], 1'b0};
                                bit_idx <= 4'd0;
                                div_cnt <= {DIV_W{1'b0}};
                                busy    <= 1'b1;
                                uart_tx <= 1'b0;   // start bit
`ifndef SYNTHESIS
                                // Simulation only: echo accepted bytes to stdout
                                $write("%c", wb_dat_i[7:0]);
                                $fflush();
`endif
                            end else begin
                                overrun <= 1'b1;   // dropped
                            end
                        end
                        8'h04: if (wb_dat_i[1]) overrun <= 1'b0;
                        default: ;
                    endcase
                end else begin
                    case (wb_adr_i[7:0])
                        8'h00: wb_dat_o <= {24'h0, tx_byte};
                        8'h04: wb_dat_o <= {30'h0, overrun, !busy};
                        8'h08: wb_dat_o <= {31'h0, busy};
                        default: wb_dat_o <= 32'h0;
                    endcase
                end
            end
        end
    end

endmodule
