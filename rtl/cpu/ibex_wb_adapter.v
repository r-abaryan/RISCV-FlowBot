// ============================================================================
// Module: ibex_wb_adapter
// Description: Open Bus Interface (OBI) to Wishbone B4 Master Adapter
// Adapts lowRISC Ibex OBI bus interface to synchronous Wishbone B4 pipelined bus
// ============================================================================

`timescale 1ns / 1ps

module ibex_wb_adapter (
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------------------------------
    // lowRISC Ibex OBI Interface (Slave side of adapter)
    // ------------------------------------------------------------------------
    input  wire        obi_req,
    output reg         obi_gnt,
    output reg         obi_rvalid,
    input  wire [31:0] obi_addr,
    input  wire        obi_we,
    input  wire [3:0]  obi_be,
    input  wire [31:0] obi_wdata,
    output reg  [31:0] obi_rdata,
    output reg         obi_err,

    // ------------------------------------------------------------------------
    // Wishbone B4 Master Interface
    // ------------------------------------------------------------------------
    output reg  [31:0] wb_adr_o,
    output reg  [31:0] wb_dat_o,
    input  wire [31:0] wb_dat_i,
    output reg         wb_we_o,
    output reg  [3:0]  wb_sel_o,
    output reg         wb_stb_o,
    input  wire        wb_ack_i,
    output reg         wb_cyc_o
);

    reg pending_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_adr_o    <= 32'h0;
            wb_dat_o    <= 32'h0;
            wb_we_o     <= 1'b0;
            wb_sel_o    <= 4'h0;
            wb_stb_o    <= 1'b0;
            wb_cyc_o    <= 1'b0;
            obi_gnt     <= 1'b0;
            obi_rvalid  <= 1'b0;
            obi_rdata   <= 32'h0;
            obi_err     <= 1'b0;
            pending_req <= 1'b0;
        end else begin
            // Default pulse responses
            obi_gnt    <= 1'b0;
            obi_rvalid <= 1'b0;
            obi_err    <= 1'b0;

            if (!pending_req) begin
                if (obi_req) begin
                    wb_adr_o    <= obi_addr;
                    wb_dat_o    <= obi_wdata;
                    wb_we_o     <= obi_we;
                    wb_sel_o    <= obi_be;
                    wb_stb_o    <= 1'b1;
                    wb_cyc_o    <= 1'b1;
                    pending_req <= 1'b1;
                end else begin
                    wb_stb_o    <= 1'b0;
                    wb_cyc_o    <= 1'b0;
                end
            end else begin
                // Waiting for Wishbone ACK
                if (wb_ack_i) begin
                    wb_stb_o    <= 1'b0;
                    wb_cyc_o    <= 1'b0;
                    obi_gnt     <= 1'b1;
                    obi_rvalid  <= 1'b1;
                    obi_rdata   <= wb_dat_i;
                    pending_req <= 1'b0;
                end
            end
        end
    end

endmodule
