// M8E unit test of soc_uart (8N1 TX, busy/overrun semantics). Fast divider (CLKS_PER_BIT=8).
`timescale 1ns/1ps
module tb_soc_uart;
  localparam B = 8;
  reg clk=0, rst_n=0; always #5 clk=~clk;
  reg [31:0] adr=0, dat=0; reg we=0, stb=0; wire [31:0] rdat; wire ack; wire tx;
  soc_uart #(.CLKS_PER_BIT(B)) dut(.clk(clk),.rst_n(rst_n),.wb_adr_i(adr),.wb_dat_i(dat),.wb_dat_o(rdat),
    .wb_we_i(we),.wb_sel_i(4'hF),.wb_stb_i(stb),.wb_cyc_i(stb),.wb_ack_o(ack),.uart_tx(tx));
  integer fails=0;
  task chk(input ok, input [8*56-1:0] n); begin if(!ok) begin fails=fails+1; $display("[FAIL] %0s",n); end else $display("[PASS] %0s",n); end endtask
  reg [31:0] rd;
  task bus(input w, input [31:0] a, input [31:0] d); begin
    @(posedge clk); adr<=a; dat<=d; we<=w; stb<=1;
    @(posedge clk); while(!ack) @(posedge clk);
    stb<=0; we<=0; @(posedge clk); rd=rdat; end endtask
  // monitor: decode frames
  reg [7:0] got [0:15]; integer ngot=0, frame_err=0, tstart; reg [7:0] sh; integer i;
  initial forever begin
    @(negedge tx); tstart=$time;
    #(B*10/2*1); // mid start bit (clk period 10ns)
    if (tx!==1'b0) frame_err=frame_err+1;
    for (i=0;i<8;i=i+1) begin #(B*10); sh[i]=tx; end
    #(B*10); if (tx!==1'b1) frame_err=frame_err+1;
    got[ngot]=sh; ngot=ngot+1;
    if (($time-tstart) < (B*10*9)) frame_err=frame_err+1;
  end
  integer t0;
  initial begin
    #3; chk(tx===1'b1,"line idle high in reset");
    #50 rst_n=1; repeat(3)@(posedge clk);
    bus(0,32'h04,0); chk(rd[0]===1 && rd[1]===0,"STATUS ready, no overrun after reset");
    bus(0,32'h08,0); chk(rd[0]===0,"TX_BUSY=0 idle");
    bus(1,32'h00,32'h55); bus(0,32'h04,0); chk(rd[0]===0,"STATUS not ready after write");
    bus(0,32'h08,0); chk(rd[0]===1,"TX_BUSY=1 (alias)");
    // write while busy: dropped
    bus(1,32'h00,32'hAA); bus(0,32'h04,0); chk(rd[1]===1,"OVERRUN set by write while busy");
    bus(0,32'h00,0); chk(rd[7:0]===8'h55,"TXDATA readback keeps accepted byte (dropped write ignored)");
    bus(1,32'h04,32'h2); bus(0,32'h04,0); chk(rd[1]===0,"OVERRUN cleared by W1C");
    bus(1,32'h04,32'h0);
    t0=0; rd=0; while (!rd[0] && t0<1000) begin bus(0,32'h04,0); t0=t0+1; end
    chk(rd[0]===1,"READY returns after frame");
    repeat(2*B) @(posedge clk);
    chk(ngot===1 && got[0]===8'h55,"exactly one frame, 0x55 (dropped 0xAA absent)");
    // back-to-back with polling: 4 bytes incl. 0x00 and 0xFF
    begin : seq
      integer k; reg [7:0] v [0:3];
      v[0]=8'h53; v[1]=8'h00; v[2]=8'hFF; v[3]=8'h0A;
      for (k=0;k<4;k=k+1) begin
        rd=1; while(rd[0]) bus(0,32'h08,0); // poll TX_BUSY until 0
        bus(1,32'h00,{24'h0,v[k]});
      end
    end
    repeat(12*B) @(posedge clk);
    chk(ngot===5 && got[1]===8'h53 && got[2]===8'h00 && got[3]===8'hFF && got[4]===8'h0A,"polled back-to-back bytes in order");
    chk(frame_err===0,"all frames: start=0, stop=1, >=9 bit times");
    // reset mid-frame
    bus(1,32'h00,32'h81); repeat(B*3) @(posedge clk);
    rst_n=0; #1; chk(tx===1'b1,"reset mid-frame forces line high");
    #20 rst_n=1; repeat(3)@(posedge clk);
    bus(0,32'h04,0); chk(rd[0]===1 && rd[1]===0,"ready/clean after reset mid-frame");
    repeat(20*B) @(posedge clk);
    chk(fails===0,"summary");
    $display("fails=%0d",fails); $finish;
  end
endmodule
