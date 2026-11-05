// M11b M2 step 3d: integration TB, safety_filter + soc_pwm wired exactly as in
// rtl/soc_top.v (disarm_in <= actuator_disarm, estop_in <= !ext_estop_n,
// wdt_trip_in <= safety_filter.wdt_expired_o). Simulation only. Small PERIOD/STALE/WDT values for speed.
// Checks:
//   I1 zero -> 0       : zero-arm gives armed, EN on, PWM pins low for a full period
//   I2 atomic          : CMD_L/CMD_R staged without COMMIT do not reach the pins;
//                        after COMMIT both wheels change on the same rollover edge
//   I3 WDT trip        : no heartbeat -> safety_filter trips -> soc_pwm kills on the
//                        same edge disarm_in rises; pins/EN low
//   I4 no reactivation : after safety_filter trip is cleared (disarm_in=0) soc_pwm stays
//                        disarmed, COMMIT ignored, ARM with stale CMD rejected
//   I5 clear + rearm   : FAULT_CLR -> zero-arm -> CMD+COMMIT -> motion resumes
//   I6 freshness vs WDT: WDT kept alive by heartbeat but no COMMIT -> FAULT_STALE
//   I7 liveness vs fresh: COMMITs kept fresh but no heartbeat -> WDT trip kills
//   I8 E-stop          : pin asserts -> kill + ESTOP_SEEN; release alone does not re-arm;
//                        FAULT_CLR rejected while pressed
// Negative control: -DNC_NO_DISARM ties soc_pwm.disarm_in to 0 -> I3 must FATAL.
`timescale 1ns / 1ps
module tb_m2_integration;
    localparam PERIOD = 100;
    localparam STALE  = 3000;
    localparam WDT    = 5000;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // soc_pwm wishbone
    reg  [31:0] adr = 0, dat = 0; reg we = 0, stb = 0, cyc = 0;
    wire [31:0] rdat; wire ack;
    // safety_filter bus
    reg  sreq = 0, swe = 0; reg [31:0] saddr = 0, swdata = 0;
    wire [31:0] srdata; wire sready;
    reg  ext_estop_n = 1;
    wire estop_tripped = !ext_estop_n;
    wire actuator_disarm;
    wire pl, pr, dl, dr, en; wire [15:0] cl, cr;

    safety_filter u_safety (
        .clk(clk), .rst_n(rst_n), .pin_estop_button(estop_tripped),
        .bus_req(sreq), .bus_we(swe), .bus_addr(saddr), .bus_wdata(swdata),
        .bus_wstrb(4'hF), .bus_rdata(srdata), .bus_ready(sready),
        .actuator_disarm(actuator_disarm), .wdt_expired_o(wdt_expired));

`ifdef NC_NO_DISARM
    wire disarm_to_pwm = 1'b0;
`else
    wire disarm_to_pwm = actuator_disarm;
`endif
    soc_pwm #(.PERIOD(PERIOD), .STALE_CYCLES(STALE)) u_pwm (
        .clk(clk), .rst_n(rst_n), .wb_adr_i(adr), .wb_dat_i(dat), .wb_dat_o(rdat),
        .wb_we_i(we), .wb_sel_i(4'hF), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
        .disarm_in(disarm_to_pwm), .estop_in(estop_tripped), .wdt_trip_in(wdt_expired),
        .pwm_left_out(pl), .pwm_right_out(pr), .dir_left_out(dl), .dir_right_out(dr),
        .motor_en_out(en), .pwm_left_cmd(cl), .pwm_right_cmd(cr));

    wire wdt_expired;
    integer errors = 0;
    task check(input cond, input [8*72-1:0] msg);
        begin if (!cond) begin errors = errors + 1; $display("[INT-FAIL] %0s t=%0t", msg, $time); end
              else $display("[INT-OK] %0s", msg); end
    endtask

    task wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk); adr = {24'h0, a}; dat = d; we = 1; stb = 1; cyc = 1;
            do begin @(posedge clk); #1; end while (!ack);
            stb = 0; cyc = 0; we = 0;
        end
    endtask
    reg [31:0] rd_v;
    task rd(input [7:0] a);
        begin
            @(negedge clk); adr = {24'h0, a}; we = 0; stb = 1; cyc = 1;
            do begin @(posedge clk); #1; end while (!ack);
            stb = 0; cyc = 0; rd_v = rdat;
        end
    endtask
    task swr(input [7:0] a, input [31:0] d);   // safety_filter write (1 edge)
        begin
            @(negedge clk); saddr = {24'h500006, a}; swdata = d; swe = 1; sreq = 1;
            @(posedge clk); #1; sreq = 0; swe = 0;
        end
    endtask
    reg [31:0] srd_v;
    task srd(input [7:0] a);                   // safety_filter read (combinational rdata)
        begin
            @(negedge clk); saddr = {24'h500006, a}; swe = 0; sreq = 1;
            #1; srd_v = srdata;
            @(posedge clk); #1; sreq = 0;
        end
    endtask
    task kick; swr(8'h04, 32'h5AFE_C0DE); endtask
    task arm_seq;   // zero-arm (M2_STEP1_DECISIONS.md section C)
        begin wr(8'h00, 32'h4); wr(8'h04, 0); wr(8'h08, 0); wr(8'h0C, 0); wr(8'h00, 32'h1); end
    endtask

    integer hl, hr, i;
    task measure;   // high cycles over one full period from counter==0
        begin
            @(negedge clk);   // align to a negedge so counter==0 is sampled once
            while (u_pwm.pwm_counter != 0) @(negedge clk);
            hl = 0; hr = 0;
            for (i = 0; i < PERIOD; i = i + 1) begin
                if (pl) hl = hl + 1; if (pr) hr = hr + 1;
                @(negedge clk);
            end
        end
    endtask

    integer k, edge_dis, edge_kill;
    initial begin
        #23 rst_n = 1;
        swr(8'h0C, WDT); kick;
        rd(8'h10); check(!rd_v[0] && !en && !pl && !pr, "I0 reset: disarmed, pins low");

        // ---- I1 zero -> 0 ----
        kick; arm_seq; kick;
        rd(8'h10); check(rd_v[0] && en, "I1 armed after zero-arm");
        measure; check(hl == 0 && hr == 0, "I1 zero command -> 0 high cycles both wheels");
        kick;

        // ---- I2 atomic ----
        wr(8'h04, 500); wr(8'h08, -16'sd250);   // staged only
        measure; check(hl == 0 && hr == 0, "I2 staged CMD without COMMIT does not reach pins");
        kick;
        wr(8'h0C, 0);
        // both shadows must change on the same edge
        k = 0;
        while (u_pwm.shadow_l == 0 && u_pwm.shadow_r == 0 && k < 2*PERIOD) begin @(posedge clk); #1; k = k + 1; end
        check(u_pwm.shadow_l == 500 && u_pwm.shadow_r == -16'sd250, "I2 both wheels loaded on the same rollover");
        measure; check(hl == 50 && hr == 25 && !dl && dr, "I2 duty 50/25 cycles, dir L=fwd R=rev");
        kick;

        // ---- I3 WDT trip (no heartbeat, keep COMMIT fresh) ----
        edge_dis = -1; edge_kill = -1; k = 0;
        while (k < WDT + 200 && edge_kill < 0) begin
            @(posedge clk); #1; k = k + 1;
            if (actuator_disarm && edge_dis < 0) edge_dis = k;
            if (!u_pwm.armed && edge_kill < 0) edge_kill = k;
            if (k % 1000 == 0) begin wr(8'h0C, 0); k = k + 3; end
        end
        check(edge_dis >= 0, "I3 safety_filter tripped without heartbeat");
        check(edge_kill >= 0 && edge_kill <= edge_dis + 1, "I3 soc_pwm disarmed within 1 edge of actuator_disarm");
        @(negedge clk);
        check(!en && !pl && !pr && cl == 0 && cr == 0, "I3 pins/EN/cmd low after WDT trip");
        rd(8'h14); check(rd_v == 0, "I3 ACTIVE cleared");
        rd(8'h10); check(rd_v[3] == 1'b1, "W1 STATUS.WDT_TRIP mirrors WDT expiry");
        srd(8'h08); check(srd_v[2] == 1'b1, "W1 SAFETY_STATUS[2] agrees");

        // ---- I4 no reactivation after safety_filter clear ----
        swr(8'h00, 32'h3); kick;              // enable + clear trip
        check(!actuator_disarm, "I4 safety_filter trip cleared (disarm_in=0)");
        rd(8'h10); check(rd_v[3] == 1'b0, "W2 STATUS.WDT_TRIP clears with safety_filter clear");
        wr(8'h04, 400); wr(8'h0C, 0);         // staging/COMMIT while disarmed
        rd(8'h14); check(rd_v == 0, "I4 COMMIT while disarmed ignored");
        measure; check(hl == 0 && hr == 0 && !en, "I4 no reactivation: pins low, EN off");
        rd(8'h04);
        if (rd_v != 0) begin
            wr(8'h00, 32'h1); rd(8'h10);
            check(!rd_v[0] && rd_v[7], "I4 ARM with non-zero CMD rejected");
        end else check(1, "I4 CMD write discarded while disarmed");
        kick;

        // ---- I5 clear + rearm ----
        arm_seq; kick;
        rd(8'h10); check(rd_v[0], "I5 re-armed via FAULT_CLR + zero-arm");
        wr(8'h04, 300); wr(8'h08, 300); wr(8'h0C, 0);
        measure; measure; check(hl == 30 && hr == 30 && en, "I5 motion resumes 30/30 after fresh COMMIT");
        kick;

        // ---- I6 freshness vs WDT: heartbeat alive, no COMMIT ----
        k = 0;
        while (u_pwm.armed && k < STALE + 500) begin
            @(posedge clk); #1; k = k + 1;
            if (k % 500 == 0) begin kick; k = k + 1; end
        end
        check(!u_pwm.armed && !actuator_disarm, "I6 stale kill while WDT alive (freshness independent)");
        rd(8'h10); check(rd_v[1], "I6 FAULT_STALE latched");
        check(!en && !pl && !pr, "I6 pins low");
        kick; arm_seq; kick;
        rd(8'h10); check(rd_v[0] && !rd_v[1], "I6 recovered via FAULT_CLR + zero-arm");

        // ---- I7 liveness vs freshness: COMMIT fresh, no heartbeat ----
        wr(8'h04, 200); wr(8'h08, 200); wr(8'h0C, 0);
        k = 0;
        while (u_pwm.armed && k < WDT + 500) begin
            @(posedge clk); #1; k = k + 1;
            if (k % 1000 == 0) begin wr(8'h0C, 0); k = k + 3; end
        end
        check(!u_pwm.armed && actuator_disarm && !u_pwm.fault_stale, "I7 WDT kill despite fresh COMMITs");
        rd(8'h10); check(rd_v[3] == 1'b1, "W3 STATUS.WDT_TRIP set after I7 WDT kill");
        swr(8'h00, 32'h3); kick;

        // ---- I8 E-stop ----
        arm_seq; kick;
        wr(8'h04, 600); wr(8'h0C, 0); measure; kick;
        check(hl == 60 && en, "I8 pre: moving 60");
        @(negedge clk); ext_estop_n = 0;
        @(posedge clk); #1;
        check(!u_pwm.armed && !en && !pl && !pr, "I8 E-stop kills on the assert edge");
        rd(8'h10); check(rd_v[8] && rd_v[4], "I8 ESTOP_SEEN + ESTOP live");
        wr(8'h00, 32'h4); rd(8'h10); check(rd_v[8] && rd_v[7], "I8 FAULT_CLR rejected while pressed");
        swr(8'h00, 32'h3); check(actuator_disarm, "I8 safety_filter refuses clear while pressed");
        @(negedge clk); ext_estop_n = 1;
        repeat (3) @(posedge clk); #1;
        check(!u_pwm.armed && !en, "I8 release alone does not re-arm");
        swr(8'h00, 32'h3); kick;
        arm_seq; kick;
        rd(8'h10); check(rd_v[0] && !rd_v[8], "I8 re-armed after release + clears");

        if (errors == 0) $display("[INT-PASS] M2 integration (safety_filter + soc_pwm), 0 failures");
        else $fatal(1, "FATAL: [INT-FAIL] %0d failures", errors);
        $finish;
    end
    initial begin #20_000_000; $fatal(1, "FATAL: integration TB timeout"); end
endmodule
