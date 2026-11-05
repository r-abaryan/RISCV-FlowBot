// M11b M2 Stage 1 Step 1b: cycle trace TB for soc_pwm vs the independent contract model
// (sw/test/m2_contract_model.py). SIMULATION ONLY. Makes no pass/fail decision on the DUT:
// sw/test/test_m2_step1b_rtl.py generates the vectors, replays them through the model and compares.
//
// Vector word (64 bit hex, one per clock cycle):
//   [63] rst (rst_n=0 during this cycle, async assert at the falling edge)
//   [62] cyc  [61] stb  [60] we   (raw Wishbone master signals; the generator emits
//        PicoRV32-style transactions: stb/cyc held until the cycle after ACK is seen)
//   [59] disarm_in  [58] estop_in  [57] wdt_trip_in
//   [55:48] byte offset (wb_adr_i = 0x5000_0200 | offset)   [31:0] wb_dat_i
// Inputs change at the falling edge. Per cycle the TB writes one line:
//   PRE  (1 ns before the rising edge, live inputs applied): pins, DIR, EN, monitors, ACK, read data
//   POST (1 ns after the rising edge): registered state.
`timescale 1ns / 1ps
module tb_m2_step1b;
    parameter integer PERIOD = 10;
    parameter integer STALE  = 25;
    parameter integer MAXV   = 1200000;

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
        if (n > MAXV) begin $display("FATAL: N > MAXV"); $fatal(1); end
        for (i = 0; i < n; i = i + 1) vec[i] = 64'hx;
        $readmemh(vfile, vec, 0, n - 1);
        if (^vec[n-1] === 1'bx) begin $display("FATAL: vector file shorter than N"); $fatal(1); end
        fd = $fopen(ofile, "w");
        if (fd == 0) begin $display("FATAL: cannot open OUT"); $fatal(1); end
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            rst_n  = !vec[i][63];
            cyc    = vec[i][62]; stb = vec[i][61]; we = vec[i][60];
            disarm = vec[i][59]; estop = vec[i][58]; wdt = vec[i][57];
            adr    = 32'h5000_0200 | {24'h0, vec[i][55:48]};
            dat    = vec[i][31:0];
            #9;   // 1 ns before the rising edge
            $fwrite(fd, "%0d %0d %0d %0d %0d %h %h %0d %h | ", pl, pr, dl, dr, en, cl, cr, ack, rdat);
            @(posedge clk); #1;
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %h %h %h %h %h %h %h %h %0d %h\n",
                    dut.armed, dut.fault_stale, dut.fault_range, dut.estop_seen, dut.arm_rejected,
                    dut.reject_reason, dut.cmd_l, dut.cmd_r, dut.active_l, dut.active_r,
                    dut.shadow_l, dut.shadow_r, dut.stale_cnt, dut.pwm_counter, ack, rdat);
        end
        $fclose(fd);
        $display("[STEP1B-TB-DONE] n=%0d", n);
        $finish;
    end
endmodule
