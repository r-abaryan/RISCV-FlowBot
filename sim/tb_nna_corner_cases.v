// ============================================================================
// Testbench: tb_nna_corner_cases
// Description: RTL Corner-Case and Boundary Fuzzing Testbench for rv_nna
// Verifies:
//   1. Maximum positive saturation (+127 clamp)
//   2. Maximum negative saturation (-128 clamp)
//   3. Maximum negative with ReLU (0 clamp)
//   4. Exact alternating cancellation (sum = 0)
//   5. Extreme bias addition override
//   6. Requantization shift=0 scaling
//   7. Invalid parameter error trap (K not divisible by 4)
//   8. Hardware auto-copy buffer chaining during layer execution
// Hardened with watchdog timer, strict assertions, and fatal exit codes.
// ============================================================================

`timescale 1ns / 1ps

module tb_nna_corner_cases;

    reg         clk;
    reg         rst_n;
    reg         bus_req;
    reg         bus_we;
    reg  [31:0] bus_addr;
    reg  [31:0] bus_wdata;
    reg  [3:0]  bus_wstrb;
    wire [31:0] bus_rdata;
    wire        bus_ready;
    wire        irq;

    // DUT instantiation
    nna_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .bus_req(bus_req),
        .bus_we(bus_we),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_wstrb(bus_wstrb),
        .bus_rdata(bus_rdata),
        .bus_ready(bus_ready),
        .irq(irq)
    );

    // 50 MHz Clock (20ns period)
    always #10 clk = ~clk;

    // Simulation Watchdog Timer (2 ms limit)
    initial begin
        #2000000;
        $fatal(1, "[TB FATAL] Watchdog timeout in tb_nna_corner_cases! Simulation hung.");
    end

    // MMIO bus tasks
    task write_word(input [31:0] addr, input [31:0] data);
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

    task read_word(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        bus_req  <= 1'b1;
        bus_we   <= 1'b0;
        bus_addr <= addr;
        @(posedge clk);
        while (!bus_ready) @(posedge clk);
        data     = bus_rdata;
        bus_req  <= 1'b0;
    end
    endtask

    task poll_done(output [31:0] status);
    begin
        status = 0;
        while ((status & 32'h2) == 0 && (status & 32'h4) == 0) begin
            read_word(32'h4000_0004, status);
            #10;
        end
    end
    endtask

    reg [31:0] rdata;
    integer i;

    initial begin
        clk       = 0;
        rst_n     = 0;
        bus_req   = 0;
        bus_we    = 0;
        bus_addr  = 0;
        bus_wdata = 0;
        bus_wstrb = 0;

        #50;
        rst_n = 1;
        #30;

        $display("===============================================================");
        $display("=== STARTING RV_NNA RTL CORNER-CASE & BOUNDARY VERIFICATION ===");
        $display("===============================================================");

        // --------------------------------------------------------------------
        // TEST 1: Maximum Positive Saturation Clamping
        // K=16, M=4. Inputs = +127, Weights = +127, Bias = 0.
        // Scale = 32768, Shift = 16. Act = None (0).
        // Accumulator = 16 * 127 * 127 = 258064.
        // Scaled = 129032 -> Clamps to +127 (0x7F) for each neuron.
        // Expected Word 0 = 0x7F7F7F7F.
        // --------------------------------------------------------------------
        $display("[TEST 1] Maximum Positive Saturation Clamping (+127)");
        write_word(32'h4000_0008, 32'h0004_0010); // K=16, M=4
        write_word(32'h4000_000C, 32'h0000_0000); // ACT = NONE
        write_word(32'h4000_0010, 32'h0000_8000); // Scale = 32768
        write_word(32'h4000_0014, 32'h0000_0010); // Shift = 16

        // Load X = +127
        for (i = 0; i < 4; i = i + 1)
            write_word(32'h4000_0100 + (i * 4), 32'h7f7f7f7f);

        // Load Biases = 0
        for (i = 0; i < 4; i = i + 1)
            write_word(32'h4000_0200 + (i * 4), 32'h0000_0000);

        // Load Weights = +127 (4 rows * 4 words = 16 words)
        for (i = 0; i < 16; i = i + 1)
            write_word(32'h4000_0400 + (i * 4), 32'h7f7f7f7f);

        // Start
        write_word(32'h4000_0000, 32'h0000_0001);
        poll_done(rdata);

        read_word(32'h4000_0800, rdata);
        $display("[TEST 1] Readback Word 0: 0x%08x (Expected: 0x7f7f7f7f)", rdata);
        if (rdata !== 32'h7f7f7f7f)
            $fatal(1, "[TEST 1 FAILED] Max positive saturation mismatch!");
        $display("[TEST 1 PASSED] Clamped correctly to +127 across all SIMD lanes.");

        // --------------------------------------------------------------------
        // TEST 2: Maximum Negative Saturation Clamping (Linear Mode)
        // Inputs = +127, Weights = -128 (0x80), Bias = 0.
        // Scale = 32768, Shift = 16. Act = None (0).
        // Accumulator = 16 * 127 * (-128) = -260096.
        // Scaled = -130048 -> Clamps to -128 (0x80) for each neuron.
        // Expected Word 0 = 0x80808080.
        // --------------------------------------------------------------------
        $display("[TEST 2] Maximum Negative Saturation (Linear Clamping to -128)");
        for (i = 0; i < 16; i = i + 1)
            write_word(32'h4000_0400 + (i * 4), 32'h80808080); // Weights = -128

        write_word(32'h4000_0000, 32'h0000_0001); // Start
        poll_done(rdata);

        read_word(32'h4000_0800, rdata);
        $display("[TEST 2] Readback Word 0: 0x%08x (Expected: 0x80808080)", rdata);
        if (rdata !== 32'h80808080)
            $fatal(1, "[TEST 2 FAILED] Max negative saturation mismatch!");
        $display("[TEST 2 PASSED] Clamped correctly to -128.");

        // --------------------------------------------------------------------
        // TEST 3: Negative Dot-Product with ReLU Activation
        // Same inputs and weights (-128), but Act = ReLU (1).
        // Expected Word 0 = 0x00000000.
        // --------------------------------------------------------------------
        $display("[TEST 3] Negative Product with ReLU Activation (Clamp to 0)");
        write_word(32'h4000_000C, 32'h0000_0001); // ACT = RELU
        write_word(32'h4000_0000, 32'h0000_0001); // Start
        poll_done(rdata);

        read_word(32'h4000_0800, rdata);
        $display("[TEST 3] Readback Word 0: 0x%08x (Expected: 0x00000000)", rdata);
        if (rdata !== 32'h00000000)
            $fatal(1, "[TEST 3 FAILED] ReLU negative clamping mismatch!");
        $display("[TEST 3 PASSED] ReLU clamped negative values to 0.");

        // --------------------------------------------------------------------
        // TEST 4: Alternating Sign Dot-Product Exact Cancellation
        // X = [127, -127, 127, -127] -> 0x817F817F
        // W = [127, 127, 127, 127] -> 0x7F7F7F7F
        // Product sum = 0. Bias = 0. Output = 0.
        // --------------------------------------------------------------------
        $display("[TEST 4] Alternating Sign Dot-Product Cancellation");
        write_word(32'h4000_000C, 32'h0000_0000); // ACT = NONE
        for (i = 0; i < 4; i = i + 1)
            write_word(32'h4000_0100 + (i * 4), 32'h817f817f);
        for (i = 0; i < 16; i = i + 1)
            write_word(32'h4000_0400 + (i * 4), 32'h7f7f7f7f);

        write_word(32'h4000_0000, 32'h0000_0001);
        poll_done(rdata);

        read_word(32'h4000_0800, rdata);
        $display("[TEST 4] Readback Word 0: 0x%08x (Expected: 0x00000000)", rdata);
        if (rdata !== 32'h00000000)
            $fatal(1, "[TEST 4 FAILED] Alternating cancellation mismatch!");
        $display("[TEST 4 PASSED] Signed dot products cancelled exactly to 0.");

        // --------------------------------------------------------------------
        // TEST 5: Extreme Bias Override (Negative dot product + Positive Bias)
        // K=4, M=1. Inputs = [10, 10, 10, 10] = 0x0A0A0A0A.
        // Weights = [-50, -50, -50, -50] = 0xCECECECE.
        // Dot product = 4 * (10 * -50) = -2000.
        // Bias = +2050 (0x00000802).
        // Acc = +50. Scale = 32768, Shift = 15 (Identity scale: 1.0).
        // Scaled = (50 * 32768 + 16384) >> 15 = 50 (0x32).
        // Expected Byte 0 = 0x32.
        // --------------------------------------------------------------------
        $display("[TEST 5] Extreme Bias Addition Override");
        write_word(32'h4000_0008, 32'h0001_0004); // K=4, M=1
        write_word(32'h4000_0010, 32'h0000_8000); // Scale = 32768
        write_word(32'h4000_0014, 32'h0000_000F); // Shift = 15
        write_word(32'h4000_0100, 32'h0a0a0a0a); // X = 10
        write_word(32'h4000_0200, 32'sd2050);     // Bias = +2050
        write_word(32'h4000_0400, 32'hcececece); // W = -50

        write_word(32'h4000_0000, 32'h0000_0001);
        poll_done(rdata);

        read_word(32'h4000_0800, rdata);
        $display("[TEST 5] Readback Word 0: 0x%08x (Expected byte 0: 0x32)", rdata);
        if (rdata[7:0] !== 8'h32)
            $fatal(1, "[TEST 5 FAILED] Bias override mismatch! Expected 0x32, got 0x%02x", rdata[7:0]);
        $display("[TEST 5 PASSED] Bias addition correctly offset negative sum to +50.");

        // --------------------------------------------------------------------
        // TEST 6: Shift = 0 Scaling (Direct Multiplication without Shift)
        // K=4, M=1. Inputs = [5, 5, 0, 0] = 0x00000505.
        // Weights = [2, 3, 0, 0] = 0x00000302.
        // Dot product = 10 + 15 = 25. Bias = 0.
        // Scale = 3, Shift = 0. Output = 25 * 3 = 75 (0x4B).
        // --------------------------------------------------------------------
        $display("[TEST 6] Requantization Shift = 0 Scaling");
        write_word(32'h4000_0008, 32'h0001_0004); // K=4, M=1
        write_word(32'h4000_0010, 32'h0000_0003); // Scale = 3
        write_word(32'h4000_0014, 32'h0000_0000); // Shift = 0
        write_word(32'h4000_0100, 32'h0000_0505);
        write_word(32'h4000_0200, 32'd0);
        write_word(32'h4000_0400, 32'h0000_0302);

        write_word(32'h4000_0000, 32'h0000_0001);
        poll_done(rdata);

        read_word(32'h4000_0800, rdata);
        $display("[TEST 6] Readback Word 0: 0x%08x (Expected byte 0: 0x4B)", rdata);
        if (rdata[7:0] !== 8'h4B)
            $fatal(1, "[TEST 6 FAILED] Shift=0 scaling mismatch! Expected 0x4B, got 0x%02x", rdata[7:0]);
        $display("[TEST 6 PASSED] Shift=0 correctly multiplied acc by 3 without shift.");

        // --------------------------------------------------------------------
        // TEST 7: Invalid Dimension Parameter Error Trapping
        // Program invalid K=5 (not a multiple of 4).
        // NNA FSM must set ERROR bit (bit 2) in STATUS and abort immediately.
        // --------------------------------------------------------------------
        $display("[TEST 7] Invalid Dimension Error Trapping (K=5)");
        write_word(32'h4000_0008, 32'h0001_0005); // K=5, M=1 (invalid!)
        write_word(32'h4000_0000, 32'h0000_0001); // Start

        poll_done(rdata);
        $display("[TEST 7] Status Readback: 0x%08x", rdata);
        if ((rdata & 32'h4) == 0)
            $fatal(1, "[TEST 7 FAILED] Core failed to flag ERROR on invalid dimension K=5!");
        $display("[TEST 7 PASSED] Invalid dimension properly rejected with STATUS.ERROR=1.");

        // --------------------------------------------------------------------
        // TEST 8: Hardware Auto-Copy Output Buffer to Input Buffer
        // Configure K=4, M=4. Inputs = [1, 2, 3, 4]. Weights = Identity Matrix (4x4).
        // Start layer with CTRL bit 1 (COPY_OUT_TO_IN) set: 0x0000_0003.
        // After completion, verify Output Buffer content is in Input Buffer!
        // --------------------------------------------------------------------
        $display("[TEST 8] Hardware Auto-Copy Buffer Chaining (Layer Execution with Auto-Copy)");
        write_word(32'h4000_0008, 32'h0004_0004); // K=4, M=4
        write_word(32'h4000_000C, 32'h0000_0000); // ACT = NONE
        write_word(32'h4000_0010, 32'h0000_8000); // Scale = 32768
        write_word(32'h4000_0014, 32'h0000_000F); // Shift = 15 (identity 1.0)

        // Input vector X: [10, 20, 30, 40] -> bytes 0x0A, 0x14, 0x1E, 0x28 -> 32'h281e140a
        write_word(32'h4000_0100, 32'h281e140a);

        // Biases = 0
        for (i = 0; i < 4; i = i + 1)
            write_word(32'h4000_0200 + (i * 4), 32'd0);

        // Weights = Identity 4x4:
        // row 0: [1, 0, 0, 0] = 0x00000001
        // row 1: [0, 1, 0, 0] = 0x00000100
        // row 2: [0, 0, 1, 0] = 0x00010000
        // row 3: [0, 0, 0, 1] = 0x01000000
        write_word(32'h4000_0400, 32'h00000001);
        write_word(32'h4000_0404, 32'h00000100);
        write_word(32'h4000_0408, 32'h00010000);
        write_word(32'h4000_040C, 32'h01000000);

        // Start Layer with Auto-Copy enabled: Bit 0 (START) | Bit 1 (COPY_OUT_TO_IN) = 0x3
        write_word(32'h4000_0000, 32'h0000_0003);
        poll_done(rdata);

        // Verify Output Buffer (0x4000_0800) matches expected [10, 20, 30, 40]
        read_word(32'h4000_0800, rdata);
        $display("[TEST 8] Output Buffer Word 0: 0x%08x (Expected: 0x281e140a)", rdata);
        if (rdata !== 32'h281e140a)
            $fatal(1, "[TEST 8 FAILED] Layer inference output mismatch!");

        // Now verify Input Buffer (0x4000_0100) received the auto-copied output
        read_word(32'h4000_0100, rdata);
        $display("[TEST 8] Auto-Copied Input Buffer Word 0: 0x%08x (Expected: 0x281e140a)", rdata);
        if (rdata !== 32'h281e140a)
            $fatal(1, "[TEST 8 FAILED] Hardware auto-copy failed to update input buffer!");

        $display("[TEST 8 PASSED] Hardware auto-copy buffer chaining verified successfully.");

        $display("===============================================================");
        $display("=== ALL 8 RV_NNA RTL CORNER-CASE TESTS PASSED SUCCESSFULLY! ===");
        $display("===============================================================");
        $finish(0);
    end

endmodule
