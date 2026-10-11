// ============================================================================
// Module: nna_top
// Description: Top-Level Integration of the Neural Network Accelerator
// Compatible with RV32IM CPU via standard synchronous MMIO / Wishbone / OBI
// ============================================================================

`timescale 1ns / 1ps
`include "soc_pkg.sv"

module nna_top (
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------------------------------
    // System Bus Interface (Slave)
    // ------------------------------------------------------------------------
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output wire [31:0] bus_rdata,
    output wire        bus_ready,

    // Interrupt Line to RISC-V CPU
    output wire        irq
);

    // Address Decode: 4 KB window at 0x4000_0000
    wire bus_sel = bus_req && (bus_addr[31:12] == 20'h40000);
    wire [11:0] offset_addr = bus_addr[11:0];

    // Single-cycle acknowledge
    assign bus_ready = bus_sel;

    // Internal Wires between Registers and Core
    wire        core_start;
    wire        core_copy_out_to_in;
    wire        core_irq_en;
    wire        core_soft_rst;
    wire [15:0] core_k_dim;
    wire [15:0] core_m_dim;
    wire [1:0]  core_act_type;
    wire [15:0] core_scale_mult;
    wire [4:0]  core_scale_shift;

    wire        core_busy;
    wire        core_done;
    wire        core_err;
    wire [31:0] core_cycle_count;
    wire        irq_pulse;

    wire [4:0]  core_in_raddr;
    wire [31:0] core_in_rdata;

    wire [5:0]  core_bias_raddr;
    wire [31:0] core_bias_rdata;

    wire [7:0]  core_weight_raddr;
    wire [31:0] core_weight_rdata;

    wire        core_out_we;
    wire [4:0]  core_out_waddr;
    wire [31:0] core_out_wdata;
    wire [3:0]  core_out_wstrb;

    wire        core_copy_step;
    wire [4:0]  core_copy_addr;

    // Register File & Buffers
    nna_regs u_regs (
        .clk(clk),
        .rst_n(rst_n),

        // Host Bus
        .bus_req(bus_sel),
        .bus_we(bus_we),
        .bus_addr(offset_addr),
        .bus_wdata(bus_wdata),
        .bus_wstrb(bus_wstrb),
        .bus_rdata(bus_rdata),

        // Core Control & Config
        .core_start(core_start),
        .core_copy_out_to_in(core_copy_out_to_in),
        .core_irq_en(core_irq_en),
        .core_soft_rst(core_soft_rst),
        .core_k_dim(core_k_dim),
        .core_m_dim(core_m_dim),
        .core_act_type(core_act_type),
        .core_scale_mult(core_scale_mult),
        .core_scale_shift(core_scale_shift),

        // Core Status Feedback
        .core_busy(core_busy),
        .core_done(core_done),
        .core_err(core_err),
        .core_cycle_count(core_cycle_count),

        // Core Datapath Scratchpad Access
        .core_in_raddr(core_in_raddr),
        .core_in_rdata(core_in_rdata),
        .core_bias_raddr(core_bias_raddr),
        .core_bias_rdata(core_bias_rdata),
        .core_weight_raddr(core_weight_raddr),
        .core_weight_rdata(core_weight_rdata),

        .core_out_we(core_out_we),
        .core_out_waddr(core_out_waddr),
        .core_out_wdata(core_out_wdata),
        .core_out_wstrb(core_out_wstrb),

        .core_copy_step(core_copy_step),
        .core_copy_addr(core_copy_addr)
    );

    // Compute Core
    nna_core u_core (
        .clk(clk),
        .rst_n(rst_n),

        .core_start(core_start),
        .core_copy_out_to_in(core_copy_out_to_in),
        .core_irq_en(core_irq_en),
        .core_soft_rst(core_soft_rst),
        .core_k_dim(core_k_dim),
        .core_m_dim(core_m_dim),
        .core_act_type(core_act_type),
        .core_scale_mult(core_scale_mult),
        .core_scale_shift(core_scale_shift),

        .core_busy(core_busy),
        .core_done(core_done),
        .core_err(core_err),
        .core_cycle_count(core_cycle_count),
        .irq_pulse(irq_pulse),

        .core_in_raddr(core_in_raddr),
        .core_in_rdata(core_in_rdata),
        .core_bias_raddr(core_bias_raddr),
        .core_bias_rdata(core_bias_rdata),
        .core_weight_raddr(core_weight_raddr),
        .core_weight_rdata(core_weight_rdata),

        .core_out_we(core_out_we),
        .core_out_waddr(core_out_waddr),
        .core_out_wdata(core_out_wdata),
        .core_out_wstrb(core_out_wstrb),

        .core_copy_step(core_copy_step),
        .core_copy_addr(core_copy_addr)
    );

    assign irq = irq_pulse;

endmodule
