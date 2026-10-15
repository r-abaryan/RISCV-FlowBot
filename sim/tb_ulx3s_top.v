// M8D proposed minimal board-level smoke test of fpga/ulx3s/ulx3s_top.v (simulation only, no hardware).
// Run from repo root (ROM path in wrapper is repo-root relative). See docs/29.
`timescale 1ns/1ps
module tb_ulx3s_top;
  reg clk=0, btn0=0, sw0=0; wire ftdi_rxd; wire [7:0] led;
  always #20 clk=~clk; // 25 MHz
  ulx3s_top dut(.clk_25mhz(clk),.btn0(btn0),.sw0(sw0),.ftdi_rxd(ftdi_rxd),.led(led));
  integer uart_edges=0, led_edges=0, fails=0, pre_rst_pc_moves=0;
  reg last_tx=1; reg [7:0] last_led=0;
  integer uart_wr=0; // CPU writes to UART register (internal, hierarchical)
  always @(posedge clk) begin
    if (ftdi_rxd===1'b0 && last_tx===1'b1) uart_edges<=uart_edges+1; last_tx<=ftdi_rxd;
    if (led!==last_led) led_edges<=led_edges+1; last_led<=led;
    if (dut.u_soc.u_uart.wb_cyc_i && dut.u_soc.u_uart.wb_stb_i && dut.u_soc.u_uart.wb_we_i && !dut.u_soc.u_uart.wb_ack_o && dut.u_soc.u_uart.wb_adr_i[7:0]==0) uart_wr<=uart_wr+1;
  end
  task chk(input ok, input [511:0] name); begin
    if (ok) $display("[PASS] %0s", name); else begin $display("[FAIL] %0s", name); fails=fails+1; end end endtask
  initial begin
    repeat (50) @(posedge clk);
    chk(led[0]===1'b1, "reset+estop held: disarm LED on");
    chk(dut.u_soc.u_cpu.picorv32_core.mem_valid!==1'b1 || dut.rst_n_s===1'b0, "CPU idle in reset");
    btn0=1; sw0=1;                      // release reset, E-stop DIP "on" (polarity assumed)
    repeat (80000) @(posedge clk);    // 3.2 ms (firmware needs ~45k cycles)
    chk(ftdi_rxd===1'b1, "ftdi_rxd idle-high");
    chk(uart_wr>0, "firmware wrote UART data register");
    chk(led_edges>0, "LED activity after release");
    // KNOWN GAP (docs/29): pin never serialises; uart_edges counts falling edges (start bits) = 0.
    chk(uart_edges==0, "KNOWN GAP: no UART start bit on pin");
    $display("uart_wr=%0d uart_edges=%0d led_edges=%0d led=%b", uart_wr, uart_edges, led_edges, led);
    $display("fails=%0d", fails); $finish;
  end
endmodule
