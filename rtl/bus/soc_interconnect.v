// ============================================================================
// Module: soc_interconnect
// Description: Wishbone B4 1-Master to 7-Slave Address Crossbar & Interconnect
// Decodes memory and peripheral regions according to the SoC memory map
// ============================================================================

`timescale 1ns / 1ps
`include "soc_pkg.sv"

module soc_interconnect (
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------------------------------
    // Master Port (from CPU)
    // ------------------------------------------------------------------------
    input  wire [31:0] m_adr_i,
    input  wire [31:0] m_dat_i,
    output reg  [31:0] m_dat_o,
    input  wire        m_we_i,
    input  wire [3:0]  m_sel_i,
    input  wire        m_stb_i,
    input  wire        m_cyc_i,
    output reg         m_ack_o,

    // ------------------------------------------------------------------------
    // Slave 0: Boot ROM (0x0000_0000 - 0x0000_1FFF)
    // ------------------------------------------------------------------------
    output wire [31:0] s0_adr_o,
    output wire [31:0] s0_dat_o,
    input  wire [31:0] s0_dat_i,
    output wire        s0_we_o,
    output wire [3:0]  s0_sel_o,
    output wire        s0_stb_o,
    output wire        s0_cyc_o,
    input  wire        s0_ack_i,

    // ------------------------------------------------------------------------
    // Slave 1: Main SRAM (0x2000_0000 - 0x2000_FFFF)
    // ------------------------------------------------------------------------
    output wire [31:0] s1_adr_o,
    output wire [31:0] s1_dat_o,
    input  wire [31:0] s1_dat_i,
    output wire        s1_we_o,
    output wire [3:0]  s1_sel_o,
    output wire        s1_stb_o,
    output wire        s1_cyc_o,
    input  wire        s1_ack_i,

    // ------------------------------------------------------------------------
    // Slave 2: rv_nna Accelerator (0x4000_0000 - 0x4000_0FFF)
    // ------------------------------------------------------------------------
    output wire        s2_req_o,
    output wire        s2_we_o,
    output wire [31:0] s2_addr_o,
    output wire [31:0] s2_wdata_o,
    output wire [3:0]  s2_wstrb_o,
    input  wire [31:0] s2_rdata_i,
    input  wire        s2_ready_i,

    // ------------------------------------------------------------------------
    // Slave 3: Timer & Watchdog (0x5000_0000 - 0x5000_00FF)
    // ------------------------------------------------------------------------
    output wire [31:0] s3_adr_o,
    output wire [31:0] s3_dat_o,
    input  wire [31:0] s3_dat_i,
    output wire        s3_we_o,
    output wire [3:0]  s3_sel_o,
    output wire        s3_stb_o,
    output wire        s3_cyc_o,
    input  wire        s3_ack_i,

    // ------------------------------------------------------------------------
    // Slave 4: UART Console (0x5000_0100 - 0x5000_01FF)
    // ------------------------------------------------------------------------
    output wire [31:0] s4_adr_o,
    output wire [31:0] s4_dat_o,
    input  wire [31:0] s4_dat_i,
    output wire        s4_we_o,
    output wire [3:0]  s4_sel_o,
    output wire        s4_stb_o,
    output wire        s4_cyc_o,
    input  wire        s4_ack_i,

    // ------------------------------------------------------------------------
    // Slave 5: Motor PWM (0x5000_0200 - 0x5000_02FF)
    // ------------------------------------------------------------------------
    output wire [31:0] s5_adr_o,
    output wire [31:0] s5_dat_o,
    input  wire [31:0] s5_dat_i,
    output wire        s5_we_o,
    output wire [3:0]  s5_sel_o,
    output wire        s5_stb_o,
    output wire        s5_cyc_o,
    input  wire        s5_ack_i,

    // ------------------------------------------------------------------------
    // Slave 6: Safety Filter (0x5000_0600 - 0x5000_06FF)
    // ------------------------------------------------------------------------
    output wire        s6_req_o,
    output wire        s6_we_o,
    output wire [31:0] s6_addr_o,
    output wire [31:0] s6_wdata_o,
    output wire [3:0]  s6_wstrb_o,
    input  wire [31:0] s6_rdata_i,
    input  wire        s6_ready_i
);

    // Address Decoding Logic
    wire is_rom    = (m_adr_i[31:28] == 4'h0);
    wire is_ram    = (m_adr_i[31:28] == 4'h2);
    wire is_nna    = (m_adr_i[31:28] == 4'h4);
    wire is_periph = (m_adr_i[31:24] == 8'h50);

    wire is_timer  = is_periph && (m_adr_i[23:8] == 16'h0000);
    wire is_uart   = is_periph && (m_adr_i[23:8] == 16'h0001);
    wire is_pwm    = is_periph && (m_adr_i[23:8] == 16'h0002);
    wire is_safety = is_periph && (m_adr_i[23:8] == 16'h0006);

    // Broadcast common bus signals
    assign s0_adr_o = m_adr_i;
    assign s0_dat_o = m_dat_i;
    assign s0_we_o  = m_we_i;
    assign s0_sel_o = m_sel_i;
    assign s0_cyc_o = m_cyc_i && is_rom;
    assign s0_stb_o = m_stb_i && is_rom;

    assign s1_adr_o = m_adr_i;
    assign s1_dat_o = m_dat_i;
    assign s1_we_o  = m_we_i;
    assign s1_sel_o = m_sel_i;
    assign s1_cyc_o = m_cyc_i && is_ram;
    assign s1_stb_o = m_stb_i && is_ram;

    // NNA bus hook
    assign s2_req_o   = m_cyc_i && m_stb_i && is_nna;
    assign s2_we_o    = m_we_i;
    assign s2_addr_o  = m_adr_i;
    assign s2_wdata_o = m_dat_i;
    assign s2_wstrb_o = m_sel_i;

    assign s3_adr_o = m_adr_i;
    assign s3_dat_o = m_dat_i;
    assign s3_we_o  = m_we_i;
    assign s3_sel_o = m_sel_i;
    assign s3_cyc_o = m_cyc_i && is_timer;
    assign s3_stb_o = m_stb_i && is_timer;

    assign s4_adr_o = m_adr_i;
    assign s4_dat_o = m_dat_i;
    assign s4_we_o  = m_we_i;
    assign s4_sel_o = m_sel_i;
    assign s4_cyc_o = m_cyc_i && is_uart;
    assign s4_stb_o = m_stb_i && is_uart;

    assign s5_adr_o = m_adr_i;
    assign s5_dat_o = m_dat_i;
    assign s5_we_o  = m_we_i;
    assign s5_sel_o = m_sel_i;
    assign s5_cyc_o = m_cyc_i && is_pwm;
    assign s5_stb_o = m_stb_i && is_pwm;

    // Safety filter bus hook
    assign s6_req_o   = m_cyc_i && m_stb_i && is_safety;
    assign s6_we_o    = m_we_i;
    assign s6_addr_o  = m_adr_i;
    assign s6_wdata_o = m_dat_i;
    assign s6_wstrb_o = m_sel_i;

    // Default error / invalid address handling
    reg err_ack;
    wire unmapped = m_cyc_i && m_stb_i && !(is_rom || is_ram || is_nna || is_timer || is_uart || is_pwm || is_safety);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_ack <= 1'b0;
        end else begin
            err_ack <= unmapped && !err_ack;
        end
    end

    // Master Response Multiplexer
    always @(*) begin
        if (is_rom) begin
            m_dat_o = s0_dat_i;
            m_ack_o = s0_ack_i;
        end else if (is_ram) begin
            m_dat_o = s1_dat_i;
            m_ack_o = s1_ack_i;
        end else if (is_nna) begin
            m_dat_o = s2_rdata_i;
            m_ack_o = s2_ready_i;
        end else if (is_timer) begin
            m_dat_o = s3_dat_i;
            m_ack_o = s3_ack_i;
        end else if (is_uart) begin
            m_dat_o = s4_dat_i;
            m_ack_o = s4_ack_i;
        end else if (is_pwm) begin
            m_dat_o = s5_dat_i;
            m_ack_o = s5_ack_i;
        end else if (is_safety) begin
            m_dat_o = s6_rdata_i;
            m_ack_o = s6_ready_i;
        end else begin
            m_dat_o = 32'hDEAD_BEEF;
            m_ack_o = err_ack;
        end
    end

endmodule
