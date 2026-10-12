// ============================================================================
// Testbench: tb_nna_trained_policy
// Verification of rv_nna Neural Accelerator against Bit-Exact Python Model
// Evaluates 2-Layer MLP (16 -> 8 -> 2) on authentic navigation observation vectors.
// Hardened with strict watchdog timer, zero-tolerance assertions, and exit codes.
// ============================================================================

`timescale 1ns / 1ps
`include "soc_pkg.sv"

module tb_nna_trained_policy;

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

    // Clock Generation: 50 MHz (20 ns period)
    initial clk = 0;
    always #10 clk = ~clk;

    // Hardware Watchdog Timer: 5 ms timeout
    initial begin
        #5000000;
        $display("[FAIL] HARDWARE WATCHDOG TIMEOUT in tb_nna_trained_policy");
        $fatal(1, "Testbench timed out");
    end

    // Device Under Test
    nna_top u_dut (
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

    // Wishbone / Synchronous MMIO Bus Tasks
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
            data = bus_rdata;
            bus_req   <= 1'b0;
        end
    endtask

    // Memory-Mapped Register Offsets
    localparam ADDR_BASE         = 32'h4000_0000;
    localparam REG_CTRL          = ADDR_BASE + 32'h00;
    localparam REG_STATUS        = ADDR_BASE + 32'h04;
    localparam REG_CONFIG_DIM    = ADDR_BASE + 32'h08;
    localparam REG_CONFIG_ACT    = ADDR_BASE + 32'h0C;
    localparam REG_CONFIG_SCALE  = ADDR_BASE + 32'h10;
    localparam REG_CONFIG_SHIFT  = ADDR_BASE + 32'h14;
    localparam REG_PERF_CYCLES   = ADDR_BASE + 32'h18;
    localparam BUF_IN            = ADDR_BASE + 32'h100;
    localparam BUF_BIAS          = ADDR_BASE + 32'h200;
    localparam BUF_WEIGHT        = ADDR_BASE + 32'h400;
    localparam BUF_OUT           = ADDR_BASE + 32'h800;

    // Policy Parameters
    localparam L1_K          = 16'd16;
    localparam L1_M          = 16'd8;
    localparam L1_SCALE_MULT = 16'd153;
    localparam L1_SHIFT      = 5'd15;
    localparam L1_ACT        = 2'd1; // ReLU

    localparam L2_K          = 16'd8;
    localparam L2_M          = 16'd2;
    localparam L2_SCALE_MULT = 16'd1333;
    localparam L2_SHIFT      = 5'd15;
    localparam L2_ACT        = 2'd2; // Clip

    // Layer Weights and Biases Storage
    reg [31:0] l1_w_rom [0:31];
    reg [31:0] l1_b_rom [0:7];
    reg [31:0] l2_w_rom [0:3];
    reg [31:0] l2_b_rom [0:1];

    // Authentic Test Vectors (25 samples)
    localparam NUM_VECTORS = 25;
    reg [31:0] vec_in_rom   [0:NUM_VECTORS*4 - 1];
    reg [31:0] vec_h1_exp   [0:NUM_VECTORS*2 - 1];
    reg [31:0] vec_out_exp  [0:NUM_VECTORS*1 - 1];

    integer i, v_idx;
    reg [31:0] rdata;
    reg [31:0] l1_cycles, l2_cycles;
    reg [31:0] total_l1_cycles, total_l2_cycles;
    integer pass_count;

    initial begin
        // Initialize Weights and Biases
        l1_w_rom[0] = 32'h12120403;
        l1_w_rom[1] = 32'hd5ec0307;
        l1_w_rom[2] = 32'he9eefcf5;
        l1_w_rom[3] = 32'hadd6cd05;
        l1_w_rom[4] = 32'h030706fc;
        l1_w_rom[5] = 32'hfd81fcfd;
        l1_w_rom[6] = 32'h14ef28f4;
        l1_w_rom[7] = 32'h24f902f2;
        l1_w_rom[8] = 32'hfefd8afc;
        l1_w_rom[9] = 32'hfdff0505;
        l1_w_rom[10] = 32'h01fd1e11;
        l1_w_rom[11] = 32'hf6f6efdf;
        l1_w_rom[12] = 32'h0e0b0205;
        l1_w_rom[13] = 32'h08faff01;
        l1_w_rom[14] = 32'h72ec2aed;
        l1_w_rom[15] = 32'hd4f3e1f5;
        l1_w_rom[16] = 32'h0b0f0501;
        l1_w_rom[17] = 32'h300203fe;
        l1_w_rom[18] = 32'h5fd102ff;
        l1_w_rom[19] = 32'h88f90502;
        l1_w_rom[20] = 32'h050806fa;
        l1_w_rom[21] = 32'h08fd07ff;
        l1_w_rom[22] = 32'h0324acf4;
        l1_w_rom[23] = 32'h60ed1af0;
        l1_w_rom[24] = 32'hf804fcfb;
        l1_w_rom[25] = 32'hfd0590fc;
        l1_w_rom[26] = 32'hfe25d2fc;
        l1_w_rom[27] = 32'hfbe9f806;
        l1_w_rom[28] = 32'h191e0afa;
        l1_w_rom[29] = 32'h00ecff03;
        l1_w_rom[30] = 32'h16ca2212;
        l1_w_rom[31] = 32'ha4d5db0d;
        l1_b_rom[0] = 32'h00001bb9;
        l1_b_rom[1] = 32'hffffda7b;
        l1_b_rom[2] = 32'hffffdfd9;
        l1_b_rom[3] = 32'hfffffe8c;
        l1_b_rom[4] = 32'hfffff6d6;
        l1_b_rom[5] = 32'h00000b92;
        l1_b_rom[6] = 32'hffffe0bd;
        l1_b_rom[7] = 32'hfffff021;
        l2_w_rom[0] = 32'h1bd8e9ff;
        l2_w_rom[1] = 32'hf3cd02fc;
        l2_w_rom[2] = 32'h1d7f9fd1;
        l2_w_rom[3] = 32'h2d8727cb;
        l2_b_rom[0] = 32'h00000284;
        l2_b_rom[1] = 32'h000003c3;

        // Initialize Test Vectors
        vec_in_rom[0] = 32'hd76c6edf;
        vec_in_rom[1] = 32'hd3767f7f;
        vec_in_rom[2] = 32'h81000000;
        vec_in_rom[3] = 32'h36290000;
        vec_h1_exp[0] = 32'h0000001d;
        vec_h1_exp[1] = 32'h00002800;
        vec_out_exp[0] = 32'h00002f1c;
        vec_in_rom[4] = 32'h7fb3b359;
        vec_in_rom[5] = 32'h7f527f41;
        vec_in_rom[6] = 32'h321b0f00;
        vec_in_rom[7] = 32'hfb021b00;
        vec_h1_exp[2] = 32'h1e040000;
        vec_h1_exp[3] = 32'h00001127;
        vec_out_exp[1] = 32'h00002630;
        vec_in_rom[8] = 32'h7f57ada7;
        vec_in_rom[9] = 32'hcac6d702;
        vec_in_rom[10] = 32'h17eaf600;
        vec_in_rom[11] = 32'hdd25ea00;
        vec_h1_exp[4] = 32'h1c07004b;
        vec_h1_exp[5] = 32'h1e000013;
        vec_out_exp[2] = 32'h0000eb18;
        vec_in_rom[12] = 32'h557fd57f;
        vec_in_rom[13] = 32'hb87f7f7f;
        vec_in_rom[14] = 32'h40090500;
        vec_in_rom[15] = 32'h05200900;
        vec_h1_exp[6] = 32'h2500002a;
        vec_h1_exp[7] = 32'h0000100a;
        vec_out_exp[3] = 32'h00000641;
        vec_in_rom[16] = 32'h7fc3c433;
        vec_in_rom[17] = 32'h7f7f7f7f;
        vec_in_rom[18] = 32'h273a1e00;
        vec_in_rom[19] = 32'h00023a00;
        vec_h1_exp[8] = 32'h12000000;
        vec_h1_exp[9] = 32'h0000171b;
        vec_out_exp[4] = 32'h0000272b;
        vec_in_rom[20] = 32'hbdb4577f;
        vec_in_rom[21] = 32'h551d1e3b;
        vec_in_rom[22] = 32'h29432300;
        vec_in_rom[23] = 32'hf9d64300;
        vec_h1_exp[10] = 32'h0d000000;
        vec_h1_exp[11] = 32'h0000130d;
        vec_out_exp[5] = 32'h00003928;
        vec_in_rom[24] = 32'h7f7fe147;
        vec_in_rom[25] = 32'hb57f7f60;
        vec_in_rom[26] = 32'h3d1a0f00;
        vec_in_rom[27] = 32'h05cc1a00;
        vec_h1_exp[12] = 32'h27000038;
        vec_h1_exp[13] = 32'h05001b0a;
        vec_out_exp[6] = 32'h00000941;
        vec_in_rom[28] = 32'hdcddf97f;
        vec_in_rom[29] = 32'ha73b09e7;
        vec_in_rom[30] = 32'h1d5b2d00;
        vec_in_rom[31] = 32'h2bc35b00;
        vec_h1_exp[14] = 32'h00000003;
        vec_h1_exp[15] = 32'h00002600;
        vec_out_exp[7] = 32'h00005e1d;
        vec_in_rom[32] = 32'h547f4a7f;
        vec_in_rom[33] = 32'h236acb7f;
        vec_in_rom[34] = 32'h3aeaf300;
        vec_in_rom[35] = 32'hfbb2ea00;
        vec_h1_exp[16] = 32'h3400003b;
        vec_h1_exp[17] = 32'h2000152f;
        vec_out_exp[8] = 32'h0000ea3a;
        vec_in_rom[36] = 32'h1b7f7fa0;
        vec_in_rom[37] = 32'hc6dd6a7f;
        vec_in_rom[38] = 32'h12e3f300;
        vec_in_rom[39] = 32'hddf0e300;
        vec_h1_exp[18] = 32'h1b00005c;
        vec_h1_exp[19] = 32'h2d000917;
        vec_out_exp[9] = 32'h0000c619;
        vec_in_rom[40] = 32'h6e61e46e;
        vec_in_rom[41] = 32'h016efffe;
        vec_in_rom[42] = 32'h42e6f000;
        vec_in_rom[43] = 32'h04ece600;
        vec_h1_exp[20] = 32'h3000002d;
        vec_h1_exp[21] = 32'h0a001223;
        vec_out_exp[10] = 32'h0000ed44;
        vec_in_rom[44] = 32'he7fb4ca9;
        vec_in_rom[45] = 32'h7f24ebe3;
        vec_in_rom[46] = 32'h2296ca00;
        vec_in_rom[47] = 32'hd0c79600;
        vec_h1_exp[22] = 32'h2d00003e;
        vec_h1_exp[23] = 32'h34000052;
        vec_out_exp[11] = 32'h00009420;
        vec_in_rom[48] = 32'h27267fb6;
        vec_in_rom[49] = 32'hb8c3fe7f;
        vec_in_rom[50] = 32'h2bfdfe00;
        vec_in_rom[51] = 32'h01f9fd00;
        vec_h1_exp[24] = 32'h1900023f;
        vec_h1_exp[25] = 32'h0d001500;
        vec_out_exp[12] = 32'h0000fd2c;
        vec_in_rom[52] = 32'h7f7f377f;
        vec_in_rom[53] = 32'ha9487f1d;
        vec_in_rom[54] = 32'h30120a00;
        vec_in_rom[55] = 32'h13a11200;
        vec_h1_exp[26] = 32'h24000047;
        vec_h1_exp[27] = 32'h10002600;
        vec_out_exp[13] = 32'h00002339;
        vec_in_rom[56] = 32'hfc005142;
        vec_in_rom[57] = 32'h7f297f7f;
        vec_in_rom[58] = 32'h392f1b00;
        vec_in_rom[59] = 32'h03f02f00;
        vec_h1_exp[28] = 32'h1d000000;
        vec_h1_exp[29] = 32'h00001c24;
        vec_out_exp[14] = 32'h00002836;
        vec_in_rom[60] = 32'h2d40ec76;
        vec_in_rom[61] = 32'h4ab84f31;
        vec_in_rom[62] = 32'h3cfafc00;
        vec_in_rom[63] = 32'h0399fa00;
        vec_h1_exp[30] = 32'h32000435;
        vec_h1_exp[31] = 32'h1a001f2a;
        vec_out_exp[15] = 32'h0000f339;
        vec_in_rom[64] = 32'hd4c3becc;
        vec_in_rom[65] = 32'haf362908;
        vec_in_rom[66] = 32'h17361a00;
        vec_in_rom[67] = 32'h189e3600;
        vec_h1_exp[32] = 32'h00040018;
        vec_h1_exp[33] = 32'h00002100;
        vec_out_exp[16] = 32'h00004215;
        vec_in_rom[68] = 32'h503235a5;
        vec_in_rom[69] = 32'h2c7ff57f;
        vec_in_rom[70] = 32'h2cd7ea00;
        vec_in_rom[71] = 32'heec0d700;
        vec_h1_exp[34] = 32'h28000038;
        vec_h1_exp[35] = 32'h1f000f2f;
        vec_out_exp[17] = 32'h0000d72d;
        vec_in_rom[72] = 32'h187fe1b2;
        vec_in_rom[73] = 32'hc7c47f7f;
        vec_in_rom[74] = 32'h36fbfd00;
        vec_in_rom[75] = 32'hfa14fb00;
        vec_h1_exp[36] = 32'h2100003d;
        vec_h1_exp[37] = 32'h0f00130d;
        vec_out_exp[18] = 32'h0000f733;
        vec_in_rom[76] = 32'h6e4034aa;
        vec_in_rom[77] = 32'h2d7f06fb;
        vec_in_rom[78] = 32'h33e6f100;
        vec_in_rom[79] = 32'hf4d8e600;
        vec_h1_exp[38] = 32'h2900002a;
        vec_h1_exp[39] = 32'h1700142f;
        vec_out_exp[19] = 32'h0000ec33;
        vec_in_rom[80] = 32'h757f0b7f;
        vec_in_rom[81] = 32'h484df8ed;
        vec_in_rom[82] = 32'h4a010100;
        vec_in_rom[83] = 32'h09f60100;
        vec_h1_exp[40] = 32'h36000017;
        vec_h1_exp[41] = 32'h07001932;
        vec_out_exp[20] = 32'h0000044b;
        vec_in_rom[84] = 32'hfb3b3da7;
        vec_in_rom[85] = 32'h3becdee4;
        vec_in_rom[86] = 32'h1ea4d300;
        vec_in_rom[87] = 32'hddc5a400;
        vec_h1_exp[42] = 32'h2a00004f;
        vec_h1_exp[43] = 32'h3a00033b;
        vec_out_exp[21] = 32'h0000b11d;
        vec_in_rom[88] = 32'hdafd3db9;
        vec_in_rom[89] = 32'h42dfcdce;
        vec_in_rom[90] = 32'h2ee9f300;
        vec_in_rom[91] = 32'hed95e900;
        vec_h1_exp[44] = 32'h24000030;
        vec_h1_exp[45] = 32'h1a021229;
        vec_out_exp[22] = 32'h0000e029;
        vec_in_rom[92] = 32'h9b9c3671;
        vec_in_rom[93] = 32'h662420a3;
        vec_in_rom[94] = 32'h291b0e00;
        vec_in_rom[95] = 32'hf1c51b00;
        vec_h1_exp[46] = 32'h11000000;
        vec_h1_exp[47] = 32'h00000c1b;
        vec_out_exp[23] = 32'h00001429;
        vec_in_rom[96] = 32'he6eccebc;
        vec_in_rom[97] = 32'had7f07ed;
        vec_in_rom[98] = 32'h1f1e0f00;
        vec_in_rom[99] = 32'h1b8e1e00;
        vec_h1_exp[48] = 32'h0000001e;
        vec_h1_exp[49] = 32'h00002200;
        vec_out_exp[24] = 32'h0000241c;

        // Reset sequence
        rst_n     = 0;
        bus_req   = 0;
        bus_we    = 0;
        bus_addr  = 0;
        bus_wdata = 0;
        bus_wstrb = 0;
        pass_count = 0;
        total_l1_cycles = 0;
        total_l2_cycles = 0;

        #40;
        rst_n = 1;
        #40;

        $display("================================================================================");
        $display(" tb_nna_trained_policy: Bit-Exact Hardware Verification (25 Authentic Vectors) ");
        $display("================================================================================");

        for (v_idx = 0; v_idx < NUM_VECTORS; v_idx = v_idx + 1) begin
            // ----------------------------------------------------------------
            // 1. Load Layer 1 Parameters, Weights & Inputs
            // ----------------------------------------------------------------
            // Write L1 Weights (32 words)
            for (i = 0; i < 32; i = i + 1) begin
                bus_write(BUF_WEIGHT + (i * 4), l1_w_rom[i]);
            end
            // Write L1 Biases (8 words)
            for (i = 0; i < 8; i = i + 1) begin
                bus_write(BUF_BIAS + (i * 4), l1_b_rom[i]);
            end
            // Write Input Vector (4 words = 16 INT8 values)
            for (i = 0; i < 4; i = i + 1) begin
                bus_write(BUF_IN + (i * 4), vec_in_rom[v_idx * 4 + i]);
            end

            // Configure Layer 1
            bus_write(REG_CONFIG_DIM,   {L1_M, L1_K});
            bus_write(REG_CONFIG_ACT,   {30'd0, L1_ACT});
            bus_write(REG_CONFIG_SCALE, {16'd0, L1_SCALE_MULT});
            bus_write(REG_CONFIG_SHIFT, {27'd0, L1_SHIFT});

            // Start Layer 1 with AUTO_COPY_OUT_TO_IN (0x1 | 0x4 = 0x5)
            bus_write(REG_CTRL, 32'h3); // 0x1 (START) | 0x2 (AUTO_COPY)

            // Poll for Completion
            rdata = 0;
            while ((rdata & 32'h2) == 0) begin
                bus_read(REG_STATUS, rdata);
            end

            // Verify Layer 1 Latency
            bus_read(REG_PERF_CYCLES, l1_cycles);
            total_l1_cycles = total_l1_cycles + l1_cycles;

            // Verify Layer 1 Hidden Activations H1 (2 words = 8 INT8 neurons)
            for (i = 0; i < 2; i = i + 1) begin
                bus_read(BUF_OUT + (i * 4), rdata);
                if (rdata !== vec_h1_exp[v_idx * 2 + i]) begin
                    $display("[FAIL] Vector %0d Layer 1 Mismatch at word %0d: Expected 0x%08x, Got 0x%08x",
                             v_idx, i, vec_h1_exp[v_idx * 2 + i], rdata);
                    $fatal(1, "Layer 1 output mismatch against reference model");
                end
            end

            // Verify Auto-Copy into BUF_IN
            for (i = 0; i < 2; i = i + 1) begin
                bus_read(BUF_IN + (i * 4), rdata);
                if (rdata !== vec_h1_exp[v_idx * 2 + i]) begin
                    $display("[FAIL] Vector %0d Auto-Copy Mismatch at word %0d: Expected 0x%08x, Got 0x%08x",
                             v_idx, i, vec_h1_exp[v_idx * 2 + i], rdata);
                    $fatal(1, "Auto-copy buffer mismatch");
                end
            end

            // ----------------------------------------------------------------
            // 2. Load Layer 2 Weights and Execute
            // ----------------------------------------------------------------
            // Write L2 Weights (4 words)
            for (i = 0; i < 4; i = i + 1) begin
                bus_write(BUF_WEIGHT + (i * 4), l2_w_rom[i]);
            end
            // Write L2 Biases (2 words)
            for (i = 0; i < 2; i = i + 1) begin
                bus_write(BUF_BIAS + (i * 4), l2_b_rom[i]);
            end

            // Configure Layer 2
            bus_write(REG_CONFIG_DIM,   {L2_M, L2_K});
            bus_write(REG_CONFIG_ACT,   {30'd0, L2_ACT});
            bus_write(REG_CONFIG_SCALE, {16'd0, L2_SCALE_MULT});
            bus_write(REG_CONFIG_SHIFT, {27'd0, L2_SHIFT});

            // Start Layer 2 (START = 0x1)
            bus_write(REG_CTRL, 32'h1);

            // Poll for Completion
            rdata = 0;
            while ((rdata & 32'h2) == 0) begin
                bus_read(REG_STATUS, rdata);
            end

            // Verify Layer 2 Latency
            bus_read(REG_PERF_CYCLES, l2_cycles);
            total_l2_cycles = total_l2_cycles + l2_cycles;

            // Verify Layer 2 Output Actions Y (word 0: byte0=v, byte1=w)
            bus_read(BUF_OUT, rdata);
            if ((rdata & 32'h0000_FFFF) !== (vec_out_exp[v_idx] & 32'h0000_FFFF)) begin
                $display("[FAIL] Vector %0d Layer 2 Action Mismatch: Expected 0x%04x, Got 0x%04x",
                         v_idx, (vec_out_exp[v_idx] & 32'hFFFF), (rdata & 32'hFFFF));
                $fatal(1, "Layer 2 action mismatch against reference model");
            end

            pass_count = pass_count + 1;
            $display("[PASS] Vector %2d/%2d: L1 Cycles=%2d | L2 Cycles=%2d | Action [v=%4d, w=%4d] (0 LSB Error)",
                     v_idx + 1, NUM_VECTORS, l1_cycles, l2_cycles,
                     $signed(rdata[7:0]), $signed(rdata[15:8]));
        end

        $display("--------------------------------------------------------------------------------");
        $display("[SUMMARY] All %0d/%0d Authentic Observation Vectors Passed with 0 LSB Error!", pass_count, NUM_VECTORS);
        $display("Layer 1 Cycles/Inference: %0d", total_l1_cycles / NUM_VECTORS);
        $display("Layer 2 Cycles/Inference: %0d", total_l2_cycles / NUM_VECTORS);
        $display("Total NN Hardware Cycles: %0d (Theoretical: 60 cycles)", (total_l1_cycles + total_l2_cycles) / NUM_VECTORS);
        $display("================================================================================");

        $finish;
    end

endmodule
