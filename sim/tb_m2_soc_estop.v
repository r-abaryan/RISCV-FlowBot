// M11b M2 Step 1b (owner decision F2, 2026-11-05): integrated-SoC input-validity assertion.
// SIMULATION ONLY, test-only. Instantiates the real rtl/soc_top.v (production RTL unchanged) and checks, on every
// clock edge, the two input invariants that make the soc_pwm "UNIT-only" combinations invalid in the SoC:
//   S1  u_pwm.estop_in    = 1  ->  u_pwm.disarm_in = 1   (asserted E-stop always implies asserted actuator disarm)
//   S2  u_pwm.wdt_trip_in = 1  ->  u_pwm.disarm_in = 1   (WDT status mirror only while disarmed)
// plus S3: the E-stop the PWM block sees is the same net the safety_filter sees (u_pwm.estop_in == u_safety.pin_estop_button).
// Stimulus: ext_estop_n driven by a fixed-seed LCG (pulses of 1..40 cycles, changes away from the clock edge),
// reset pulses, and forced WDT expiries (test-only deposit of u_safety.wdt_countdown = 3, the only internal poke).
// Firmware: firmware.hex (arms/drives PWM, then loops), so the checks run with live bus traffic.
// Vacuity: each of S1/S2 must see its antecedent true on >= MIN_HITS edges, else FATAL.
// Negative controls (make test_m2_soc_estop): temporary copies of soc_top.v with a broken connection must FATAL S1/S2.
`timescale 1ns / 1ps
`ifndef ROM_INIT_FILE
`define ROM_INIT_FILE "../sw/firmware/firmware.hex"
`endif
`ifndef N_CYCLES
`define N_CYCLES 200000
`endif
module tb_m2_soc_estop;
    reg clk = 0, rst_n = 0, ext_estop_n = 1;
    wire uart_tx, pl, pr, dl, dr, en, disarm;
    wire [15:0] cl, cr;
    always #10 clk = ~clk;

    soc_top #(.ROM_INIT_FILE(`ROM_INIT_FILE), .UART_CLKS_PER_BIT(16)) dut (
        .clk(clk), .rst_n(rst_n), .ext_estop_n(ext_estop_n), .uart_tx(uart_tx),
        .pwm_left_out(pl), .pwm_right_out(pr), .pwm_left_cmd(cl), .pwm_right_cmd(cr),
        .dir_left_out(dl), .dir_right_out(dr), .motor_en_out(en), .actuator_disarm(disarm));

    localparam integer MIN_HITS = 1000;
    integer cyc = 0, hits_e = 0, hits_w = 0, hits_ew = 0, hits_e_run = 0, errs = 0;
    reg [31:0] lcg = 32'h1234_5678;
    task nxt; lcg = lcg * 32'd1664525 + 32'd1013904223; endtask

    // checks sample the values the soc_pwm flops see at the edge (stimulus changes at +3/+13 ns, never on the edge)
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (dut.u_pwm.estop_in) begin
            hits_e = hits_e + 1; if (rst_n) hits_e_run = hits_e_run + 1;
            if (!dut.u_pwm.disarm_in) begin
                errs = errs + 1;
                $fatal(1, "[SOCESTOP-FAIL] S1 estop_in=1 with disarm_in=0 at cycle %0d", cyc);
            end
        end
        if (dut.u_pwm.wdt_trip_in) begin
            hits_w = hits_w + 1;
            if (dut.u_pwm.estop_in) hits_ew = hits_ew + 1;
            if (!dut.u_pwm.disarm_in) begin
                errs = errs + 1;
                $fatal(1, "[SOCESTOP-FAIL] S2 wdt_trip_in=1 with disarm_in=0 at cycle %0d", cyc);
            end
        end
        if (dut.u_pwm.estop_in !== dut.u_safety.pin_estop_button)
            $fatal(1, "[SOCESTOP-FAIL] S3 E-stop net differs between soc_pwm and safety_filter at cycle %0d", cyc);
    end

    integer k, len;
    initial begin
        #53 rst_n = 1;
        while (cyc < `N_CYCLES) begin
            nxt; len = 1 + (lcg[15:8] % 40);
            case (lcg[31:29])
                3'd0, 3'd1: begin ext_estop_n = 0; repeat (len) @(posedge clk); #3 ext_estop_n = 1; end
                3'd2: begin                                   // forced WDT expiry (test-only state deposit)
                          @(posedge clk); #3 dut.u_safety.wdt_countdown = 32'd3;
                          repeat (len + 8) @(posedge clk); #3;
                      end
                3'd3: begin #3 ext_estop_n = 0; dut.u_safety.wdt_countdown = 32'd3;   // both at once
                          repeat (len + 8) @(posedge clk); #3 ext_estop_n = 1; end
                3'd4: if (lcg[7:0] < 8'd16) begin @(posedge clk); #13 rst_n = 0;
                          repeat (1 + lcg[3:0]) @(posedge clk); #3 rst_n = 1; end
                default: begin repeat (len * 4) @(posedge clk); #3; end
            endcase
        end
        $display("[SOCESTOP] cycles=%0d estop_edges=%0d (out of reset %0d) wdt_edges=%0d both=%0d errors=%0d",
                 cyc, hits_e, hits_e_run, hits_w, hits_ew, errs);
        if (hits_e_run < MIN_HITS || hits_w < MIN_HITS || hits_ew < 1)
            $fatal(1, "[SOCESTOP-FAIL] vacuous: antecedent seen too rarely");
        $display("[SOCESTOP-PASS] S1 estop=>disarm, S2 wdt=>disarm, S3 shared E-stop net on every edge");
        $finish(0);
    end
endmodule
