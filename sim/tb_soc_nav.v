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

    // Clock generation: 50 MHz SIM clock (20 ns period).
    // M11b harness fix 4: the target board runs at 25 MHz. The WDT budget, UART
    // divider and PWM period are all counted in clock cycles, so results here are
    // CYCLE-EQUIVALENT to the board; nominal board time = cycles / 25 MHz (board
    // clock frequency itself not yet verified, B1). Every ns value printed by this
    // TB (incl. NAV_TIME_LIMIT_NS) is SIM time = half the nominal board time.
    // UART_DIV=217 is 115200 baud only at 25 MHz (230400 baud in sim time).
    always #10 clk = ~clk;

    // Testbench time limit, in SIM ns (default 30 ms sim time)
    initial begin
        #(`NAV_TIME_LIMIT_NS);
        // M11b M1 closure: state dump so a time-limit failure is diagnosable.
        $display("[TB] TIME LIMIT: cycles=%0d test_passed=%0b RAM[4095]=0x%08x trap=%0b disarm=%0b wdt_expired=%0b pwm_cmd L=%0d R=%0d",
                 cycle_count, test_passed, dut.u_ram.ram_mem[4095], dut.u_cpu.trap, actuator_disarm,
                 dut.u_safety.flag_wdt_expired, pwm_left_cmd, pwm_right_cmd);
        $fatal(1, "[TB FATAL] Navigation simulation watchdog timeout reached (%0d sim ns)!", `NAV_TIME_LIMIT_NS);
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
                    $display("[TB ASSERT] NNA completed Layer 2 inference #%0d: v_raw=0x%02x, w_raw=0x%02x at sim time %0t (cycle %0d)",
                             nna_inference_count + 1,
                             dut.u_nna.u_regs.out_buf[0][7:0],
                             dut.u_nna.u_regs.out_buf[0][15:8],
                             $time, cycle_count);
                    nna_inference_count <= nna_inference_count + 1;
                end
            end
        end
    end

    // Monitor motor COMMIT writes (M2 contract v3, offset 0x0C). On the acking edge
    // the staged CMD_L/CMD_R are the values being committed. History index 0 is the
    // zero COMMIT of the arm sequence (issued while disarmed, so ignored by RTL).
    // One cycle after each armed COMMIT, ACTIVE must equal the committed pair.
    reg        commit_chk = 1'b0;
    reg [15:0] commit_l_q, commit_r_q;
    always @(posedge clk) begin
        commit_chk <= 1'b0;
        if (rst_n && dut.u_pwm.wb_cyc_i && dut.u_pwm.wb_stb_i && dut.u_pwm.wb_we_i &&
            (dut.u_pwm.wb_adr_i[7:0] == 8'h0C) && dut.u_pwm.wb_ack_o) begin
            pwm_left_history[pwm_write_count]  <= dut.u_pwm.cmd_l;
            pwm_right_history[pwm_write_count] <= dut.u_pwm.cmd_r;
            commit_l_q <= dut.u_pwm.cmd_l;
            commit_r_q <= dut.u_pwm.cmd_r;
            commit_chk <= dut.u_pwm.armed;
            $display("[TB ASSERT] Motor COMMIT #%0d: CMD_L=0x%04x (%0d), CMD_R=0x%04x (%0d) armed=%0b at sim time %0t (cycle %0d)",
                     pwm_write_count,
                     dut.u_pwm.cmd_l, $signed(dut.u_pwm.cmd_l),
                     dut.u_pwm.cmd_r, $signed(dut.u_pwm.cmd_r),
                     dut.u_pwm.armed, $time, cycle_count);
            pwm_write_count <= pwm_write_count + 1;
        end
        if (commit_chk && (dut.u_pwm.active_l !== commit_l_q || dut.u_pwm.active_r !== commit_r_q))
            $fatal(1, "[TB FATAL] ACTIVE != committed CMD after armed COMMIT: ACTIVE L=0x%04x R=0x%04x, CMD L=0x%04x R=0x%04x",
                   dut.u_pwm.active_l, dut.u_pwm.active_r, commit_l_q, commit_r_q);
    end

    // Safety watchdog trip check (ensure watchdog never trips spuriously during valid run)
    always @(posedge clk) begin
        if (rst_n && dut.u_safety.flag_wdt_expired) begin
            $fatal(1, "[TB FATAL] Safety watchdog tripped unexpectedly at sim time %0t (cycle %0d)! Disarm=%0b",
                   $time, cycle_count, actuator_disarm);
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

        // %t prints in ns with the unit (the TB precision is 1 ps, so the old
        // bare %0t printed ps values that were labelled "ns").
        $timeformat(-9, 0, " ns", 0);
        $display("\n=======================================================");
        $display("   STARTING RISC-V ROBOT NAVIGATION SOC SIMULATION     ");
        $display("   ROM: %s", `ROM_INIT_FILE);
        $display("   sim clk 50 MHz; results cycle-equivalent; nominal board time = cycles / 25 MHz (B1 open)");
        $display("   UART_DIV=%0d, NAV_TIME_LIMIT_NS=%0d (sim ns)", `UART_DIV, `NAV_TIME_LIMIT_NS);
        $display("=======================================================");

        // Hold reset for 5 cycles
        #100;
        rst_n = 1;
        $display("[TB] System reset deasserted at sim time %0t", $time);

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

            // 3. Assert motor commands (M2 contract v3 signed CMD words) and safety interlock.
            // History index 0 = zero COMMIT of the arm sequence; 1..3 = nav cycles 1..3.
            // Firmware safety filter (clamp 64, slew 8/tick, proximity): Cycle1 v 23->8, w=7.
            // Cycle2 v -24->0, w 127->64->15. Cycle3 wall ~11 cm -> v=0, w 65->64->23.
            // cmd = sign(x)*min(1000,(|x|*1000)>>7), x = v-w (L), v+w (R).
            // Reference: sw/test/test_nav_expected.py (uses sw/test/motor_cmd_ref.py).
            if (pwm_write_count != 4)
                $fatal(1, "[TB FATAL] expected 4 motor COMMITs (1 arm-zero + 3 nav), got %0d", pwm_write_count);
            if (pwm_left_history[0] != 16'h0000 || pwm_right_history[0] != 16'h0000)
                $fatal(1, "[TB FATAL] arm-sequence COMMIT not zero: L=0x%04x R=0x%04x", pwm_left_history[0], pwm_right_history[0]);
            if (pwm_left_history[1] != 16'h0007 || pwm_right_history[1] != 16'h0075) begin
                $fatal(1, "[TB FATAL] Cycle 1 CMD mismatch: got L=0x%04x, R=0x%04x (expected 0x0007, 0x0075)",
                       pwm_left_history[1], pwm_right_history[1]);
            end
            $display(" [ASSERT 5 PASS] Cycle 1 CMD forward drive, small right bias: L=%0d, R=%0d",
                     $signed(pwm_left_history[1]), $signed(pwm_right_history[1]));

            if (pwm_left_history[2] != 16'hff8b || pwm_right_history[2] != 16'h0075) begin
                $fatal(1, "[TB FATAL] Cycle 2 CMD mismatch: got L=0x%04x, R=0x%04x (expected 0xff8b, 0x0075)",
                       pwm_left_history[2], pwm_right_history[2]);
            end
            $display(" [ASSERT 6 PASS] Cycle 2 CMD slew-limited turn in place: L=%0d, R=%0d",
                     $signed(pwm_left_history[2]), $signed(pwm_right_history[2]));

            if (pwm_left_history[3] != 16'hff4d || pwm_right_history[3] != 16'h00b3) begin
                $fatal(1, "[TB FATAL] Cycle 3 CMD mismatch: got L=0x%04x, R=0x%04x (expected 0xff4d, 0x00b3)",
                       pwm_left_history[3], pwm_right_history[3]);
            end
            // Unclamped (raw v=+23, w=+65, no filter) would be L=cmd(-42)=-328 (0xfeb8),
            // R=cmd(88)=687 (0x02af). v_safe=0 requires L == -R exactly.
            if (pwm_left_history[3] == 16'hfeb8 || pwm_right_history[3] == 16'h02af)
                $fatal(1, "[TB FATAL] Cycle 3 CMD equals the UNCLAMPED value: safety override did not act");
            if ($signed(pwm_left_history[3]) != -$signed(pwm_right_history[3]))
                $fatal(1, "[TB FATAL] Cycle 3 L=%0d R=%0d, not consistent with v_safe=0",
                       $signed(pwm_left_history[3]), $signed(pwm_right_history[3]));
            $display(" [ASSERT 7 PASS] Cycle 3 Safety Override verified: v_cmd clamped to 0, CMD L=%0d, R=%0d",
                     $signed(pwm_left_history[3]), $signed(pwm_right_history[3]));

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
