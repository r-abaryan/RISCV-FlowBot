// Board-wrapper smoke test of fpga/ulx3s/ulx3s_top.v (simulation only, no hardware).
// Decodes the real ftdi_rxd pin at 217 clocks/bit (115200 baud @ 25 MHz) and checks the boot banner.
// Run from repo root (ROM path in wrapper is repo-root relative): make -C sim test_ulx3s_top
`timescale 1ns/1ps
module tb_ulx3s_top;
  localparam BIT = 217;
  reg clk=0, btn0=0, sw0=0; wire ftdi_rxd; wire [7:0] led;
  always #20 clk=~clk; // 25 MHz
  ulx3s_top dut(.clk_25mhz(clk),.btn0(btn0),.sw0(sw0),.ftdi_rxd(ftdi_rxd),.led(led));
  integer led_edges=0, fails=0, nrx=0, frame_err=0, k;
  reg [7:0] last_led=0, sh; reg mon=0;
  reg [7:0] rx [0:255];
  // expected beginning of robot_nav_firmware banner
  reg [8*51-1:0] exp = "\n=== RISC-V Mobile Robot Navigation SoC Online ===\n";
  integer i, mism;
  always @(posedge clk) begin if (led!==last_led) led_edges<=led_edges+1; last_led<=led; end
  always @(negedge ftdi_rxd) if (mon) begin
    repeat (BIT/2) @(posedge clk);
    if (ftdi_rxd!==1'b0) frame_err=frame_err+1;
    sh=0;
    for (k=0;k<8;k=k+1) begin repeat (BIT) @(posedge clk); sh[k]=ftdi_rxd; end
    repeat (BIT) @(posedge clk);
    if (ftdi_rxd!==1'b1) frame_err=frame_err+1;
    if (nrx<256) rx[nrx]=sh; nrx=nrx+1;
  end
  task chk(input ok, input [511:0] name); begin
    if (ok) $display("[PASS] %0s", name); else begin $display("[FAIL] %0s", name); fails=fails+1; end end endtask
  initial begin
    repeat (50) @(posedge clk);
    chk(led[0]===1'b1, "reset+estop held: disarm LED on");
    chk(ftdi_rxd===1'b1, "ftdi_rxd idle-high in reset");
    btn0=1; sw0=1; mon=1;               // release reset, E-stop DIP "on" (polarity assumed)
    repeat (200000) @(posedge clk);     // 8 ms; 51 banner bytes at 86.8 us each = 4.4 ms
    chk(nrx>=51, "at least 51 bytes decoded from ftdi_rxd pin");
    chk(frame_err==0, "all frames have valid start/stop bits");
    mism=0; for (i=0;i<51;i=i+1) if (rx[i]!==exp[8*(50-i) +: 8]) mism=mism+1;
    chk(mism==0, "first 51 decoded bytes match boot banner line");
    chk(led_edges>0, "LED activity after release");
    $display("nrx=%0d frame_err=%0d mism=%0d led_edges=%0d", nrx, frame_err, mism, led_edges);
    $display("fails=%0d", fails); $finish;
  end
endmodule
