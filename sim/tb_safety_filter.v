// ============================================================================
// Testbench: tb_safety_filter
// Description: Verification testbench for the hardware safety interlock module
// ============================================================================

`timescale 1ns / 1ps

module tb_safety_filter;

    reg        clk;
    reg        rst_n;
    reg        bus_req;
    reg        bus_we;
    reg [31:0] bus_addr;
    reg [31:0] bus_wdata;
    reg [3:0]  bus_wstrb;
    wire [31:0] bus_rdata;
    wire       bus_ready;

    reg        pin_estop_button;
    wire       actuator_disarm;

    // Instantiate safety filter
    safety_filter dut (
        .clk(clk),
        .rst_n(rst_n),
        .bus_req(bus_req),
        .bus_we(bus_we),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_wstrb(bus_wstrb),
        .bus_rdata(bus_rdata),
        .bus_ready(bus_ready),
        .pin_estop_button(pin_estop_button),
        .actuator_disarm(actuator_disarm)
    );

    // Clock Generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // Bus write helper task
    task bus_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            bus_req   <= 1'b1;
            bus_we    <= 1'b1;
            bus_addr  <= addr;
            bus_wdata <= data;
            bus_wstrb <= 4'b1111;
            @(posedge clk);
            while (!bus_ready) @(posedge clk);
            bus_req   <= 1'b0;
            bus_we    <= 1'b0;
        end
    endtask

    // Bus read helper task
    task bus_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            bus_req   <= 1'b1;
            bus_we    <= 1'b0;
            bus_addr  <= addr;
            bus_wstrb <= 4'b0000;
            @(posedge clk);
            while (!bus_ready) @(posedge clk);
            data = bus_rdata;
            bus_req   <= 1'b0;
        end
    endtask

    reg [31:0] rdata;

    initial begin
        $dumpfile("tb_safety_filter.vcd");
        $dumpvars(0, tb_safety_filter);

        clk              = 0;
        rst_n            = 0;
        bus_req          = 0;
        bus_we           = 0;
        bus_addr         = 32'd0;
        bus_wdata        = 32'd0;
        bus_wstrb        = 4'd0;
        pin_estop_button = 0;

        $display("=== TB_SAFETY_FILTER: Starting Test ===");

        // Reset phase
        #50;
        if (actuator_disarm !== 1'b1) begin
            $display("ERROR: Actuator must be disarmed during reset!");
            $finish;
        end

        // Deassert reset
        rst_n = 1;
        #40;

        // Immediately after reset, countdown is 2,500,000, not tripped, not estop -> actuator_disarm should be 0
        if (actuator_disarm !== 1'b0) begin
            $display("ERROR: Actuator should be armed after successful reset (disarm=0)!");
            $finish;
        end
        $display("[PASS] Reset sequence verified. Actuator armed.");

        // Configure shorter watchdog timeout for fast simulation (100 cycles)
        bus_write(32'h5000060C, 32'd100);
        bus_write(32'h50000604, 32'h5AFE_C0DE); // Heartbeat refresh

        bus_read(32'h50000604, rdata);
        $display("[Info] Watchdog countdown after refresh: %d", rdata);
        if (rdata > 32'd100) begin
            $display("ERROR: Timeout countdown did not reload correctly!");
            $finish;
        end

        // Send heartbeats every 40 cycles - verify actuator remains armed
        repeat (3) begin
            #800; // 40 cycles
            if (actuator_disarm !== 1'b0) begin
                $display("ERROR: Actuator tripped prematurely during regular heartbeats!");
                $finish;
            end
            bus_write(32'h50000604, 32'h5AFE_C0DE);
        end
        $display("[PASS] Heartbeat refresh maintains armed state.");

        // Now test watchdog timeout by letting it expire
        $display("[Test] Allowing watchdog to time out...");
        #2500; // 125 cycles > 100 cycles
        bus_read(32'h50000608, rdata);
        $display("[Info] Safety status reg: 0x%08x", rdata);
        if (actuator_disarm !== 1'b1) begin
            $display("ERROR: Actuator failed to disarm after watchdog timeout!");
            $finish;
        end
        if (rdata[1] !== 1'b1 || rdata[2] !== 1'b1) begin
            $display("ERROR: Status flags did not record watchdog trip!");
            $finish;
        end
        $display("[PASS] Watchdog expiration successfully disarmed actuator!");

        // Test clearing trip via CTRL register (bit 1 = clear trip)
        $display("[Test] Clearing trip condition via bus...");
        bus_write(32'h50000600, 32'h00000003); // Enable + Clear trip
        #40;
        if (actuator_disarm !== 1'b0) begin
            $display("ERROR: Actuator remained disarmed after clearing trip!");
            $finish;
        end
        $display("[PASS] Trip successfully cleared.");

        // Test Physical Emergency Stop (E-Stop) Bumper
        $display("[Test] Asserting external physical E-Stop bumper...");
        @(posedge clk);
        pin_estop_button = 1'b1;
        #1;
        if (actuator_disarm !== 1'b1) begin
            $display("ERROR: Hardware E-Stop pin must instantly disarm actuators!");
            $finish;
        end
        @(posedge clk);
        pin_estop_button = 1'b0;
        #20;
        // Even after button release, actuator must remain locked out until explicit software reset
        if (actuator_disarm !== 1'b1) begin
            $display("ERROR: E-Stop trip must latch until software re-arms!");
            $finish;
        end
        $display("[PASS] Physical E-Stop latch and lockout verified!");

        // Re-arm
        bus_write(32'h50000600, 32'h00000003);
        #40;
        if (actuator_disarm !== 1'b0) begin
            $display("ERROR: Failed to rearm after E-Stop release!");
            $finish;
        end
        $display("[PASS] System successfully re-armed.");

        $display("=== TB_SAFETY_FILTER: ALL TESTS PASSED SUCCESSFULLY! ===");
        $finish;
    end

endmodule
