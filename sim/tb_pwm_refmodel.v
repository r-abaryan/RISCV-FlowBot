// M11b M2 Stage 1: lockstep trace TB for soc_pwm (simulation only).
// Replays a cycle vector file written by sw/test/test_pwm_refmodel.py and dumps the
// observable state after every rising edge. The Python reference model
// (sw/test/pwm_refmodel.py) replays the same vectors and compares line by line.
// This TB makes no pass/fail decision on the DUT itself; it only checks that the
// whole vector file was consumed ([REFTB-DONE] n=<count>).
//
// Vector word (64 bit hex, one per clock):
//   [63] reset (rst_n=0 for this cycle)   [62:61] op 0 idle, 1 write, 2 read
//   [60] disarm_in  [59] estop_in  [58] wdt_trip_in   [47:40] byte offset
//   [31:0] write data
// Inputs change at the falling edge; outputs are sampled 1 ns after the rising edge.
`timescale 1ns / 1ps
module tb_pwm_refmodel;
    parameter integer PERIOD = 4;
    parameter integer STALE  = 6;
    parameter integer MAXV   = 400000;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg [31:0] adr = 0, dat = 0; reg we = 0, stb = 0, cyc = 0;
    reg disarm = 1, estop = 0, wdt = 0;
    wire [31:0] rdat; wire ack;
    wire pl, pr, dl, dr, en; wire [15:0] cl, cr;

    soc_pwm #(.PERIOD(PERIOD), .STALE_CYCLES(STALE)) dut (
        .clk(clk), .rst_n(rst_n), .wb_adr_i(adr), .wb_dat_i(dat), .wb_dat_o(rdat),
        .wb_we_i(we), .wb_sel_i(4'hF), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
        .disarm_in(disarm), .estop_in(estop), .wdt_trip_in(wdt),
        .pwm_left_out(pl), .pwm_right_out(pr), .dir_left_out(dl), .dir_right_out(dr),
        .motor_en_out(en), .pwm_left_cmd(cl), .pwm_right_cmd(cr));

    reg [63:0] vec [0:MAXV-1];
    reg [1023:0] vfile, ofile;
    integer n, i, fd;

    initial begin
        if (!$value$plusargs("VEC=%s", vfile)) begin $display("FATAL: no +VEC"); $fatal(1); end
        if (!$value$plusargs("OUT=%s", ofile)) begin $display("FATAL: no +OUT"); $fatal(1); end
        if (!$value$plusargs("N=%d", n))       begin $display("FATAL: no +N");   $fatal(1); end
        if (n > MAXV || n < 1) begin $display("FATAL: N out of range"); $fatal(1); end
        for (i = 0; i < MAXV; i = i + 1) vec[i] = 64'hx;
        $readmemh(vfile, vec, 0, n - 1);
        if (^vec[n-1] === 1'bx) begin $display("FATAL: vector file shorter than N"); $fatal(1); end
        fd = $fopen(ofile, "w");
        if (fd == 0) begin $display("FATAL: cannot open OUT"); $fatal(1); end
        rst_n = 0;
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            rst_n  = !vec[i][63];
            cyc    = (vec[i][62:61] != 2'd0); stb = cyc;
            we     = (vec[i][62:61] == 2'd1);
            disarm = vec[i][60]; estop = vec[i][59]; wdt = vec[i][58];
            adr    = {24'h0, vec[i][47:40]};
            dat    = vec[i][31:0];
            @(posedge clk); #1;
            $fwrite(fd, "%0d %0d %0d %0d %0d %h %h %0d %0d %0d %0d %0d %0d %h %h %h %h %h %h %h %h %h\n",
                    pl, pr, dl, dr, en, cl, cr, dut.armed, dut.fault_stale, dut.fault_range,
                    dut.estop_seen, dut.arm_rejected, dut.reject_reason, dut.cmd_l, dut.cmd_r,
                    dut.active_l, dut.active_r, dut.shadow_l, dut.shadow_r, dut.stale_cnt,
                    dut.pwm_counter, rdat);
        end
        $fclose(fd);
        $display("[REFTB-DONE] n=%0d", n);
        $finish;
    end
endmodule
