// ============================================================================
// wdt_kick_monitor.v  (TEST-ONLY regression monitor, added in M11b)
// Passive second top-level module compiled alongside tb_soc_nav (make
// test_nav_div217). It never drives the DUT. It observes the
// UNMODIFIED safety_filter via hierarchical references and reports:
//   * cycle of every accepted heartbeat (write of 0x5AFEC0DE to +0x04),
//     every CTRL clear (+0x00 bit1) and every TIMEOUT write (+0x0C)
//   * interval between consecutive refreshes (heartbeat or CTRL clear)
//   * minimum wdt_countdown seen while armed, and its cycle
//   * the first cycle flag_wdt_expired / flag_tripped rise (genuine expiry)
// Cycle counts are clock-frequency independent; the TB clock period does not
// change them. The UART divider is a cycle count, so UART_DIV=217 reproduces
// the board's 25 MHz / 115200 baud bit time in cycles.
// PASS/FAIL (M11b): at the summary point the monitor calls $fatal if the
// watchdog tripped, or if the longest refresh gap exceeds WDT_MAX_GAP_CYCLES
// (default 250,000 = 50% of the firmware's 500,000-cycle timeout), or if no
// refresh was ever seen. It prints [WDTMON-PASS] otherwise.
// Define WDTMON_VERBOSE to log every individual refresh (very long output).
// ============================================================================
`ifndef WDT_MAX_GAP_CYCLES
`define WDT_MAX_GAP_CYCLES 250000
`endif
`timescale 1ns / 1ps
module wdt_kick_monitor;
    localparam [31:0] KEY = 32'h5AFE_C0DE;
    `define SF tb_soc_nav.dut.u_safety

    reg  [63:0] cyc = 0;
    reg  [63:0] last_refresh = 0;
    reg  [63:0] max_gap = 0, max_gap_end = 0;
    reg  [31:0] min_cd = 32'hFFFF_FFFF;
    reg  [63:0] min_cd_at = 0;
    reg  [31:0] timeout_val_at_min = 0;
    integer     n_refresh = 0;
    reg         prev_wr = 1'b0;
    reg         reported_trip = 1'b0;
    reg         seen_refresh = 1'b0;

    wire wr      = `SF.bus_sel && `SF.bus_we;
    wire [7:0] a = `SF.bus_addr[7:0];
    wire hb      = wr && (a == 8'h04) && (`SF.bus_wdata == KEY);
    wire clr     = wr && (a == 8'h00) && `SF.bus_wstrb[0] && `SF.bus_wdata[1];
    wire tow     = wr && (a == 8'h0C);

    always @(posedge tb_soc_nav.clk) begin
        if (tb_soc_nav.rst_n) begin
            cyc <= cyc + 1;
            // count each bus write once (rising edge of the write strobe)
            if (wr && !prev_wr) begin
                if (tow)
                    $display("[WDTMON] cyc=%0d TIMEOUT write value=%0d", cyc, `SF.bus_wdata);
                if (hb || clr) begin
                    n_refresh = n_refresh + 1;
`ifdef WDTMON_VERBOSE
                    $display("[WDTMON] cyc=%0d %0s #%0d gap_since_prev=%0d countdown_before=%0d timeout=%0d",
                             cyc, hb ? "HEARTBEAT" : "CTRL_CLEAR", n_refresh,
                             cyc - last_refresh, `SF.wdt_countdown, `SF.reg_timeout_val);
`endif
                    if (seen_refresh && (cyc - last_refresh) > max_gap) begin
                        max_gap     <= cyc - last_refresh;
                        max_gap_end <= cyc;
                    end
                    last_refresh <= cyc;
                    seen_refresh <= 1'b1;
                end
            end
            prev_wr <= wr;
            if (seen_refresh && `SF.reg_enable && !`SF.flag_tripped && `SF.wdt_countdown < min_cd) begin
                min_cd    <= `SF.wdt_countdown;
                min_cd_at <= cyc;
                timeout_val_at_min <= `SF.reg_timeout_val;
            end
            if (`SF.flag_tripped && !reported_trip) begin
                reported_trip <= 1'b1;
                $display("[WDTMON] cyc=%0d TRIP flag_tripped=1 flag_wdt_expired=%0b estop=%0b",
                         cyc, `SF.flag_wdt_expired, `SF.pin_estop_button);
            end
        end
    end

    // Summary: printed NAV_POST_PASS_CYCLES after the pass token is seen, or
    // when the TB cycle budget is exhausted (timeout path).
    reg        pass_seen = 1'b0;
    reg [63:0] pass_cyc  = 0;
    always @(posedge tb_soc_nav.clk) begin
        if (tb_soc_nav.test_passed === 1'b1 && !pass_seen) begin
            pass_seen <= 1'b1; pass_cyc <= cyc;
            $display("[WDTMON] cyc=%0d PASS token (CAFEBABE) observed by TB", cyc);
        end
        if (pass_seen && cyc >= pass_cyc + `NAV_POST_PASS_CYCLES) summary;
        if (tb_soc_nav.cycle_count == `NAV_MAX_CYCLES) summary;
    end
    reg summarized = 1'b0;
    task summary;
        begin
            if (!summarized) begin
                summarized = 1'b1;
                $display("[WDTMON-SUMMARY] refreshes=%0d max_gap=%0d (ending cyc %0d) min_countdown=%0d at cyc %0d timeout=%0d margin=%0d (%0d.%01d%%) tripped=%0b wdt_expired=%0b end_cyc=%0d",
                         n_refresh, max_gap, max_gap_end, min_cd, min_cd_at, timeout_val_at_min,
                         min_cd, (min_cd*100)/timeout_val_at_min, ((min_cd*1000)/timeout_val_at_min)%10,
                         `SF.flag_tripped, `SF.flag_wdt_expired, cyc);
                if (`SF.flag_tripped || reported_trip)
                    $fatal(1, "[WDTMON-FAIL] watchdog/E-stop trip observed (wdt_expired=%0b)", `SF.flag_wdt_expired);
                else if (n_refresh < 2)
                    $fatal(1, "[WDTMON-FAIL] fewer than 2 watchdog refreshes observed (%0d)", n_refresh);
                else if (max_gap > `WDT_MAX_GAP_CYCLES)
                    $fatal(1, "[WDTMON-FAIL] max refresh gap %0d > budget %0d cycles", max_gap, `WDT_MAX_GAP_CYCLES);
                else
                    $display("[WDTMON-PASS] no trip; max refresh gap %0d <= budget %0d cycles over %0d cycles",
                             max_gap, `WDT_MAX_GAP_CYCLES, cyc);
            end
        end
    endtask
endmodule
