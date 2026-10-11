// ============================================================================
// Module: soc_timer
// Description: Wishbone B4 64-bit Real-Time System Timer and Comparator
// Base Address: 0x5000_0000
// ============================================================================

`timescale 1ns / 1ps

module soc_timer (
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

    output wire        timer_irq
);

    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg        timer_en;
    reg        timer_ie;

    assign timer_irq = timer_en && timer_ie && (mtime >= mtimecmp);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'h0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
            timer_en <= 1'b1;
            timer_ie <= 1'b0;
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;

            if (timer_en) begin
                mtime <= mtime + 64'd1;
            end

            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (wb_adr_i[7:0])
                        8'h00: mtime[31:0]       <= wb_dat_i;
                        8'h04: mtime[63:32]      <= wb_dat_i;
                        8'h08: mtimecmp[31:0]    <= wb_dat_i;
                        8'h0C: mtimecmp[63:32]   <= wb_dat_i;
                        8'h10: begin
                            timer_en <= wb_dat_i[0];
                            timer_ie <= wb_dat_i[1];
                        end
                        default: ;
                    endcase
                end else begin
                    case (wb_adr_i[7:0])
                        8'h00: wb_dat_o <= mtime[31:0];
                        8'h04: wb_dat_o <= mtime[63:32];
                        8'h08: wb_dat_o <= mtimecmp[31:0];
                        8'h0C: wb_dat_o <= mtimecmp[63:32];
                        8'h10: wb_dat_o <= {30'h0, timer_ie, timer_en};
                        8'h14: wb_dat_o <= {31'h0, (mtime >= mtimecmp)};
                        default: wb_dat_o <= 32'h0;
                    endcase
                end
            end
        end
    end

endmodule
