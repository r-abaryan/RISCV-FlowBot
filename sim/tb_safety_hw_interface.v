// M7A: register-level tests of safety_filter as the firmware sees it.
// Uses the same offsets as sw/firmware/soc_regs.h. Exits nonzero ($fatal) on failure.
`timescale 1ns / 1ps
module tb_safety_hw_interface;
    reg clk=0, rst_n=0, bus_req=0, bus_we=0; reg [31:0] bus_addr=0, bus_wdata=0; reg [3:0] bus_wstrb=0;
    wire [31:0] bus_rdata; wire bus_ready; reg estop=0; wire disarm;
    safety_filter dut(.clk(clk),.rst_n(rst_n),.bus_req(bus_req),.bus_we(bus_we),.bus_addr(bus_addr),
        .bus_wdata(bus_wdata),.bus_wstrb(bus_wstrb),.bus_rdata(bus_rdata),.bus_ready(bus_ready),
        .pin_estop_button(estop),.actuator_disarm(disarm));
    always #10 clk=~clk;
    localparam CTRL=32'h50000600, HB=32'h50000604, STAT=32'h50000608, TMO=32'h5000060C, KEY=32'h5AFEC0DE;
    integer errors=0, checks=0; reg [31:0] r; integer i;
    initial begin #5000000; $display("[FATAL] hang"); $fatal(1,"hang"); end
    task wr(input [31:0] a, input [31:0] d); begin
        @(posedge clk); bus_req<=1; bus_we<=1; bus_addr<=a; bus_wdata<=d; bus_wstrb<=4'hF;
        @(posedge clk); bus_req<=0; bus_we<=0; bus_wstrb<=0; end endtask
    task rd(input [31:0] a, output [31:0] d); begin
        @(posedge clk); bus_req<=1; bus_we<=0; bus_addr<=a; @(posedge clk); #1 d=bus_rdata; bus_req<=0; end endtask
    task chk(input [1023:0] name, input cond); begin
        checks=checks+1;
        if (cond) $display("[PASS] %0s", name); else begin errors=errors+1; $display("[FAIL] %0s", name); end end endtask
    initial begin
        repeat(3) @(posedge clk); chk("disarm during reset", disarm===1);
        rst_n=1; @(posedge clk); #1;
        chk("armed after reset (default enable=1)", disarm===0);
        rd(TMO,r); chk("reset TIMEOUT = 2500000", r==2500000);
        rd(CTRL,r); chk("reset CTRL enable bit", r==1);
        rd(STAT,r); chk("reset STATUS = enable only", r==1);

        // Correct bring-up sequence used by firmware: timeout, ctrl enable|clear, heartbeat
        wr(TMO,50); rd(TMO,r); chk("TIMEOUT readback 50", r==50);
        wr(CTRL,3); wr(HB,KEY);
        rd(HB,r); chk("countdown reloaded near timeout", r<=50 && r>=35);
        // regular heartbeats keep armed for 10x timeout
        for (i=0;i<10;i=i+1) begin repeat(30) @(posedge clk); wr(HB,KEY); end
        chk("armed under regular heartbeats", disarm===0);

        // Wrong keys must not refresh
        wr(HB,32'h0); wr(HB,32'h5AFEC0DF); wr(HB,~KEY);
        wr(STAT,KEY); wr(32'h50000610,KEY); // writes to RO / unmapped offset must not refresh
        repeat(60) @(posedge clk); #1;
        chk("wrong keys / wrong offsets do not feed watchdog -> trip", disarm===1);
        rd(STAT,r); chk("STATUS tripped+wdt_expired+enable (0x7)", r==32'h7);

        // Heartbeat with correct key after trip must not un-trip
        wr(HB,KEY); repeat(5) @(posedge clk); #1;
        chk("valid heartbeat does not clear latched trip", disarm===1);
        // Supported recovery: CTRL enable|clear
        wr(CTRL,3); #1;
        chk("recovery via CTRL=3 re-arms", disarm===0);
        rd(STAT,r); chk("STATUS cleared after recovery", r==32'h1);
        // CTRL=1 alone (no clear) must not clear a trip
        repeat(80) @(posedge clk); #1; chk("tripped again without heartbeat", disarm===1);
        wr(CTRL,1); #1; chk("CTRL=1 (no clear bit) does not recover", disarm===1);
        wr(CTRL,3); wr(HB,KEY);

        // Software disable is fail-safe
        wr(CTRL,0); #1; chk("CTRL enable=0 disarms actuators", disarm===1);
        rd(STAT,r); chk("STATUS enable=0", r[0]==0);
        wr(CTRL,3); wr(HB,KEY); #1; chk("re-enable restores arm", disarm===0);

        // E-stop: combinational, latched, recovery blocked while pressed
        @(posedge clk); estop=1; #1; chk("E-stop pin disarms combinationally", disarm===1);
        rd(STAT,r); chk("STATUS shows estop pin bit3", r[3]==1);
        wr(CTRL,3); #1; chk("clear refused while E-stop pressed", disarm===1);
        @(posedge clk); estop=0; wr(HB,KEY); repeat(3) @(posedge clk); #1;
        chk("E-stop latched after release", disarm===1);
        wr(CTRL,3); wr(HB,KEY); #1; chk("recovery after E-stop release", disarm===0);

        // Timeout register edge cases
        wr(TMO,0); wr(CTRL,3); repeat(4) @(posedge clk); #1;
        chk("TIMEOUT=0 trips immediately (fail-safe)", disarm===1);
        wr(TMO,32'd40); wr(CTRL,3); wr(HB,KEY);
        // Watchdog expires exactly: count how many cycles until trip
        i=0; while (disarm===0 && i<200) begin @(posedge clk); #1; i=i+1; end
        chk("trip latency bounded by timeout+margin", i>=30 && i<=45);
        $display("[Info] trip after %0d cycles with TIMEOUT=40", i);
        // Reset recovers
        rst_n=0; #1; chk("async reset disarms", disarm===1); @(posedge clk); rst_n=1; @(posedge clk); #1;
        chk("reset clears trip", disarm===0);

        $display("checks=%0d errors=%0d", checks, errors);
        if (errors!=0) $fatal(1,"M7A FAILED");
        $display("=== TB_SAFETY_HW_INTERFACE: ALL PASSED ===");
        $finish(0);
    end
endmodule
