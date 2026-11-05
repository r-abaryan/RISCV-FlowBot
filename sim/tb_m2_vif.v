// M11b M2 Step 1b/1c: exhaustive RTL interface checks V-IF1 / V-IF2 / V-IF3 (docs/50_M2_MOTOR_CONTRACT.md).
// SIMULATION ONLY, test-only, self-checking. DUT: rtl/periph/soc_pwm.v (unchanged), driven through its Wishbone port.
//
// V-IF1 (`define VIF1, PERIOD from -DP=...): for every c in -1000..+1000 and three wheel patterns
//   mode 0: (L,R)=(c,0)   mode 1: (L,R)=(0,c)   mode 2: (L,R)=(c,-c)
//   the TB stages CMD_L/CMD_R and COMMITs at mid-period; from the next counter==0 the TB counts pin-high cycles over one
//   full period and requires: high == floor(|cmd|*PERIOD/1000) per side (expected value computed here from the integer
//   formula, not read from the DUT), DIR == (cmd<0) on every cycle, EN == 1 on every cycle, monitor pwm_*_cmd == cmd.
//   Range sharded by +LO=<c> +HI=<c> (inclusive), modes by +MODES=<bitmask>.
// V-IF2 (`define VIF2): for every 16-bit value x outside -1000..+1000 (63,535 values) on L with R valid, then on R with
//   L valid (the valid side cycles through -1000..1000): from an armed, moving state (ACTIVE=SHADOW=(400,-400), PWM high
//   part running) write CMD=(x, valid) and COMMIT. Required on the ACK edge (checked 1 cycle later, at negedge): ARMED=0,
//   FAULT_RANGE=1, ACTIVE=0, SHADOW=0, EN=0, both pins 0, monitors 0, DIR 0. Escape monitor on EVERY cycle: ACTIVE and
//   SHADOW are always within -1000..+1000 (never the invalid value). Then the recovery sequence (FAULT_CLR, zero CMD,
//   ARM, CMD=(400,-400), COMMIT, wait for rollover) restores the moving state for the next value. Sharded by +LO/+HI
//   over the 16-bit raw value 0..65535 (in-range values inside the shard are skipped), sides by +SIDES=<bitmask>.
// V-IF3 (`define VIF3): (L,R) in {-1001,-1000,-1,0,1,1000,1001}^2 = 49 pairs from the armed moving state: accepted (ACTIVE
//   == (L,R), armed, no fault) iff both in range; else range fault as in V-IF2.
// Internal signals read (test-only, hierarchical): pwm_counter (window alignment), armed, fault_range, active_*, shadow_*.
// Negative-control hooks: -DNC_EXPECT_PLUS1=<c> perturbs the expected high count for one c by +1 (must FATAL V-IF1).
// Exit: $finish(0) with [VIF-PASS] and counts; any failure -> $fatal(1, "[VIF-FAIL] ...") on the first error.
`timescale 1ns / 1ps
`ifndef P
`define P 1000
`endif
module tb_m2_vif;
    localparam integer PERIOD = `P;
    localparam integer STALE  = 4 * `P + 64;
    reg clk = 0, rst_n = 0;
    reg [31:0] adr = 0, dat = 0; reg we = 0, stb = 0, cyc = 0;
    wire [31:0] rdat; wire ack, pl, pr, dl, dr, en; wire [15:0] cl, cr;
    always #5 clk = ~clk;
    soc_pwm #(.PERIOD(PERIOD), .STALE_CYCLES(STALE)) dut (
        .clk(clk), .rst_n(rst_n), .wb_adr_i(adr), .wb_dat_i(dat), .wb_dat_o(rdat), .wb_we_i(we), .wb_sel_i(4'hF),
        .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack), .disarm_in(1'b0), .estop_in(1'b0), .wdt_trip_in(1'b0),
        .pwm_left_out(pl), .pwm_right_out(pr), .dir_left_out(dl), .dir_right_out(dr), .motor_en_out(en),
        .pwm_left_cmd(cl), .pwm_right_cmd(cr));

    integer n_wait;
    task wr(input [7:0] a, input [31:0] d);
        begin @(negedge clk); adr = {24'h0, a}; dat = d; we = 1; stb = 1; cyc = 1;
              n_wait = 0;
              do begin @(posedge clk); #1; n_wait = n_wait + 1; end while (!ack && n_wait < 4);
              if (!ack) $fatal(1, "[VIF-FAIL] no ACK on write %h", a);
              stb = 0; cyc = 0; we = 0; end
    endtask
    function integer absv(input integer v); absv = v < 0 ? -v : v; endfunction
    function integer expect_hi(input integer v); expect_hi = (absv(v) * PERIOD) / 1000; endfunction

    integer lo, hi, modes, sides, n_checked = 0, n_skipped = 0;

`ifdef VIF1
    // ---------------------------------------------------------------- V-IF1 window checker
    integer exp_l = 0, exp_r = 0, nxt_l = 0, nxt_r = 0, win_l = 0, win_r = 0;
    integer hl = 0, hr = 0, ncyc = 0;
    reg nxt_valid = 0, win_valid = 0;
    integer windows_checked = 0;
    always @(negedge clk) if (rst_n) begin
        if (dut.pwm_counter == 0) begin
            if (win_valid) begin
                if (ncyc != PERIOD) $fatal(1, "[VIF-FAIL] window length %0d", ncyc);
                if (hl != expect_hi(win_l) `ifdef NC_EXPECT_PLUS1 + ((win_l == `NC_EXPECT_PLUS1) ? 1 : 0) `endif)
                    $fatal(1, "[VIF-FAIL] V-IF1 P=%0d L=%0d high=%0d expected=%0d", PERIOD, win_l, hl, expect_hi(win_l));
                if (hr != expect_hi(win_r))
                    $fatal(1, "[VIF-FAIL] V-IF1 P=%0d R=%0d high=%0d expected=%0d", PERIOD, win_r, hr, expect_hi(win_r));
                windows_checked = windows_checked + 1;
            end
            win_valid = nxt_valid; win_l = nxt_l; win_r = nxt_r; nxt_valid = 0;
            hl = 0; hr = 0; ncyc = 0;
        end
        if (win_valid) begin
            ncyc = ncyc + 1; hl = hl + pl; hr = hr + pr;
            if (!en) $fatal(1, "[VIF-FAIL] V-IF1 EN low while moving L=%0d R=%0d", win_l, win_r);
            if (dl !== (win_l < 0) || dr !== (win_r < 0))
                $fatal(1, "[VIF-FAIL] V-IF1 DIR L=%0d dl=%b R=%0d dr=%b", win_l, dl, win_r, dr);
            if ($signed(cl) != win_l || $signed(cr) != win_r)
                $fatal(1, "[VIF-FAIL] V-IF1 monitor L=%0d/%0d R=%0d/%0d", $signed(cl), win_l, $signed(cr), win_r);
        end
    end
    integer c, m, l, r;
    initial begin
        if (!$value$plusargs("LO=%d", lo)) lo = -1000;
        if (!$value$plusargs("HI=%d", hi)) hi = 1000;
        if (!$value$plusargs("MODES=%d", modes)) modes = 7;
        #23 rst_n = 1;
        wr(8'h00, 32'h4); wr(8'h04, 0); wr(8'h08, 0); wr(8'h0C, 0); wr(8'h00, 32'h1);
        if (!dut.armed) $fatal(1, "[VIF-FAIL] zero-arm did not arm");
        for (m = 0; m < 3; m = m + 1) if (modes[m]) for (c = lo; c <= hi; c = c + 1) begin
            l = (m == 1) ? 0 : c; r = (m == 0) ? 0 : (m == 1 ? c : -c);
            @(negedge clk); while (dut.pwm_counter != PERIOD / 2) @(negedge clk);
            wr(8'h04, l); wr(8'h08, r); wr(8'h0C, 0);
            nxt_l = l; nxt_r = r; nxt_valid = 1;
            n_checked = n_checked + 1;
        end
        @(negedge clk); while (dut.pwm_counter != PERIOD / 2) @(negedge clk);   // let the last window complete
        @(negedge clk); while (dut.pwm_counter != PERIOD / 2) @(negedge clk);
        if (windows_checked != n_checked) $fatal(1, "[VIF-FAIL] windows %0d != values %0d", windows_checked, n_checked);
        $display("[VIF-PASS] V-IF1 P=%0d values %0d..%0d modes=%0d windows=%0d", PERIOD, lo, hi, modes, windows_checked);
        $finish(0);
    end
`endif

`ifdef VIF2_OR_3
`else
`ifdef VIF2
`define VIF2_OR_3
`endif
`ifdef VIF3
`define VIF2_OR_3
`endif
`endif
`ifdef VIF2_OR_3
    // ---------------------------------------------------------------- escape monitor (every cycle)
    always @(negedge clk) if (rst_n) begin
        if ($signed(dut.active_l) > 1000 || $signed(dut.active_l) < -1000 || $signed(dut.active_r) > 1000 ||
            $signed(dut.active_r) < -1000 || $signed(dut.shadow_l) > 1000 || $signed(dut.shadow_l) < -1000 ||
            $signed(dut.shadow_r) > 1000 || $signed(dut.shadow_r) < -1000)
            $fatal(1, "[VIF-FAIL] ESCAPE out-of-range ACTIVE/SHADOW %0d %0d %0d %0d", $signed(dut.active_l),
                   $signed(dut.active_r), $signed(dut.shadow_l), $signed(dut.shadow_r));
    end
    task moving;   // recovery sequence -> armed, ACTIVE=SHADOW=(400,-400)
        begin
            wr(8'h00, 32'h4); wr(8'h04, 0); wr(8'h08, 0); wr(8'h00, 32'h1);
            wr(8'h04, 400); wr(8'h08, -400); wr(8'h0C, 0);
            @(negedge clk); while (dut.pwm_counter != 0) @(negedge clk);
            if (!(dut.armed && !dut.fault_range && $signed(dut.shadow_l) == 400 && $signed(dut.shadow_r) == -400 && en && pl))
                $fatal(1, "[VIF-FAIL] recovery did not reach the moving state");
        end
    endtask
    task try_pair(input integer l, input integer r, input [31:0] wl, input [31:0] wr_);
        reg ok;
        begin
            ok = (l >= -1000 && l <= 1000 && r >= -1000 && r <= 1000);
            wr(8'h04, wl); wr(8'h08, wr_); wr(8'h0C, 0);   // COMMIT acts on this ACK edge
            @(negedge clk);
            if (ok) begin
                if (!(dut.armed && !dut.fault_range && $signed(dut.active_l) == l && $signed(dut.active_r) == r))
                    $fatal(1, "[VIF-FAIL] valid pair (%0d,%0d) not accepted", l, r);
            end else begin
                if (!(!dut.armed && dut.fault_range && dut.active_l == 0 && dut.active_r == 0 && dut.shadow_l == 0 &&
                      dut.shadow_r == 0 && !en && !pl && !pr && !dl && !dr && cl == 0 && cr == 0))
                    $fatal(1, "[VIF-FAIL] invalid pair (%0d,%0d) [raw %h,%h]: armed=%b fr=%b act=%0d,%0d sh=%0d,%0d en=%b pl=%b pr=%b",
                           l, r, wl, wr_, dut.armed, dut.fault_range, $signed(dut.active_l), $signed(dut.active_r),
                           $signed(dut.shadow_l), $signed(dut.shadow_r), en, pl, pr);
            end
        end
    endtask
`endif

`ifdef VIF2
    integer x, side, sv, valid_i = 0;
    initial begin
        if (!$value$plusargs("LO=%d", lo)) lo = 0;
        if (!$value$plusargs("HI=%d", hi)) hi = 65535;
        if (!$value$plusargs("SIDES=%d", sides)) sides = 3;
        #23 rst_n = 1;
        moving;
        for (side = 0; side < 2; side = side + 1) if (sides[side]) for (x = lo; x <= hi; x = x + 1) begin
            sv = (x >= 32768) ? x - 65536 : x;
            if (sv >= -1000 && sv <= 1000) n_skipped = n_skipped + 1;
            else begin
                valid_i = valid_i + 1;
                if (side == 0) try_pair(sv, (valid_i % 2001) - 1000, {{16{sv[15]}}, sv[15:0]}, (valid_i % 2001) - 1000);
                else           try_pair((valid_i % 2001) - 1000, sv, (valid_i % 2001) - 1000, {{16{sv[15]}}, sv[15:0]});
                n_checked = n_checked + 1;
                moving;
            end
        end
        $display("[VIF-PASS] V-IF2 P=%0d raw %0d..%0d sides=%0d invalid_values_checked=%0d in_range_skipped=%0d",
                 PERIOD, lo, hi, sides, n_checked, n_skipped);
        $finish(0);
    end
`endif

`ifdef VIF3
    integer i, j; integer vals [0:6];
    initial begin
        vals[0] = -1001; vals[1] = -1000; vals[2] = -1; vals[3] = 0; vals[4] = 1; vals[5] = 1000; vals[6] = 1001;
        #23 rst_n = 1;
        moving;
        for (i = 0; i < 7; i = i + 1) for (j = 0; j < 7; j = j + 1) begin
            try_pair(vals[i], vals[j], vals[i], vals[j]); n_checked = n_checked + 1; moving;
        end
        $display("[VIF-PASS] V-IF3 P=%0d pairs=%0d", PERIOD, n_checked);
        $finish(0);
    end
`endif
endmodule
