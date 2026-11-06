// TEST-ONLY (M11b M1 closure). CHARACTERIZATION probe, not an acceptance test.
// Observes the PWM block after the pass token: any duty/enable write, register
// + gate state at end of the post-pass window, and the measured pin-high
// fraction over the final PROBE_WIN cycles of the window.
// M1 documented a defect: the idle loop left the last duty (L=410/R=589) and
// pwm_en=1 in place. M2 (contract v3): firmware writes DISARM before idling, so
// at the end of the post-pass window the probe now ASSERTS armed=0, ACTIVE=0,
// SHADOW=0, motor_en_out=0, both PWM pins low for the whole window, and no PWM
// writes other than DISARM after the pass token ($fatal otherwise). Run via
// `make char_pwm_idle` (sim/Makefile); compiled with tb_soc_nav.v.
`timescale 1ns / 1ps
`ifndef PROBE_WIN
`define PROBE_WIN 524288
`endif
module pwm_idle_probe;
    `define PW tb_soc_nav.dut.u_pwm
    reg [63:0] c = 0;
    reg pass_seen = 0; reg [63:0] pass_c = 0;
    integer hiL = 0, hiR = 0, n = 0, wr_after = 0;
    reg done = 0;
    reg [63:0] win_start = 0;
    // The measurement window must fit inside the post-pass window, otherwise the
    // unsigned start index underflows and the window is silently empty.
    initial if (`PROBE_WIN + 4 > `NAV_POST_PASS_CYCLES)
        $fatal(1, "[PWMPROBE-ERROR] PROBE_WIN=%0d does not fit NAV_POST_PASS_CYCLES=%0d",
               `PROBE_WIN, `NAV_POST_PASS_CYCLES);
    wire wr = `PW.wb_cyc_i && `PW.wb_stb_i && `PW.wb_we_i && !`PW.wb_ack_o;
    always @(posedge tb_soc_nav.clk) if (tb_soc_nav.rst_n) begin
        c <= c + 1;
        if (tb_soc_nav.test_passed === 1'b1 && !pass_seen) begin
            pass_seen <= 1; pass_c <= c;
            $display("[PWMPROBE] cyc=%0d pass: armed=%0b motor_en=%0b activeL=%0d activeR=%0d disarm=%0b cmdL=%0d cmdR=%0d",
                     c, `PW.armed, `PW.motor_en_out, `PW.active_l, `PW.active_r, `PW.disarm_in,
                     `PW.pwm_left_cmd, `PW.pwm_right_cmd);
        end
        if (pass_seen && wr) begin
            wr_after = wr_after + 1;
            if (!(`PW.wb_adr_i[7:0] == 8'h00 && `PW.wb_dat_i == 32'h2))
                $fatal(1, "[PWMPROBE-FAIL] non-DISARM PWM write after pass: adr=0x%02x data=0x%08x",
                       `PW.wb_adr_i[7:0], `PW.wb_dat_i);
            $display("[PWMPROBE] cyc=%0d PWM write after pass: adr=0x%02x data=%0d", c, `PW.wb_adr_i[7:0], `PW.wb_dat_i);
        end
        // Window = cycles pass_c+POST-WIN-1 .. pass_c+POST-2 inclusive = exactly
        // PROBE_WIN samples (M11b harness fix 3: the old '>=' start took WIN+1).
        if (pass_seen && !done && c > pass_c + `NAV_POST_PASS_CYCLES - `PROBE_WIN - 2) begin
            if (n == 0) win_start = c;
            n = n + 1; hiL = hiL + `PW.pwm_left_out; hiR = hiR + `PW.pwm_right_out;
        end
        if (pass_seen && !done && c >= pass_c + `NAV_POST_PASS_CYCLES - 2) begin
            done = 1;
            if (n == 0) $fatal(1, "[PWMPROBE-ERROR] empty measurement window (n=0)");
            if (n != `PROBE_WIN)
                $fatal(1, "[PWMPROBE-ERROR] window has %0d samples, expected PROBE_WIN=%0d", n, `PROBE_WIN);
            $display("[PWMPROBE-END] window cyc=%0d..%0d (%0d samples, pass token at cyc=%0d)",
                     win_start, c, n, pass_c);
            $display("[PWMPROBE-END] cyc=%0d armed=%0b motor_en=%0b activeL=%0d activeR=%0d shadowL=%0d shadowR=%0d disarm=%0b wdt_expired=%0b cmdL=%0d cmdR=%0d writes_after_pass=%0d",
                     c, `PW.armed, `PW.motor_en_out, `PW.active_l, `PW.active_r, `PW.shadow_l, `PW.shadow_r, `PW.disarm_in,
                     tb_soc_nav.dut.u_safety.flag_wdt_expired, `PW.pwm_left_cmd, `PW.pwm_right_cmd, wr_after);
            $display("[PWMPROBE-END] pin high over last %0d cycles: L=%0d (%0d ppm) R=%0d (%0d ppm)",
                     n, hiL, (hiL*64'd1000000)/n, hiR, (hiR*64'd1000000)/n);
            if (`PW.armed !== 1'b0 || `PW.motor_en_out !== 1'b0 ||
                `PW.active_l !== 16'sd0 || `PW.active_r !== 16'sd0 ||
                `PW.shadow_l !== 16'sd0 || `PW.shadow_r !== 16'sd0 || hiL != 0 || hiR != 0)
                $fatal(1, "[PWMPROBE-FAIL] idle state not safe after DISARM");
            $display("[PWMPROBE-PASS] idle after DISARM: disarmed, ACTIVE/SHADOW=0, EN=0, pins low for %0d cycles", n);
        end
    end
endmodule
