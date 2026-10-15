// M8D proposed minimal board-level smoke test of fpga/ulx3s/ulx3s_top.v (simulation only, no hardware).
// Run from repo root (ROM path in wrapper is repo-root relative). See docs/29.
`timescale 1ns/1ps
module tb_ulx3s_top;
  reg clk=0, btn0=0, sw0=0; wire ftdi_rxd; wire [7:0] led;
  always #20 clk=~clk; // 25 MHz
  ulx3s_top dut(.clk_25mhz(clk),.btn0(btn0),.sw0(sw0),.ftdi_rxd(ftdi_rxd),.led(led));
  localparam BIT = 217;            // clk cycles per bit, must match soc_uart default
  localparam NEXP = 148;           // msg_boot length in robot_nav_firmware.s
  integer led_edges=0, fails=0, uart_wr=0, nbytes=0, frame_err=0, busy_wr=0, in_rst_edges=0;
  reg last_tx=1; reg [7:0] last_led=0;
  reg [7:0] rx [0:511]; reg [7:0] sh; integer i, gap;
  reg [8*160-1:0] expect_s;
  reg [7:0] exp_b [0:NEXP-1];
  reg decoding=0;
  // Independent UART receiver on the physical pin (mid-bit sampling).
  initial begin : rxloop
    forever begin
      @(negedge ftdi_rxd); decoding=1;
      repeat (BIT/2) @(posedge clk);
      if (ftdi_rxd!==1'b0) frame_err=frame_err+1;
      for (i=0;i<8;i=i+1) begin repeat (BIT) @(posedge clk); sh[i]=ftdi_rxd; end
      repeat (BIT) @(posedge clk);
      if (ftdi_rxd!==1'b1) frame_err=frame_err+1;
      rx[nbytes]=sh; nbytes=nbytes+1; decoding=0;
    end
  end
  always @(posedge clk) begin
    if (led!==last_led) led_edges<=led_edges+1; last_led<=led;
    if (dut.u_soc.u_uart.wb_cyc_i && dut.u_soc.u_uart.wb_stb_i && dut.u_soc.u_uart.wb_we_i && !dut.u_soc.u_uart.wb_ack_o && dut.u_soc.u_uart.wb_adr_i[7:0]==0) begin
      uart_wr<=uart_wr+1;
      if (dut.u_soc.u_uart.busy) busy_wr<=busy_wr+1;   // write while busy (firmware must never do this)
    end
  end
  task chk(input ok, input [8*60-1:0] name); begin
    if (ok) $display("[PASS] %0s", name); else begin $display("[FAIL] %0s", name); fails=fails+1; end end endtask
  integer j, mism;
  initial begin
    // "\n=== RISC-V Mobile Robot Navigation SoC Online ===\n[CORE] RV32IM CPU @ 50MHz\n[ACCEL] rv_nna INT8 4-way SIMD\n[SAFETY] Deterministic Interlock Armed\n\n"
    expect_s = 0;
    repeat (50) @(posedge clk);
    chk(led[0]===1'b1, "reset+estop held: disarm LED on");
    chk(ftdi_rxd===1'b1, "ftdi_rxd idle-high in reset");
    chk(dut.u_soc.u_cpu.picorv32_core.mem_valid!==1'b1 || dut.rst_n_s===1'b0, "CPU idle in reset");
    repeat (3*BIT*10) @(posedge clk);
    chk(nbytes==0 && uart_wr==0, "no UART activity while held in reset");
    btn0=1; sw0=1;
    // wait for banner bytes (each 10*BIT cycles)
    j=0; while (nbytes<NEXP && j<(NEXP+20)*10*BIT+200000) begin @(posedge clk); j=j+1; end
    repeat (BIT*2) @(posedge clk);
    chk(nbytes>=NEXP, "received full banner length from ftdi_rxd");
    mism=0;
    for (j=0;j<NEXP;j=j+1) if (rx[j]!==exp_b[j]) mism=mism+1;
    chk(mism==0, "banner bytes and order match msg_boot exactly");
    chk(frame_err==0, "framing: start=0 and stop=1 on every frame");
    chk(busy_wr==0, "firmware never wrote while TX busy");
    chk(dut.u_soc.u_uart.overrun===1'b0, "OVERRUN flag clear");
    chk(led_edges>0, "LED activity after release");
    $display("bytes=%0d uart_wr=%0d led_edges=%0d mism=%0d", nbytes, uart_wr, led_edges, mism);
    // reset behaviour: mid-stream reset, pin must go idle-high and output restart from banner
    btn0=0; repeat (4) @(posedge clk);
    chk(ftdi_rxd===1'b1, "reset mid-transmission forces pin high");
    repeat (10*BIT) @(posedge clk);
    chk(dut.u_soc.u_uart.busy===1'b0, "UART idle while in reset");
    j=nbytes; btn0=1;
    repeat (BIT*10*8) @(posedge clk);
    chk(nbytes>=j+6 && rx[j]===8'h0A && rx[j+1]==="=", "after reset output restarts with banner start");
    $display("fails=%0d", fails); $finish;
  end
  integer q; reg [8*150-1:0] bs;
  initial begin
    bs = "\n=== RISC-V Mobile Robot Navigation SoC Online ===\n[CORE] RV32IM CPU @ 50MHz\n[ACCEL] rv_nna INT8 4-way SIMD\n[SAFETY] Deterministic Interlock Armed\n\n";
    for (q=0;q<NEXP;q=q+1) exp_b[q] = bs[8*(NEXP-1-q) +: 8];
  end
endmodule
