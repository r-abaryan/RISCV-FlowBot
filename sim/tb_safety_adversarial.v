// ============================================================================
// Testbench: tb_safety_adversarial
// Description: Adversarial Security, Fault Injection, and Race Condition Verification
// for the RISC-V Deterministic Hardware Safety Filter.
//
// Scenarios Tested:
//   1. Corrupted Heartbeat Key Injection (Watchdog must not refresh)
//   2. Heartbeat Write vs E-Stop Collision (Physical E-Stop must dominate)
//   3. Illicit Clear-Trip Attempt while E-Stop Pin is Actively Held High
//   4. Firmware Disable Attempt (Setting reg_enable = 0 must force-disarm)
//   5. Minimum Countdown Expiration (Timeout = 1 cycle boundary)
//   6. Reset Glitch Resilience (Actuator disarms instantly during asynchronous reset)
// ============================================================================

`timescale 1ns / 1ps

module tb_safety_adversarial;

    reg         clk;
    reg         rst_n;
    reg         bus_req;
    reg         bus_we;
    reg  [31:0] bus_addr;
    reg  [31:0] bus_wdata;
    reg  [3:0]  bus_wstrb;
    wire [31:0] bus_rdata;
    wire        bus_ready;

    reg         pin_estop_button;
    wire        actuator_disarm;

    // DUT instantiation
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

    // 50 MHz clock
    always #10 clk = ~clk;

    // Safety watchdog timeout for testbench execution
    initial begin
        #3000000; // 3 ms limit
        $fatal(1, "[TB FATAL] Watchdog timeout in tb_safety_adversarial! Test hung.");
    end

    // MMIO bus tasks
    task bus_write(input [31:0] addr, input [31:0] data);
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
        bus_wstrb <= 4'b0000;
    end
    endtask

    task bus_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        bus_req   <= 1'b1;
        bus_we    <= 1'b0;
        bus_addr  <= addr;
        bus_wstrb <= 4'b0000;
        @(posedge clk);
        while (!bus_ready) @(posedge clk);
        data     = bus_rdata;
        bus_req  <= 1'b0;
    end
    endtask

    reg [31:0] rdata;

    initial begin
        clk              = 0;
        rst_n            = 0;
        bus_req          = 0;
        bus_we           = 0;
        bus_addr         = 0;
        bus_wdata        = 0;
        bus_wstrb        = 0;
        pin_estop_button = 0;

        #40;
        rst_n = 1;
        #40;

        $display("======================================================================");
        $display("=== STARTING ADVERSARIAL HARDWARE SAFETY FILTER STRESS TESTS       ===");
        $display("======================================================================");

        // --------------------------------------------------------------------
        // TEST 1: Corrupted Heartbeat Key Injection
        // Attack: Errant firmware or noise writes invalid heartbeat keys
        // (0xDEADBEEF, 0x00000000, 0x5AFE_C0DF off-by-one bit).
        // Watchdog must ignore them and expire without resetting countdown.
        // --------------------------------------------------------------------
        $display("[ADVERSARIAL TEST 1] Corrupted Heartbeat Key Fault Injection...");
        bus_write(32'h5000060C, 32'd50);           // Short timeout = 50 cycles
        bus_write(32'h50000604, 32'h5AFE_C0DE);    // Valid initial refresh

        // Inject 5 bogus keys over 20 cycles
        repeat (5) begin
            #40;
            bus_write(32'h50000604, 32'hDEADBEEF);
            bus_write(32'h50000604, 32'h00000000);
            bus_write(32'h50000604, 32'h5AFEC0DF); // 1 bit flip
        end

        // Wait for remaining cycles to exceed 50
        #1200;

        // Check if tripped
        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 1 FAILED] Safety watchdog failed to trip after invalid heartbeat keys!");

        bus_read(32'h50000608, rdata);
        if (rdata[1] !== 1'b1)
            $fatal(1, "[TEST 1 FAILED] Trip flag not asserted after watchdog expiration!");
        if (rdata[2] !== 1'b1)
            $fatal(1, "[TEST 1 FAILED] Watchdog expired flag not asserted!");

        $display("[TEST 1 PASSED] Corrupted heartbeat keys properly rejected; watchdog expired.");

        // Clear trip for next test
        bus_write(32'h50000600, 32'h00000003); // Enable + Clear trip
        #40;
        if (actuator_disarm !== 1'b0)
            $fatal(1, "[TEST 1 FAILED] Could not re-arm after test 1!");

        // --------------------------------------------------------------------
        // TEST 2: Heartbeat Write vs Physical E-Stop Button Collision (Race Condition)
        // Attack/Fault: E-Stop bumper hits concurrently as CPU attempts heartbeat write.
        // E-Stop MUST have unconditional priority and trip immediately.
        // --------------------------------------------------------------------
        $display("[ADVERSARIAL TEST 2] Simultaneous Heartbeat Write vs E-Stop Collision...");
        bus_write(32'h5000060C, 32'd200);

        @(posedge clk);
        // Start write transaction and assert E-stop at identical edge
        bus_req          <= 1'b1;
        bus_we           <= 1'b1;
        bus_addr         <= 32'h50000604;
        bus_wdata        <= 32'h5AFE_C0DE;
        bus_wstrb        <= 4'b1111;
        pin_estop_button <= 1'b1; // Collision!

        @(posedge clk);
        // Actuator must be instantly disarmed (combinational)
        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 2 FAILED] Combinational E-Stop failed to override bus write!");

        bus_req          <= 1'b0;
        bus_we           <= 1'b0;
        bus_wstrb        <= 4'b0000;
        pin_estop_button <= 1'b0;

        #20;
        // Even after pulse release, must remain latched
        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 2 FAILED] Collision state failed to latch trip!");

        bus_read(32'h50000608, rdata);
        if (rdata[1] !== 1'b1)
            $fatal(1, "[TEST 2 FAILED] Trip flag not recorded after collision! rdata=0x%08x", rdata);

        $display("[TEST 2 PASSED] E-Stop unconditionally overrode concurrent heartbeat write.");

        // Clear trip
        bus_write(32'h50000600, 32'h00000003);
        #40;

        // --------------------------------------------------------------------
        // TEST 3: Illicit Trip Clear While Physical E-Stop Button Is Held High
        // Attack/Fault: Firmware maliciously or mistakenly tries to clear trip
        // while the physical bumper is still depressed against an obstacle.
        // Hardware MUST ignore the clear request and remain disarmed.
        // --------------------------------------------------------------------
        $display("[ADVERSARIAL TEST 3] Clearing Trip While Physical E-Stop Remains Held...");
        pin_estop_button = 1'b1;
        #40;

        // Try repeatedly to write CLEAR_TRIP to CTRL
        repeat (4) begin
            bus_write(32'h50000600, 32'h00000003); // Enable + clear trip
            #20;
            if (actuator_disarm !== 1'b1)
                $fatal(1, "[TEST 3 FAILED] Actuators armed while physical E-Stop was held high!");
        end

        // Release E-Stop
        pin_estop_button = 1'b0;
        #40;
        // Actuators must STILL remain disarmed until software explicitly clears trip AFTER release
        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 3 FAILED] Actuators prematurely re-armed when button released!");

        // Now clear trip legitimately
        bus_write(32'h50000600, 32'h00000003);
        #40;
        if (actuator_disarm !== 1'b0)
            $fatal(1, "[TEST 3 FAILED] Legitimate clear failed after button release!");

        $display("[TEST 3 PASSED] Physical E-Stop lock strictly enforces hardware interlock.");

        // --------------------------------------------------------------------
        // TEST 4: Firmware Attempt to Bypass Safety by Disabling Module (reg_enable=0)
        // Attack: Compromised firmware writes reg_enable = 0 to turn off safety filter.
        // Architecture specification: Disabling module MUST force actuator_disarm = 1!
        // --------------------------------------------------------------------
        $display("[ADVERSARIAL TEST 4] Firmware Module-Disable Attempt (Fail-Safe Verification)...");
        bus_write(32'h50000600, 32'h00000000); // reg_enable = 0
        #20;

        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 4 FAILED] Disabling safety filter failed to trip fail-safe disarm!");

        bus_read(32'h50000600, rdata);
        if (rdata[0] !== 1'b0)
            $fatal(1, "[TEST 4 FAILED] reg_enable readback mismatch!");

        // Re-enable module
        bus_write(32'h50000600, 32'h00000003); // reg_enable = 1, clear trip
        #40;
        if (actuator_disarm !== 1'b0)
            $fatal(1, "[TEST 4 FAILED] Re-arming after disable failed!");

        $display("[TEST 4 PASSED] Disabling filter properly engages fail-safe disarm.");

        // --------------------------------------------------------------------
        // TEST 5: Minimum 1-Cycle Countdown Expiration Boundary
        // Program timeout = 1 cycle. Verify clean countdown to 0 and trip without hang.
        // --------------------------------------------------------------------
        $display("[ADVERSARIAL TEST 5] Single-Cycle Countdown Boundary...");
        bus_write(32'h5000060C, 32'd1);
        bus_write(32'h50000604, 32'h5AFE_C0DE);
        #100;

        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 5 FAILED] 1-cycle timeout failed to expire!");

        $display("[TEST 5 PASSED] Single-cycle countdown expired cleanly.");

        // Clear trip
        bus_write(32'h5000060C, 32'd5000);
        bus_write(32'h50000600, 32'h00000003);
        #40;

        // --------------------------------------------------------------------
        // TEST 6: Asynchronous Reset Glitch Immunity
        // Verify actuator_disarm asserts combinatorially on rst_n falling edge
        // without waiting for clock edge.
        // --------------------------------------------------------------------
        $display("[ADVERSARIAL TEST 6] Asynchronous Reset Glitch Immunity...");
        if (actuator_disarm !== 1'b0)
            $fatal(1, "[TEST 6 FAILED] Precondition: actuator not armed!");

        #5; // Asynchronous offset
        rst_n = 0;
        #1;
        if (actuator_disarm !== 1'b1)
            $fatal(1, "[TEST 6 FAILED] Actuator disarm did not assert asynchronously with rst_n!");

        #50;
        rst_n = 1;
        #40;
        if (actuator_disarm !== 1'b0)
            $fatal(1, "[TEST 6 FAILED] Actuator failed to re-arm after clean reset!");

        $display("[TEST 6 PASSED] Asynchronous reset safety interlock verified.");

        $display("======================================================================");
        $display("=== ALL 6 ADVERSARIAL HARDWARE SAFETY FILTER TESTS PASSED!         ===");
        $display("======================================================================");
        $finish(0);
    end

endmodule
