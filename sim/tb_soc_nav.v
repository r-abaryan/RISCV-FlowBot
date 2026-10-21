// ============================================================================
// Testbench: tb_soc_nav
// Description: Full SoC Simulation executing Autonomous Navigation Policy
// Runs multi-layer INT8 MLP policy (16->8 ReLU, 8->2 Clip) on rv_nna,
// exercises hardware safety interlock watchdog, and verifies motor outputs.
// Hardened with watchdog timer, strict assertions, and fatal exit codes.
// ============================================================================

`timescale 1ns / 1ps

`ifndef ROM_INIT_FILE
    `define ROM_INIT_FILE "../sw/firmware/robot_nav.hex"
`endif

// UART divider for simulation speed only (RTL default 217 is exercised by tb_ulx3s_top).
`ifndef UART_DIV
`define UART_DIV 16
`endif
// Test-only overrides (defaults unchanged): cycle budget and $time watchdog.
// Used by make test_nav_div217 (M11b) to run at board baud (UART_DIV=217).
`ifndef NAV_MAX_CYCLES
`define NAV_MAX_CYCLES 1000000
`endif
`ifndef NAV_TIME_LIMIT_NS
`define NAV_TIME_LIMIT_NS 30000000
`endif
// Extra cycles to keep simulating after the CAFEBABE token (default 0 = old
// behaviour). Lets the firmware's post-pass banner and halt loop be observed.
`ifndef NAV_POST_PASS_CYCLES
`define NAV_POST_PASS_CYCLES 0
`endif
module tb_soc_nav;

    reg clk;
    reg rst_n;
    reg ext_estop_n;

    wire uart_tx;
    wire pwm_left_out;
    wire pwm_right_out;
    wire [15:0] pwm_left_cmd;
    wire [15:0] pwm_right_cmd;
    wire actuator_disarm;

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // Testbench Watchdog Timeout (30ms simulation time)
    initial begin
        #(`NAV_TIME_LIMIT_NS);
        $fatal(1, "[TB FATAL] Navigation simulation watchdog timeout reached (%0d ns)!", `NAV_TIME_LIMIT_NS);
    end

    // DUT Instance with configurable ROM
    soc_top #(
        .ROM_INIT_FILE(`ROM_INIT_FILE),
        .UART_CLKS_PER_BIT(`UART_DIV)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .ext_estop_n     (ext_estop_n),
        .uart_tx         (uart_tx),
        .pwm_left_out    (pwm_left_out),
        .pwm_right_out   (pwm_right_out),
        .pwm_left_cmd    (pwm_left_cmd),
        .pwm_right_cmd   (pwm_right_cmd),
        .actuator_disarm (actuator_disarm)
    );

    // CPU trap detection
    always @(posedge clk) begin
        if (rst_n && dut.u_cpu.trap) begin
            $fatal(1, "[TB FATAL] CPU TRAPPED! pc=0x%08x, mem_addr=0x%08x, mem_wdata=0x%08x",
                   dut.u_cpu.picorv32_core.reg_pc, dut.u_cpu.mem_addr, dut.u_cpu.mem_wdata);
        end
    end

    // ========================================================================
    // Hardware Assertions & Monitors
    // ========================================================================
    integer nna_done_count = 0;
    integer pwm_write_count = 0;
    reg [15:0] pwm_left_history [0:7];
    reg [15:0] pwm_right_history [0:7];
    reg [7:0]  nna_v_history [0:7];
    reg [7:0]  nna_w_history [0:7];
    integer nna_inference_count = 0;
    reg nna_done_prev = 0;

    // Monitor rv_nna accelerator done pulses (edge-triggered)
    always @(posedge clk) begin
        if (!rst_n) begin
            nna_done_prev <= 1'b0;
        end else begin
            nna_done_prev <= dut.u_nna.core_done;
            if (dut.u_nna.core_done && !nna_done_prev) begin
                nna_done_count <= nna_done_count + 1;
                // When Layer 2 completes (M=2), capture raw policy outputs from out_buf
                if (dut.u_nna.u_regs.reg_m_dim == 16'd2) begin
                    nna_v_history[nna_inference_count] <= dut.u_nna.u_regs.out_buf[0][7:0];
                    nna_w_history[nna_inference_count] <= dut.u_nna.u_regs.out_buf[0][15:8];
                    $display("[TB ASSERT] NNA completed Layer 2 inference #%0d: v_raw=0x%02x, w_raw=0x%02x at time %0t ns",
                             nna_inference_count + 1,
                             dut.u_nna.u_regs.out_buf[0][7:0],
                             dut.u_nna.u_regs.out_buf[0][15:8],
                             $time);
                    nna_inference_count <= nna_inference_count + 1;
                end
            end
        end
    end

    // Monitor PWM register writes
    always @(posedge clk) begin
        if (rst_n && dut.u_pwm.wb_cyc_i && dut.u_pwm.wb_stb_i && dut.u_pwm.wb_we_i &&
            (dut.u_pwm.wb_adr_i[7:0] == 8'h08) && dut.u_pwm.wb_ack_o) begin
            // Captured write to DUTY_RIGHT (completes left/right pair write)
            pwm_left_history[pwm_write_count]  <= dut.u_pwm.reg_left_duty;
            pwm_right_history[pwm_write_count] <= dut.u_pwm.wb_dat_i[15:0];
            $display("[TB ASSERT] PWM Duty Cycle Written #%0d: Left=0x%04x (%0d), Right=0x%04x (%0d) at time %0t ns",
                     pwm_write_count + 1,
                     dut.u_pwm.reg_left_duty, dut.u_pwm.reg_left_duty,
                     dut.u_pwm.wb_dat_i[15:0], dut.u_pwm.wb_dat_i[15:0],
                     $time);
            pwm_write_count <= pwm_write_count + 1;
        end
    end

    // Safety watchdog trip check (ensure watchdog never trips spuriously during valid run)
    always @(posedge clk) begin
        if (rst_n && dut.u_safety.flag_wdt_expired) begin
            $fatal(1, "[TB FATAL] Safety watchdog tripped unexpectedly at time %0t ns! Disarm=%0b",
                   $time, actuator_disarm);
        end
    end

    integer cycle_count;
    reg test_passed;

    initial begin
        clk = 0;
        rst_n = 0;
        ext_estop_n = 1; // E-Stop normal (armed)
        cycle_count = 0;
        test_passed = 0;

        $display("\n=======================================================");
        $display("   STARTING RISC-V ROBOT NAVIGATION SOC SIMULATION     ");
        $display("   ROM: %s", `ROM_INIT_FILE);
        $display("=======================================================");

        // Hold reset for 5 cycles
        #100;
        rst_n = 1;
        $display("[TB] System reset deasserted at time %0t ns", $time);

        // Simulation loop with NAV_MAX_CYCLES timeout (default 1,000,000)
        while (cycle_count < `NAV_MAX_CYCLES && !test_passed) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            // Check if CPU wrote 0xCAFEBABE to RAM at word address 0x3FFC (ram_mem[4095])
            if (dut.u_ram.ram_mem[4095] == 32'hCAFEBABE) begin
                test_passed = 1;
            end
        end

        // Optional post-pass observation window (test-only, default 0)
        if (test_passed) repeat (`NAV_POST_PASS_CYCLES) @(posedge clk);

        // Wait a few cycles for final UART flush
        #500;

        if (test_passed) begin
            $display("\n=======================================================");
            $display("   VERIFYING MEANINGFUL HARDWARE ASSERTIONS           ");
            $display("=======================================================");

            // 1. Assert NNA accelerator execution count (3 cycles x 2 layers = 6 executions)
            if (nna_done_count != 6) begin
                $fatal(1, "[TB FATAL] Expected 6 NNA executions, but counted %0d", nna_done_count);
            end
            $display(" [ASSERT 1 PASS] NNA accelerator executed exactly 6 layer evaluations (3 x 2-layer passes)");

            // 2. Assert NNA policy inference outputs across the 3 navigation cycles
            // Cycle 1: Open corridor (goldens from sw/model/reference_model.py with RL seed 1 weights)
            if (nna_v_history[0] != 8'h17 || nna_w_history[0] != 8'h07) begin
                $fatal(1, "[TB FATAL] Cycle 1 raw policy output mismatch: got v=0x%02x, w=0x%02x (expected v=0x17, w=0x07, RL seed 1 weights)",
                       nna_v_history[0], nna_w_history[0]);
            end
            $display(" [ASSERT 2 PASS] Cycle 1 raw policy output verified: v=0x17 (+23), w=0x07 (+7)");

            // Cycle 2: Obstacle on left
            if (nna_v_history[1] != 8'he8 || nna_w_history[1] != 8'h7f) begin
                $fatal(1, "[TB FATAL] Cycle 2 raw policy output mismatch: got v=0x%02x, w=0x%02x (expected v=0xE8, w=0x7F, RL seed 1 weights)",
                       nna_v_history[1], nna_w_history[1]);
            end
            $display(" [ASSERT 3 PASS] Cycle 2 raw policy output verified: v=0xE8 (-24), w=0x7F (+127)");

            // Cycle 3: Front obstacle
            if (nna_v_history[2] != 8'h17 || nna_w_history[2] != 8'h41) begin
                $fatal(1, "[TB FATAL] Cycle 3 raw policy output mismatch: got v=0x%02x, w=0x%02x (expected v=0x17, w=0x41, RL seed 1 weights)",
                       nna_v_history[2], nna_w_history[2]);
            end
            $display(" [ASSERT 4 PASS] Cycle 3 raw policy output verified: v=0x17 (+23), w=0x41 (+65)");

            // 3. Assert Motor PWM commands and Safety Interlock
            // History index 0 is initial zero PWM. Index 1, 2, 3 correspond to Cycle 1, 2, 3.
            // M7B: expected values include the firmware safety filter (clamp 64, slew 8/tick,
            // proximity). Cycle1: v 23->8 (slew), w=7. Cycle2: v -24->0 (slew from 8), w 127->64->15.
            // Cycle3: wall at ~11 cm -> v=0, w 65->64->23. Reference: sw/test/test_nav_expected.py
            // Cycle 1 PWM: forward drive with small right bias (w=+7)
            if (pwm_left_history[1] != 16'h01f7 || pwm_right_history[1] != 16'h022e) begin
                $fatal(1, "[TB FATAL] Cycle 1 PWM mismatch: got L=0x%04x, R=0x%04x (expected 0x01f7, 0x022e)",
                       pwm_left_history[1], pwm_right_history[1]);
            end
            $display(" [ASSERT 5 PASS] Cycle 1 PWM balanced forward drive: L=0x%04x, R=0x%04x",
                     pwm_left_history[1], pwm_right_history[1]);

            // Cycle 2 PWM: differential steer right (Right > Left, slew-limited)
            if (pwm_left_history[2] != 16'h01b9 || pwm_right_history[2] != 16'h022e) begin
                $fatal(1, "[TB FATAL] Cycle 2 PWM mismatch: got L=0x%04x, R=0x%04x (expected 0x01b9, 0x022e)",
                       pwm_left_history[2], pwm_right_history[2]);
            end
            $display(" [ASSERT 6 PASS] Cycle 2 PWM slew-limited right turn: L=0x01b9, R=0x%04x", pwm_right_history[2]);

            // Cycle 3 Safety Override: front wall obstacle triggered firmware clamp
            // v_cmd clamped to 0, differential turn in place
            if (pwm_left_history[3] != 16'h019a || pwm_right_history[3] != 16'h024d) begin
                $fatal(1, "[TB FATAL] Cycle 3 PWM mismatch: got L=0x%04x, R=0x%04x (expected 0x019a, 0x024d)",
                       pwm_left_history[3], pwm_right_history[3]);
            end
            // Stronger check: with raw v=+23, w=+65 and NO clamp the duties would be
            // L=((23-65+128)*1000)>>8=0x014f, R=((23+65+128)*1000)>>8=0x034b. Require
            // the clamp took effect (v=0 => L+R = 2*128*1000/256 within rounding of 1000).
            if (pwm_left_history[3] == 16'h014f || pwm_right_history[3] == 16'h034b) begin
                $fatal(1, "[TB FATAL] Cycle 3 PWM equals the UNCLAMPED value: safety override did not act");
            end
            if (pwm_left_history[3] + pwm_right_history[3] < 16'd998 || pwm_left_history[3] + pwm_right_history[3] > 16'd1000) begin
                $fatal(1, "[TB FATAL] Cycle 3 L+R=%0d, not consistent with v_safe=0", pwm_left_history[3] + pwm_right_history[3]);
            end
            $display(" [ASSERT 7 PASS] Cycle 3 Safety Override verified: v_cmd clamped to 0, PWM L=0x019a, R=0x024d");

            // Final safety state assertions
            if (actuator_disarm != 1'b0) begin
                $fatal(1, "[TB FATAL] Actuator disarmed unexpectedly! disarm=%0b", actuator_disarm);
            end
            $display(" [ASSERT 8 PASS] Safety interlock armed, watchdog refreshed, no trip (actuator_disarm=0)");

            $display("\n=======================================================");
            $display(" SUCCESS: All 8 Navigation SoC Hardware Assertions PASSED!");
            $display(" Total Simulation Cycles: %0d", cycle_count);
            $display(" Final PWM Left Cmd:  %0d (0x%04x)", pwm_left_cmd, pwm_left_cmd);
            $display(" Final PWM Right Cmd: %0d (0x%04x)", pwm_right_cmd, pwm_right_cmd);
            $display(" Actuator Disarm:     %0b (0 = Normal/Armed)", actuator_disarm);
            $display("=======================================================\n");
            $finish(0);
        end else begin
            $display("\n=======================================================");
            $display(" TIMEOUT / FAILURE: Navigation firmware did not complete!");
            $display(" Cycles elapsed: %0d, RAM[4095]: 0x%08x, Trap: %0b", 
                     cycle_count, dut.u_ram.ram_mem[4095], dut.u_cpu.trap);
            $display("=======================================================");
            $fatal(1, "[TB FATAL] Navigation policy test failed due to timeout!");
        end
    end

endmodule
