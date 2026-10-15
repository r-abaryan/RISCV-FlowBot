// ============================================================================
// Module: soc_top
// Description: Complete RISC-V Robot Control System-on-Chip
// Integrates RV32IM CPU, rv_nna INT8 accelerator, Deterministic Safety Interlock,
// Interconnect, SRAM, Boot ROM, Timer, UART, and Motor PWM
// ============================================================================

`timescale 1ns / 1ps
`include "soc_pkg.sv"

module soc_top #(
    parameter ROM_INIT_FILE = "",
    parameter integer UART_CLKS_PER_BIT = 217  // 25 MHz / 115200
) (
    input  wire        clk,
    input  wire        rst_n,

    // External Physical E-Stop (Active-Low)
    input  wire        ext_estop_n,

    // External Diagnostic UART
    output wire        uart_tx,

    // Motor PWM Outputs and Command Monitors
    output wire        pwm_left_out,
    output wire        pwm_right_out,
    output wire [15:0] pwm_left_cmd,
    output wire [15:0] pwm_right_cmd,

    // Hardware Safety Status
    output wire        actuator_disarm
);

    // ------------------------------------------------------------------------
    // CPU Wishbone Bus Signals
    // ------------------------------------------------------------------------
    wire [31:0] cpu_wb_adr;
    wire [31:0] cpu_wb_dat_o;
    wire [31:0] cpu_wb_dat_i;
    wire        cpu_wb_we;
    wire [3:0]  cpu_wb_sel;
    wire        cpu_wb_stb;
    wire        cpu_wb_cyc;
    wire        cpu_wb_ack;

    // CPU Interrupts
    wire        timer_irq;
    wire        nna_irq;
    wire [31:0] cpu_irq = {30'h0, nna_irq, timer_irq};

    // ------------------------------------------------------------------------
    // RV32IM Processor Core Instance (PicoRV32 RV32IM Wishbone)
    // ------------------------------------------------------------------------
    picorv32_wb #(
        .ENABLE_COUNTERS     (1),
        .ENABLE_COUNTERS64   (1),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .TWO_STAGE_SHIFT     (1),
        .BARREL_SHIFTER      (1),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .COMPRESSED_ISA      (0),
        .CATCH_MISALIGN      (1),
        .CATCH_ILLINSN       (1),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (1),
        .ENABLE_FAST_MUL     (1),
        .ENABLE_DIV          (1),
        .ENABLE_IRQ          (1),
        .ENABLE_IRQ_QREGS    (1),
        .ENABLE_IRQ_TIMER    (0),
        .ENABLE_TRACE        (0),
        .REGS_INIT_ZERO      (1),
        .MASKED_IRQ          (32'h0000_0000),
        .LATCHED_IRQ         (32'hFFFF_FFFF),
        .PROGADDR_RESET      (32'h0000_0000),
        .PROGADDR_IRQ        (32'h0000_0010),
        .STACKADDR           (32'h2000_F000)
    ) u_cpu (
        .wb_clk_i    (clk),
        .wb_rst_i    (!rst_n),
        .trap        (),

        // Wishbone Master Interface
        .wbm_adr_o   (cpu_wb_adr),
        .wbm_dat_o   (cpu_wb_dat_o),
        .wbm_dat_i   (cpu_wb_dat_i),
        .wbm_we_o    (cpu_wb_we),
        .wbm_sel_o   (cpu_wb_sel),
        .wbm_stb_o   (cpu_wb_stb),
        .wbm_ack_i   (cpu_wb_ack),
        .wbm_cyc_o   (cpu_wb_cyc),

        // PCPI unused
        .pcpi_valid  (),
        .pcpi_insn   (),
        .pcpi_rs1    (),
        .pcpi_rs2    (),
        .pcpi_wr     (1'b0),
        .pcpi_rd     (32'h0),
        .pcpi_wait   (1'b0),
        .pcpi_ready  (1'b0),

        // Interrupts
        .irq         (cpu_irq),
        .eoi         (),

        .trace_valid (),
        .trace_data  ()
    );

    // ------------------------------------------------------------------------
    // Slave Interconnect Buses
    // ------------------------------------------------------------------------
    // Slave 0: ROM
    wire [31:0] rom_adr;
    wire [31:0] rom_dat_w;
    wire [31:0] rom_dat_r;
    wire        rom_we;
    wire [3:0]  rom_sel;
    wire        rom_stb;
    wire        rom_cyc;
    wire        rom_ack;

    // Slave 1: RAM
    wire [31:0] ram_adr;
    wire [31:0] ram_dat_w;
    wire [31:0] ram_dat_r;
    wire        ram_we;
    wire [3:0]  ram_sel;
    wire        ram_stb;
    wire        ram_cyc;
    wire        ram_ack;

    // Slave 2: NNA
    wire        nna_req;
    wire        nna_we;
    wire [31:0] nna_addr;
    wire [31:0] nna_wdata;
    wire [3:0]  nna_wstrb;
    wire [31:0] nna_rdata;
    wire        nna_ready;

    // Slave 3: Timer
    wire [31:0] timer_adr;
    wire [31:0] timer_dat_w;
    wire [31:0] timer_dat_r;
    wire        timer_we;
    wire [3:0]  timer_sel;
    wire        timer_stb;
    wire        timer_cyc;
    wire        timer_ack;

    // Slave 4: UART
    wire [31:0] uart_adr;
    wire [31:0] uart_dat_w;
    wire [31:0] uart_dat_r;
    wire        uart_we;
    wire [3:0]  uart_sel;
    wire        uart_stb;
    wire        uart_cyc;
    wire        uart_ack;

    // Slave 5: PWM
    wire [31:0] pwm_adr;
    wire [31:0] pwm_dat_w;
    wire [31:0] pwm_dat_r;
    wire        pwm_we;
    wire [3:0]  pwm_sel;
    wire        pwm_stb;
    wire        pwm_cyc;
    wire        pwm_ack;

    // Slave 6: Safety Filter
    wire        safety_req;
    wire        safety_we;
    wire [31:0] safety_addr;
    wire [31:0] safety_wdata;
    wire [3:0]  safety_wstrb;
    wire [31:0] safety_rdata;
    wire        safety_ready;

    // ------------------------------------------------------------------------
    // Interconnect Crossbar
    // ------------------------------------------------------------------------
    soc_interconnect u_interconnect (
        .clk        (clk),
        .rst_n      (rst_n),

        // Master
        .m_adr_i    (cpu_wb_adr),
        .m_dat_i    (cpu_wb_dat_o),
        .m_dat_o    (cpu_wb_dat_i),
        .m_we_i     (cpu_wb_we),
        .m_sel_i    (cpu_wb_sel),
        .m_stb_i    (cpu_wb_stb),
        .m_cyc_i    (cpu_wb_cyc),
        .m_ack_o    (cpu_wb_ack),

        // Slave 0: ROM
        .s0_adr_o   (rom_adr),
        .s0_dat_o   (rom_dat_w),
        .s0_dat_i   (rom_dat_r),
        .s0_we_o    (rom_we),
        .s0_sel_o   (rom_sel),
        .s0_stb_o   (rom_stb),
        .s0_cyc_o   (rom_cyc),
        .s0_ack_i   (rom_ack),

        // Slave 1: RAM
        .s1_adr_o   (ram_adr),
        .s1_dat_o   (ram_dat_w),
        .s1_dat_i   (ram_dat_r),
        .s1_we_o    (ram_we),
        .s1_sel_o   (ram_sel),
        .s1_stb_o   (ram_stb),
        .s1_cyc_o   (ram_cyc),
        .s1_ack_i   (ram_ack),

        // Slave 2: NNA
        .s2_req_o   (nna_req),
        .s2_we_o    (nna_we),
        .s2_addr_o  (nna_addr),
        .s2_wdata_o (nna_wdata),
        .s2_wstrb_o (nna_wstrb),
        .s2_rdata_i (nna_rdata),
        .s2_ready_i (nna_ready),

        // Slave 3: Timer
        .s3_adr_o   (timer_adr),
        .s3_dat_o   (timer_dat_w),
        .s3_dat_i   (timer_dat_r),
        .s3_we_o    (timer_we),
        .s3_sel_o   (timer_sel),
        .s3_stb_o   (timer_stb),
        .s3_cyc_o   (timer_cyc),
        .s3_ack_i   (timer_ack),

        // Slave 4: UART
        .s4_adr_o   (uart_adr),
        .s4_dat_o   (uart_dat_w),
        .s4_dat_i   (uart_dat_r),
        .s4_we_o    (uart_we),
        .s4_sel_o   (uart_sel),
        .s4_stb_o   (uart_stb),
        .s4_cyc_o   (uart_cyc),
        .s4_ack_i   (uart_ack),

        // Slave 5: PWM
        .s5_adr_o   (pwm_adr),
        .s5_dat_o   (pwm_dat_w),
        .s5_dat_i   (pwm_dat_r),
        .s5_we_o    (pwm_we),
        .s5_sel_o   (pwm_sel),
        .s5_stb_o   (pwm_stb),
        .s5_cyc_o   (pwm_cyc),
        .s5_ack_i   (pwm_ack),

        // Slave 6: Safety Filter
        .s6_req_o   (safety_req),
        .s6_we_o    (safety_we),
        .s6_addr_o  (safety_addr),
        .s6_wdata_o (safety_wdata),
        .s6_wstrb_o (safety_wstrb),
        .s6_rdata_i (safety_rdata),
        .s6_ready_i (safety_ready)
    );

    // ------------------------------------------------------------------------
    // Peripheral & Memory Instances
    // ------------------------------------------------------------------------
    soc_rom #(
        .MEM_SIZE_WORDS (2048),
        .INIT_FILE      (ROM_INIT_FILE)
    ) u_rom (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_adr_i (rom_adr),
        .wb_dat_i (rom_dat_w),
        .wb_dat_o (rom_dat_r),
        .wb_we_i  (rom_we),
        .wb_sel_i (rom_sel),
        .wb_stb_i (rom_stb),
        .wb_cyc_i (rom_cyc),
        .wb_ack_o (rom_ack)
    );

    soc_ram #(
        .MEM_SIZE_WORDS (16384)
    ) u_ram (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_adr_i (ram_adr),
        .wb_dat_i (ram_dat_w),
        .wb_dat_o (ram_dat_r),
        .wb_we_i  (ram_we),
        .wb_sel_i (ram_sel),
        .wb_stb_i (ram_stb),
        .wb_cyc_i (ram_cyc),
        .wb_ack_o (ram_ack)
    );

    nna_top u_nna (
        .clk        (clk),
        .rst_n      (rst_n),
        .bus_req    (nna_req),
        .bus_we     (nna_we),
        .bus_addr   (nna_addr),
        .bus_wdata  (nna_wdata),
        .bus_wstrb  (nna_wstrb),
        .bus_rdata  (nna_rdata),
        .bus_ready  (nna_ready),
        .irq        (nna_irq)
    );

    soc_timer u_timer (
        .clk       (clk),
        .rst_n     (rst_n),
        .wb_adr_i  (timer_adr),
        .wb_dat_i  (timer_dat_w),
        .wb_dat_o  (timer_dat_r),
        .wb_we_i   (timer_we),
        .wb_sel_i  (timer_sel),
        .wb_stb_i  (timer_stb),
        .wb_cyc_i  (timer_cyc),
        .wb_ack_o  (timer_ack),
        .timer_irq (timer_irq)
    );

    soc_uart #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_uart (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_adr_i (uart_adr),
        .wb_dat_i (uart_dat_w),
        .wb_dat_o (uart_dat_r),
        .wb_we_i  (uart_we),
        .wb_sel_i (uart_sel),
        .wb_stb_i (uart_stb),
        .wb_cyc_i (uart_cyc),
        .wb_ack_o (uart_ack),
        .uart_tx  (uart_tx)
    );

    wire estop_tripped = !ext_estop_n;

    safety_filter u_safety (
        .clk              (clk),
        .rst_n            (rst_n),
        .pin_estop_button (estop_tripped),
        .bus_req          (safety_req),
        .bus_we           (safety_we),
        .bus_addr         (safety_addr),
        .bus_wdata        (safety_wdata),
        .bus_wstrb        (safety_wstrb),
        .bus_rdata        (safety_rdata),
        .bus_ready        (safety_ready),
        .actuator_disarm  (actuator_disarm)
    );

    soc_pwm u_pwm (
        .clk           (clk),
        .rst_n         (rst_n),
        .wb_adr_i      (pwm_adr),
        .wb_dat_i      (pwm_dat_w),
        .wb_dat_o      (pwm_dat_r),
        .wb_we_i       (pwm_we),
        .wb_sel_i      (pwm_sel),
        .wb_stb_i      (pwm_stb),
        .wb_cyc_i      (pwm_cyc),
        .wb_ack_o      (pwm_ack),
        .disarm_in     (actuator_disarm),
        .pwm_left_cmd  (pwm_left_cmd),
        .pwm_right_cmd (pwm_right_cmd),
        .pwm_left_out  (pwm_left_out),
        .pwm_right_out (pwm_right_out)
    );

endmodule
