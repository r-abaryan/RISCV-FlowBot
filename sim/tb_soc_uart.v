// Unit testbench for rtl/periph/soc_uart.v (D-B register map), UART_CLKS_PER_BIT = 8.
// Simulation only. Run: make -C sim test_uart
`timescale 1ns/1ps
module tb_soc_uart;
  localparam D = 8;
  reg clk=0, rst_n=0; always #5 clk=~clk;
  reg [31:0] adr=0, dat=0; reg we=0, stb=0; wire [31:0] rdat; wire ack, tx;
  soc_uart #(.UART_CLKS_PER_BIT(D)) dut(.clk(clk),.rst_n(rst_n),.wb_adr_i(adr),.wb_dat_i(dat),
    .wb_dat_o(rdat),.wb_we_i(we),.wb_sel_i(4'hF),.wb_stb_i(stb),.wb_cyc_i(stb),.wb_ack_o(ack),.uart_tx(tx));
  integer fails=0; reg [31:0] r;
  integer cyc=0; always @(posedge clk) cyc<=cyc+1;
  task chk(input ok, input [511:0] n); begin
    if (ok) $display("[PASS] %0s", n); else begin $display("[FAIL] %0s", n); fails=fails+1; end end endtask
  task wr(input [7:0] a, input [31:0] d); begin
    @(posedge clk); #1 adr=a; dat=d; we=1; stb=1;
    @(posedge clk); while (!ack) @(posedge clk); #1 stb=0; we=0; end endtask
  task rd(input [7:0] a, output [31:0] d); begin
    @(posedge clk); #1 adr=a; we=0; stb=1;
    @(posedge clk); while (!ack) @(posedge clk); d=rdat; #1 stb=0; end endtask
  // pin monitor: decode 8N1 frames
  reg [7:0] got [0:15]; integer ng=0; integer frame_err=0; integer k; reg [7:0] sh;
  reg mon_en=1;
  initial forever begin
    @(negedge tx);
    if (mon_en) begin
      repeat (D/2) @(posedge clk);
      if (tx!==1'b0) frame_err=frame_err+1;
      sh=0;
      for (k=0;k<8;k=k+1) begin repeat (D) @(posedge clk); sh[k]=tx; end
      repeat (D) @(posedge clk);
      if (tx!==1'b1) frame_err=frame_err+1;
      got[ng]=sh; ng=ng+1;
    end
  end
  integer tw, n;
  initial begin
    repeat (4) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);
    chk(tx===1'b1, "idle high after reset");
    rd(8'h08,r); chk(r===32'h0, "STATUS idle = 0");
    rd(8'h04,r); chk(r===32'h0, "RXDATA reads 0");
    rd(8'h00,r); chk(r===32'h0, "TXDATA reads 0");
    wr(8'h0C,32'h1234); rd(8'h0C,r); chk(r===32'h0, "BAUD write ignored, reads 0");
    // --- normal byte: busy timing + frame bits
    wr(8'h00,32'hA5); tw=cyc;
    rd(8'h08,r); chk(r[0]===1'b1 && r[2]===1'b0, "busy after TXDATA write, no overrun");
    r=1; while (r[0]) rd(8'h08,r);
    n=cyc-tw; $display("busy duration ~%0d cycles (frame = %0d)", n, 10*D);
    chk(n>=10*D-2 && n<=10*D+8, "busy lasts ~10 bit times");
    repeat (D) @(posedge clk);
    chk(ng==1 && got[0]===8'hA5 && frame_err==0, "frame decoded 0xA5 8N1 (start/stop ok)");
    // --- back-to-back with polling: no loss
    for (n=0;n<3;n=n+1) begin r=1; while (r[0]) rd(8'h08,r); wr(8'h00,32'h30+n); end
    r=1; while (r[0]) rd(8'h08,r); repeat (D) @(posedge clk);
    chk(ng==4 && got[1]===8'h30 && got[2]===8'h31 && got[3]===8'h32 && frame_err==0, "polled back-to-back bytes 0x30..0x32 intact");
    rd(8'h08,r); chk(r[2]===1'b0, "no overrun when polling");
    // --- write while busy: dropped, overrun set
    wr(8'h00,32'h41); wr(8'h00,32'h42);   // 2nd arrives while busy
    rd(8'h08,r); chk(r[2]===1'b1 && r[0]===1'b1, "busy-write sets sticky overrun");
    r=1; while (r[0]) rd(8'h08,r); repeat (D) @(posedge clk);
    chk(ng==5 && got[4]===8'h41 && frame_err==0, "dropped byte not transmitted; first byte intact");
    rd(8'h08,r); chk(r[2]===1'b1 && r[0]===1'b0, "overrun stays sticky after idle");
    // --- W1C: writing 0 does not clear, writing 1 clears; other bits ignored
    wr(8'h08,32'h0); rd(8'h08,r); chk(r[2]===1'b1, "STATUS write of 0 does not clear");
    wr(8'h08,32'h4); rd(8'h08,r); chk(r[2]===1'b0, "W1C clears overrun");
    // --- clear colliding with busy-write: overrun stays set
    wr(8'h00,32'h51);
    wr(8'h00,32'h52);                       // dropped -> overrun
    wr(8'h08,32'h4); rd(8'h08,r);           // clear while busy, no coincident drop
    chk(r[2]===1'b0, "W1C while busy clears (no coincident drop)");
    wr(8'h00,32'h53); rd(8'h08,r); chk(r[2]===1'b1, "drop after clear re-sets overrun");
    wr(8'h08,32'h4);
    // coincident clear+drop cannot occur on single-master bus (one request/cycle);
    // verify priority via forced stimulus: hold the clear and drop in the same request is impossible,
    // so check by hierarchical force of the decode signals.
    force dut.drop_wr = 1'b1; force dut.clr_ovr = 1'b1; @(posedge clk); #1;
    release dut.drop_wr; release dut.clr_ovr;
    rd(8'h08,r); chk(r[2]===1'b1, "coincident clear+drop: overrun stays set (forced)");
    r=1; while (r[0]) rd(8'h08,r); wr(8'h08,32'h4);
    // --- reset mid-frame
    repeat (D) @(posedge clk);
    mon_en=0;
    wr(8'h00,32'h55); repeat (3*D) @(posedge clk);
    wr(8'h00,32'h66);                      // dropped -> overrun
    rd(8'h08,r); chk(r[2]===1'b1 && r[0]===1'b1, "pre-reset: busy+overrun");
    #3 rst_n=0; #1;
    chk(tx===1'b1, "reset mid-frame: tx returns high");
    repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);
    rd(8'h08,r); chk(r===32'h0, "after reset: not busy, overrun cleared");
    repeat (4*D) @(posedge clk); chk(tx===1'b1, "no stale frame after reset");
    mon_en=1; ng=0; frame_err=0;
    wr(8'h00,32'h7E); r=1; while (r[0]) rd(8'h08,r); repeat (D) @(posedge clk);
    chk(ng==1 && got[0]===8'h7E && frame_err==0, "clean frame after reset");
    $display("fails=%0d", fails);
    if (fails==0) $display("TB_SOC_UART PASS"); else $display("TB_SOC_UART FAIL");
    $finish;
  end
  initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
