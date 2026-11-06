// TEST-ONLY (M11b M1 closure). Negative control for the watchdog heartbeat fix:
// force the UART's internal busy flag to 1 so uart_puts spins forever on TX_BUSY.
// Compiled together with tb_soc_nav.v (hierarchical references); never synthesized.
// Run via `make test_wdt_uart_stall` (sim/Makefile).
// STALL_MODE 0: force from reset (first banner stalls).
// STALL_MODE 1: force at the cycle the TB first sees the CAFEBABE pass token
//               (the post-pass banner stalls).
// Expected: firmware stops kicking -> flag_wdt_expired -> TB $fatal -> rc!=0.
// A stuck UART must NOT keep the watchdog alive. M1 places the per-byte heartbeat
// AFTER the TX-busy wait in uart_puts/uart_put_nibble (docs/48 sec. 2); this test
// fails if a future change moves the kick before or into that wait.
`timescale 1ns / 1ps
`ifndef STALL_MODE
`define STALL_MODE 0
`endif
module uart_stall_inject;
    reg forced = 1'b0;
    reg [63:0] c = 0;
    always @(posedge tb_soc_nav.clk) if (tb_soc_nav.rst_n) c <= c + 1;
    always @(posedge tb_soc_nav.clk) begin
        if (!forced && tb_soc_nav.rst_n &&
            ((`STALL_MODE == 0) || (tb_soc_nav.test_passed === 1'b1))) begin
            forced = 1'b1;
            force tb_soc_nav.dut.u_uart.busy = 1'b1;
            $display("[STALL] cyc=%0d forcing u_uart.busy=1 (mode %0d)", c, `STALL_MODE);
        end
    end
    always @(posedge tb_soc_nav.clk)
        if (forced && tb_soc_nav.dut.u_safety.flag_wdt_expired)
            $display("[STALL] cyc=%0d flag_wdt_expired=1 disarm=%0b pwm_cmd L=%0d R=%0d",
                     c, tb_soc_nav.actuator_disarm, tb_soc_nav.pwm_left_cmd, tb_soc_nav.pwm_right_cmd);
endmodule
