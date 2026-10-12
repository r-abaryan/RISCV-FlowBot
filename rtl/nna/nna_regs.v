// ============================================================================
// Module: nna_regs
// Description: Memory-Mapped Registers and Scratchpad Buffers for rv_nna
// Dual-ported storage: Port A (CPU bus), Port B (Accelerator Datapath)
// ============================================================================

`timescale 1ns / 1ps
`include "soc_pkg.sv"

module nna_regs (
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------------------------------
    // Host Bus Interface (Port A)
    // ------------------------------------------------------------------------
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [11:0] bus_addr,       // 12-bit offset (4KB window)
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,

    // ------------------------------------------------------------------------
    // Control & Configuration Registers to Core
    // ------------------------------------------------------------------------
    output wire        core_start,
    output wire        core_copy_out_to_in,
    output wire        core_irq_en,
    output wire        core_soft_rst,
    output wire [15:0] core_k_dim,
    output wire [15:0] core_m_dim,
    output wire [1:0]  core_act_type,
    output wire [15:0] core_scale_mult,
    output wire [4:0]  core_scale_shift,

    // Status & Feedback from Core
    input  wire        core_busy,
    input  wire        core_done,
    input  wire        core_err,
    input  wire [31:0] core_cycle_count,

    // ------------------------------------------------------------------------
    // Accelerator Core Datapath Access (Port B)
    // ------------------------------------------------------------------------
    // Input Buffer Read
    input  wire [4:0]  core_in_raddr,     // 32 words
    output wire [31:0] core_in_rdata,

    // Bias Buffer Read
    input  wire [5:0]  core_bias_raddr,   // 64 words
    output wire [31:0] core_bias_rdata,

    // Weight Buffer Read
    input  wire [7:0]  core_weight_raddr, // 256 words
    output wire [31:0] core_weight_rdata,

    // Output Buffer Write from Core
    input  wire        core_out_we,
    input  wire [4:0]  core_out_waddr,    // 32 words
    input  wire [31:0] core_out_wdata,
    input  wire [3:0]  core_out_wstrb,

    // Hardware Auto-Copy: Output to Input Buffer
    input  wire        core_copy_step,
    input  wire [4:0]  core_copy_addr
);

    // ------------------------------------------------------------------------
    // Internal Memories
    // ------------------------------------------------------------------------
    reg [31:0] in_buf     [0:31];   // 32 words = 128 bytes
    reg [31:0] bias_buf   [0:63];   // 64 words = 256 bytes
    reg [31:0] weight_buf [0:255];  // 256 words = 1024 bytes
    reg [31:0] out_buf    [0:31];   // 32 words = 128 bytes

`ifndef SYNTHESIS
    integer init_idx;
    initial begin
        for (init_idx = 0; init_idx < 32; init_idx = init_idx + 1) in_buf[init_idx] = 32'h0;
        for (init_idx = 0; init_idx < 64; init_idx = init_idx + 1) bias_buf[init_idx] = 32'h0;
        for (init_idx = 0; init_idx < 256; init_idx = init_idx + 1) weight_buf[init_idx] = 32'h0;
        for (init_idx = 0; init_idx < 32; init_idx = init_idx + 1) out_buf[init_idx] = 32'h0;
    end
`endif

    // ------------------------------------------------------------------------
    // CSR Registers
    // ------------------------------------------------------------------------
    reg        reg_start_pulse;
    reg        reg_copy_out_to_in;
    reg        reg_irq_en;
    reg        reg_soft_rst;
    reg [15:0] reg_k_dim;
    reg [15:0] reg_m_dim;
    reg [1:0]  reg_act_type;
    reg [15:0] reg_scale_mult;
    reg [4:0]  reg_scale_shift;

    assign core_start          = reg_start_pulse;
    assign core_copy_out_to_in = reg_copy_out_to_in;
    assign core_irq_en         = reg_irq_en;
    assign core_soft_rst       = reg_soft_rst;
    assign core_k_dim          = reg_k_dim;
    assign core_m_dim          = reg_m_dim;
    assign core_act_type       = reg_act_type;
    assign core_scale_mult     = reg_scale_mult;
    assign core_scale_shift    = reg_scale_shift;

    // ------------------------------------------------------------------------
    // Region Address Decoding
    // ------------------------------------------------------------------------
    wire is_csr    = (bus_addr[11:8] == 4'h0);
    wire is_in_buf = (bus_addr[11:8] == 4'h1) && (bus_addr[7] == 1'b0); // 0x100 - 0x17F
    wire is_bias   = (bus_addr[11:8] == 4'h2);                         // 0x200 - 0x2FF
    wire is_weight = (bus_addr[11] == 1'b0) && (bus_addr[10] == 1'b1); // 0x400 - 0x7FF
    wire is_out    = (bus_addr[11:8] == 4'h8) && (bus_addr[7] == 1'b0); // 0x800 - 0x87F

    // ------------------------------------------------------------------------
    // Host Bus Synchronous Write & Register Handling
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_start_pulse    <= 1'b0;
            reg_copy_out_to_in <= 1'b0;
            reg_irq_en         <= 1'b0;
            reg_soft_rst       <= 1'b0;
            reg_k_dim          <= 16'd16;
            reg_m_dim          <= 16'd8;
            reg_act_type       <= `ACT_RELU;
            reg_scale_mult     <= 16'h8000; // Q16 = 0.5
            reg_scale_shift    <= 5'd16;
        end else begin
            // Self-clearing start pulse
            reg_start_pulse <= 1'b0;

            if (bus_req && bus_we) begin
                if (is_csr) begin
                    case (bus_addr[7:0])
                        8'h00: begin // CTRL
                            if (bus_wstrb[0]) begin
                                reg_start_pulse    <= bus_wdata[0];
                                reg_copy_out_to_in <= bus_wdata[1];
                                reg_irq_en         <= bus_wdata[2];
                                reg_soft_rst       <= bus_wdata[3];
                            end
                        end
                        8'h08: begin // CONFIG_DIM
                            if (bus_wstrb[0]) reg_k_dim[7:0]   <= bus_wdata[7:0];
                            if (bus_wstrb[1]) reg_k_dim[15:8]  <= bus_wdata[15:8];
                            if (bus_wstrb[2]) reg_m_dim[7:0]   <= bus_wdata[23:16];
                            if (bus_wstrb[3]) reg_m_dim[15:8]  <= bus_wdata[31:24];
                        end
                        8'h0C: begin // CONFIG_ACT
                            if (bus_wstrb[0]) reg_act_type     <= bus_wdata[1:0];
                        end
                        8'h10: begin // CONFIG_SCALE
                            if (bus_wstrb[0]) reg_scale_mult[7:0]  <= bus_wdata[7:0];
                            if (bus_wstrb[1]) reg_scale_mult[15:8] <= bus_wdata[15:8];
                        end
                        8'h14: begin // CONFIG_SHIFT
                            if (bus_wstrb[0]) reg_scale_shift      <= bus_wdata[4:0];
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Internal SRAM Scratchpad Memory Write Ports (Synchronous Clock, No Reset)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (bus_req && bus_we) begin
            if (is_in_buf) begin
                if (bus_wstrb[0]) in_buf[bus_addr[6:2]][7:0]   <= bus_wdata[7:0];
                if (bus_wstrb[1]) in_buf[bus_addr[6:2]][15:8]  <= bus_wdata[15:8];
                if (bus_wstrb[2]) in_buf[bus_addr[6:2]][23:16] <= bus_wdata[23:16];
                if (bus_wstrb[3]) in_buf[bus_addr[6:2]][31:24] <= bus_wdata[31:24];
            end else if (is_bias) begin
                if (bus_wstrb[0]) bias_buf[bus_addr[7:2]][7:0]   <= bus_wdata[7:0];
                if (bus_wstrb[1]) bias_buf[bus_addr[7:2]][15:8]  <= bus_wdata[15:8];
                if (bus_wstrb[2]) bias_buf[bus_addr[7:2]][23:16] <= bus_wdata[23:16];
                if (bus_wstrb[3]) bias_buf[bus_addr[7:2]][31:24] <= bus_wdata[31:24];
            end else if (is_weight) begin
                if (bus_wstrb[0]) weight_buf[bus_addr[9:2]][7:0]   <= bus_wdata[7:0];
                if (bus_wstrb[1]) weight_buf[bus_addr[9:2]][15:8]  <= bus_wdata[15:8];
                if (bus_wstrb[2]) weight_buf[bus_addr[9:2]][23:16] <= bus_wdata[23:16];
                if (bus_wstrb[3]) weight_buf[bus_addr[9:2]][31:24] <= bus_wdata[31:24];
            end
        end

        // Hardware Core Output Writeback (Port B Write to Output Buffer)
        if (core_out_we) begin
            if (core_out_wstrb[0]) out_buf[core_out_waddr][7:0]   <= core_out_wdata[7:0];
            if (core_out_wstrb[1]) out_buf[core_out_waddr][15:8]  <= core_out_wdata[15:8];
            if (core_out_wstrb[2]) out_buf[core_out_waddr][23:16] <= core_out_wdata[23:16];
            if (core_out_wstrb[3]) out_buf[core_out_waddr][31:24] <= core_out_wdata[31:24];
        end

        // Hardware Auto-Copy: Output to Input Buffer for multi-layer chaining
        if (core_copy_step) begin
            in_buf[core_copy_addr] <= out_buf[core_copy_addr];
        end
    end

    // ------------------------------------------------------------------------
    // Host Bus Read Multiplexing
    // ------------------------------------------------------------------------
    always @(*) begin
        if (is_csr) begin
            case (bus_addr[7:0])
                8'h00:   bus_rdata = {28'h0, reg_soft_rst, reg_irq_en, reg_copy_out_to_in, core_busy};
                8'h04:   bus_rdata = {29'h0, core_err, core_done, core_busy};
                8'h08:   bus_rdata = {reg_m_dim, reg_k_dim};
                8'h0C:   bus_rdata = {30'h0, reg_act_type};
                8'h10:   bus_rdata = {16'h0, reg_scale_mult};
                8'h14:   bus_rdata = {27'h0, reg_scale_shift};
                8'h18:   bus_rdata = core_cycle_count;
                default: bus_rdata = 32'h0;
            endcase
        end else if (is_in_buf) begin
            bus_rdata = in_buf[bus_addr[6:2]];
        end else if (is_bias) begin
            bus_rdata = bias_buf[bus_addr[7:2]];
        end else if (is_weight) begin
            bus_rdata = weight_buf[bus_addr[9:2]];
        end else if (is_out) begin
            bus_rdata = out_buf[bus_addr[6:2]];
        end else begin
            bus_rdata = 32'h0;
        end
    end

    // ------------------------------------------------------------------------
    // Port B Read Outputs to Core Datapath (Combinational / Distributed Read)
    // ------------------------------------------------------------------------
    assign core_in_rdata     = in_buf[core_in_raddr];
    assign core_bias_rdata   = bias_buf[core_bias_raddr];
    assign core_weight_rdata = weight_buf[core_weight_raddr];

endmodule
