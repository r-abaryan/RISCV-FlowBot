// M11b M2 step 2: directed unit TB for soc_pwm contract v3 (simulation only).
// Covers smoke-level T1, T2, T4, T5, T6, T7(override 2000), T9, T10, T11, S1, S2, E2-like.
// Exhaustive V-IF1/2/3, P1 random, NC mutants: NOT here (next step).
`timescale 1ns / 1ps
module tb_soc_pwm_unit;
    localparam PERIOD = 1000;
    localparam STALE  = 10000;  // > 4 periods so measure loops do not trip stale
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg [31:0] adr = 0, dat = 0; reg we = 0, stb = 0, cyc = 0;
    wire [31:0] rdat; wire ack;
    reg disarm = 0, estop = 0, wdt = 0;
    wire pl, pr, dl, dr, en; wire [15:0] cl, cr;
    integer errors = 0;

    soc_pwm #(.PERIOD(PERIOD), .STALE_CYCLES(STALE)) dut (
        .clk(clk), .rst_n(rst_n), .wb_adr_i(adr), .wb_dat_i(dat), .wb_dat_o(rdat),
        .wb_we_i(we), .wb_sel_i(4'hF), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
        .disarm_in(disarm), .estop_in(estop), .wdt_trip_in(wdt),
        .pwm_left_out(pl), .pwm_right_out(pr), .dir_left_out(dl), .dir_right_out(dr),
        .motor_en_out(en), .pwm_left_cmd(cl), .pwm_right_cmd(cr));

    task check(input cond, input [8*64-1:0] msg);
        begin if (!cond) begin errors = errors + 1; $display("[UNIT-FAIL] %0s t=%0t", msg, $time); end end
    endtask

    // Wishbone write: request held until ack (write takes effect on the ack edge)
    task wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk); adr = {24'h0, a}; dat = d; we = 1; stb = 1; cyc = 1;
            do begin @(posedge clk); #1; end while (!ack);   // hold until accepted
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

    // count high cycles over one full period starting at counter==0
    integer hl, hr;
    task measure;
        integer i;
        begin
            while (dut.pwm_counter != 0) @(negedge clk);
            hl = 0; hr = 0;
            for (i = 0; i < PERIOD; i = i + 1) begin
                if (pl) hl = hl + 1; if (pr) hr = hr + 1;
                @(negedge clk);
            end
        end
    endtask
    task wait_period; begin while (dut.pwm_counter != PERIOD-1) @(negedge clk); @(negedge clk); end endtask

    task arm_seq;   // zero-arm sequence (M2_STEP1_DECISIONS.md section C)
        begin
            wr(8'h00, 32'h4); wr(8'h04, 0); wr(8'h08, 0); wr(8'h0C, 0);
            wr(8'h00, 32'h1);
        end
    endtask

    integer k, t_commit;
    initial begin
        // ---- T1 / E2: reset state, E-stop held from power-up ----
        estop = 1; disarm = 1;
        #1; check(!pl && !pr && !en, "T1/E2 outputs low during reset");
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (2*PERIOD) begin @(negedge clk); check(!pl && !pr && !en && !dl && !dr, "T1 outputs low after release"); end
        check(dut.estop_seen, "E2 ESTOP_SEEN latched at power-up");
        wr(8'h00, 32'h4); rd(8'h10);
        check(rd_v[7] && rd_v[8], "T11 FAULT_CLR refused while E-stop held");
        estop = 0; disarm = 0;
        arm_seq; rd(8'h10);
        check(rd_v[0] && !rd_v[8] && !rd_v[7], "T10 armed after release + sequence");
        rd(8'h18); check(rd_v == STALE, "PARAMS == STALE_CYCLES");

        // ---- T2: zero command ----
        wr(8'h0C, 0);
        for (k = 0; k < 3; k = k + 1) begin measure; check(hl == 0 && hr == 0, "T2 zero cmd high cycles"); end

        // ---- V-IF1 smoke: a few values, measured high cycles ----
        wr(8'h04, 500); wr(8'h08, -16'sd250); wr(8'h0C, 0); wait_period;
        measure; check(hl == 500 && hr == 250, "VIF1 500/-250 duty");
        check(!dl && dr && en, "VIF1 DIR sign");
        wr(8'h04, 1000); wr(8'h08, -16'sd1); wr(8'h0C, 0); wait_period;
        measure; check(hl == 1000 && hr == 1 && !dl && dr, "VIF1 1000/-1");

        // ---- T4: mid-period commit does not alter current pulse ----
        wr(8'h04, 100); wr(8'h08, 100); wr(8'h0C, 0); wait_period;
        while (dut.pwm_counter != 300) @(negedge clk);
        wr(8'h04, 700); wr(8'h08, 700); wr(8'h0C, 0);
        check(cl == 100 && cr == 100, "T4 shadow unchanged mid-period");
        wait_period; check(cl == 700 && cr == 700, "T4 both sides change at rollover");

        // ---- T7/S1: stale exact timing; COMMIT on the expiry edge loses ----
        wr(8'h0C, 0); t_commit = 0;   // last accepted reload: this write's edge
        // stale_cnt == STALE right after this edge; expiry STALE edges later
        k = 0;
        while (!dut.fault_stale) begin @(posedge clk); #1; k = k + 1; end
        check(k == STALE, "T7 FAULT_STALE exactly STALE edges after reload");
        if (k != STALE) $display("  measured %0d edges", k);
        check(!pl && !pr && !en, "T7 pins low on stale edge");
        // T9: no auto-resume
        wr(8'h04, 300); wr(8'h0C, 0); rd(8'h14);
        check(rd_v == 0 && !en, "T9 commit after fault ignored");
        rd(8'h10); check(rd_v[1], "T9 FAULT_STALE still latched");
        // T10: ARM before FAULT_CLR -> rejected
        wr(8'h00, 32'h1); rd(8'h10); check(rd_v[7] && !rd_v[0], "T10 ARM w/o FAULT_CLR rejected");
        arm_seq; rd(8'h10); check(rd_v[0], "T10 re-armed");

        // S1: COMMIT on the exact expiry edge
        wr(8'h04, 200); wr(8'h0C, 0);
        while (dut.stale_cnt != 2) @(negedge clk);
        @(negedge clk); // now stale_cnt == 1: next edge is expiry
        adr = 8'h0C; dat = 0; we = 1; stb = 1; cyc = 1; @(posedge clk); #1; stb = 0; cyc = 0; we = 0;
        check(dut.fault_stale && dut.active_l == 0, "S1 stale wins over same-edge COMMIT");
        arm_seq;

        // ---- T11: FAULT_CLR with non-zero staged cmd rejected (no fault latched path) ----
        wr(8'h04, 5); wr(8'h00, 32'h2); // DISARM
        rd(8'h04); check(rd_v == 0, "R3 kill clears staged CMD");
        wr(8'h04, 5); wr(8'h00, 32'h4); rd(8'h10);
        check(rd_v[7] && rd_v[14:12] == 3'd6, "T11 FAULT_CLR refused, staged CMD nonzero");
        wr(8'h00, 32'h1); rd(8'h10); check(!rd_v[0] && rd_v[14:12] == 3'd6, "T10 ARM refused, staged CMD nonzero");
        arm_seq;

        // ---- S2: COMMIT + disarm_in same edge ----
        wr(8'h04, 400);
        @(negedge clk); adr = 8'h0C; we = 1; stb = 1; cyc = 1; disarm = 1;
        #1; check(!pl && !pr && !en, "S2 pins low combinationally on disarm_in");
        @(posedge clk); #1; stb = 0; cyc = 0; we = 0;
        check(!dut.armed && dut.active_l == 0 && dut.cmd_l == 0, "S2 kill wins, CMD cleared");
        disarm = 0; arm_seq;

        // ---- T5 / T6: commits while disarmed ----
        wr(8'h00, 32'h2);                  // disarm
        wr(8'h04, 300); wr(8'h0C, 0); rd(8'h10);
        check(!rd_v[2] && rd_v[6] && !en, "T5 in-range commit while disarmed: no effect, no fault");
        wr(8'h04, 1001); wr(8'h0C, 0); rd(8'h10);
        check(rd_v[2], "T6 FAULT_RANGE latched while disarmed");
        arm_seq; rd(8'h10); check(rd_v[0] && !rd_v[2], "recover from range fault");
        wr(8'h04, -16'sd1001); wr(8'h0C, 0); rd(8'h10);
        check(rd_v[2] && !rd_v[0] && !en, "range fault armed (-1001)");
        wr(8'h04, 16'h8000); rd(8'h04); check(rd_v == 0, "R2 CMD write discarded while faulted");

        // ---- F1 (contract v3.1): ARM_REQ+FAULT_CLR in one CTRL write is rejected, reason 7 ----
        wr(8'h00, 32'h2); wr(8'h00, 32'h4); wr(8'h04, 0); wr(8'h08, 0);   // disarm, clear prior fault, zero CMD
        rd(8'h10); check(!rd_v[0] && !rd_v[1] && !rd_v[2], "F1 pre: disarmed, no fault");
        wr(8'h00, 32'h5); rd(8'h10);
        check(!rd_v[0] && rd_v[7] && rd_v[14:12] == 3'd7 && !en, "F1a 0x5 on clean state: not armed, reason 7");
        wr(8'h04, 16'd1001); wr(8'h0C, 0); rd(8'h10); check(rd_v[2], "F1b pre: FAULT_RANGE latched");
        wr(8'h00, 32'h5); rd(8'h10);
        check(!rd_v[0] && rd_v[2] && rd_v[7] && rd_v[14:12] == 3'd7, "F1b 0x5 with fault: fault stays, reason 7");
        wr(8'h00, 32'h4); wr(8'h00, 32'h1); rd(8'h10);
        check(rd_v[0] && !rd_v[2] && !rd_v[7], "F1c separate 0x4 then 0x1 arms");
        wr(8'h00, 32'h7); rd(8'h10);
        check(!rd_v[0] && rd_v[7] && rd_v[14:12] == 3'd7 && !en, "F1d 0x7 while armed: DISARM acts, reason 7");
        wr(8'h00, 32'h4); wr(8'h00, 32'hFFFF_FFF9); rd(8'h10);
        check(rd_v[0] && !rd_v[7], "F1e reserved CTRL bits 31:3 ignored (0xFFFFFFF9 arms)");
        wr(8'h00, 32'h2); rd(8'h10); check(!rd_v[0] && !en, "F1 post: disarmed");

        if (errors == 0) $display("[UNIT-PASS] soc_pwm directed unit tests, 0 failures");
        else $fatal(1, "FATAL: [UNIT-FAIL] %0d failures", errors);
        $finish;
    end
    initial begin #50_000_000; $fatal(1, "FATAL: unit TB timeout"); end
endmodule
