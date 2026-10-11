// ============================================================================
// Testbench: tb_nna_top
// Tests memory-mapped bus writes to NNA, layer execution, and output readback
// Hardened with watchdog timer, strict assertions, and fatal exit codes.
// ============================================================================

`timescale 1ns / 1ps

module tb_nna_top;

    reg        clk;
    reg        rst_n;
    reg        bus_req;
    reg        bus_we;
    reg [31:0] bus_addr;
    reg [31:0] bus_wdata;
    reg [3:0]  bus_wstrb;
    wire [31:0] bus_rdata;
    wire       bus_ready;
    wire       irq;

    // Instantiate Device Under Test
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

    // Clock generator: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // Simulation Watchdog Timer (100,000 cycles / 2ms)
    initial begin
        #2000000;
        $fatal(1, "[TB FATAL] Watchdog timeout in tb_nna_top! NNA simulation hung.");
    end

    // Bus write task
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

    // Bus read task
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

        $display("=== TB_NNA_TOP: Starting Test ===");

        // Test 1: Write and verify CONFIG registers
        $display("[Test 1] Writing configuration registers...");
        // K=16, M=8 -> CONFIG_DIM = {M[15:0], K[15:0]} = 0x0008_0010
        write_word(32'h4000_0008, 32'h0008_0010);
        // Activation = ReLU (0x01)
        write_word(32'h4000_000C, 32'h0000_0001);
        // Scale = 0x8000 (32768, representing 0.5 in Q16)
        write_word(32'h4000_0010, 32'h0000_8000);
        // Shift = 16
        write_word(32'h4000_0014, 32'h0000_0010);

        read_word(32'h4000_0008, rdata);
        $display("CONFIG_DIM readback: 0x%08x (expected 0x00080010)", rdata);
        if (rdata != 32'h0008_0010) begin
            $fatal(1, "[TB FATAL] CONFIG_DIM register mismatch!");
        end

        // Test 2: Load Input activation vector (4 words = 16 bytes)
        // All inputs set to 10 (0x0A0A0A0A)
        $display("[Test 2] Loading Input activations into Scratchpad...");
        write_word(32'h4000_0100, 32'h0a0a0a0a);
        write_word(32'h4000_0104, 32'h0a0a0a0a);
        write_word(32'h4000_0108, 32'h0a0a0a0a);
        write_word(32'h4000_010C, 32'h0a0a0a0a);

        // Test 3: Load Biases (8 words, all 0)
        $display("[Test 3] Loading Biases...");
        for (i = 0; i < 8; i = i + 1) begin
            write_word(32'h4000_0200 + (i * 4), 32'd0);
        end

        // Test 4: Load Weights: 8 neurons x 4 words per row = 32 words
        // Weight row 0: all weights = 2 (0x02020202) -> sum = 16 * 10 * 2 = 320.
        // Scale = 0.5 -> output = 160 -> clamped by ReLU to 127!
        // Weight row 1: all weights = 1 (0x01010101) -> sum = 16 * 10 * 1 = 160.
        // Scale = 0.5 -> output = 80!
        $display("[Test 4] Loading Weight matrix (32 words)...");
        for (i = 0; i < 32; i = i + 1) begin
            if (i < 4)
                write_word(32'h4000_0400 + (i * 4), 32'h02020202);
            else if (i < 8)
                write_word(32'h4000_0400 + (i * 4), 32'h01010101);
            else
                write_word(32'h4000_0400 + (i * 4), 32'h00000000);
        end

        // Test 5: Trigger computation
        $display("[Test 5] Triggering NNA inference...");
        write_word(32'h4000_0000, 32'h0000_0001); // CTRL.START = 1

        // Poll STATUS until DONE
        rdata = 0;
        while ((rdata & 32'h2) == 0) begin
            read_word(32'h4000_0004, rdata);
            #10;
        end
        $display("Execution finished! STATUS=0x%08x", rdata);

        // Read cycle count
        read_word(32'h4000_0018, rdata);
        $display("Layer executed in %0d clock cycles", rdata);

        // Read back output buffer words
        read_word(32'h4000_0800, rdata);
        $display("Output Word 0 (Neurons 0-3): 0x%08x", rdata);
        // Expected: Neuron 0 = 127 (0x7F), Neuron 1 = 80 (0x50), Neurons 2-3 = 0
        // Little endian: byte 0 = 0x7F, byte 1 = 0x50, byte 2 = 0x00, byte 3 = 0x00 -> 0x0000507f
        if (rdata[15:0] == 16'h507f) begin
            $display("SUCCESS: Neuron 0 (127/0x7F) and Neuron 1 (80/0x50) match exact expected values!");
        end else begin
            $fatal(1, "[TB FATAL] Output mismatch! Got 0x%08x, expected 0x0000507f", rdata);
        end

        $display("=== TB_NNA_TOP: ALL TESTS PASSED SUCCESSFULLY! ===");
        $finish(0);
    end

endmodule
