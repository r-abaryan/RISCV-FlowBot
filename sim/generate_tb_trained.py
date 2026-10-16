#!/usr/bin/env python3
"""
Generates sim/tb_nna_trained_policy.v with authentic test vectors from quantization analysis.
"""

import json
import os
import sys

def generate_tb(weights_path="sw/policy/trained_policy_weights.json",
                vectors_path="sim/test_vectors_trained.json",
                out_path="sim/tb_nna_trained_policy.v",
                module_name="tb_nna_trained_policy"):
    weights = json.load(open(weights_path))
    vectors = json.load(open(vectors_path))

    def pack_matrix(matrix):
        words = []
        for row in matrix:
            padded = list(row)
            while len(padded) % 4 != 0:
                padded.append(0)
            for i in range(0, len(padded), 4):
                b0 = padded[i] & 0xFF
                b1 = padded[i+1] & 0xFF
                b2 = padded[i+2] & 0xFF
                b3 = padded[i+3] & 0xFF
                w = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
                words.append(w)
        return words

    l1_w_words = pack_matrix(weights["l1"]["weights"])
    l1_b_words = [b & 0xFFFFFFFF for b in weights["l1"]["biases"]]
    l2_w_words = pack_matrix(weights["l2"]["weights"])
    l2_b_words = [b & 0xFFFFFFFF for b in weights["l2"]["biases"]]

    tb_content = f"""// ============================================================================
// Testbench: tb_nna_trained_policy
// Verification of rv_nna Neural Accelerator against Bit-Exact Python Model
// Evaluates 2-Layer MLP ({len(weights["l1"]["weights"][0])} -> {len(weights["l1"]["weights"])} -> {len(weights["l2"]["weights"])}) on authentic navigation observation vectors.
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
    localparam L1_SCALE_MULT = 16'd{weights["l1"]["scale_mult"]};
    localparam L1_SHIFT      = 5'd{weights["l1"]["scale_shift"]};
    localparam L1_ACT        = 2'd1; // ReLU

    localparam L2_K          = 16'd8;
    localparam L2_M          = 16'd2;
    localparam L2_SCALE_MULT = 16'd{weights["l2"]["scale_mult"]};
    localparam L2_SHIFT      = 5'd{weights["l2"]["scale_shift"]};
    localparam L2_ACT        = 2'd2; // Clip

    // Layer Weights and Biases Storage
    reg [31:0] l1_w_rom [0:31];
    reg [31:0] l1_b_rom [0:7];
    reg [31:0] l2_w_rom [0:3];
    reg [31:0] l2_b_rom [0:1];

    // Authentic Test Vectors ({len(vectors)} samples)
    localparam NUM_VECTORS = {len(vectors)};
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
"""

    for i, w in enumerate(l1_w_words):
        tb_content += f"        l1_w_rom[{i}] = 32'h{w:08x};\n"
    for i, b in enumerate(l1_b_words):
        tb_content += f"        l1_b_rom[{i}] = 32'h{b:08x};\n"
    for i, w in enumerate(l2_w_words):
        tb_content += f"        l2_w_rom[{i}] = 32'h{w:08x};\n"
    for i, b in enumerate(l2_b_words):
        tb_content += f"        l2_b_rom[{i}] = 32'h{b:08x};\n"

    tb_content += "\n        // Initialize Test Vectors\n"
    for v_i, vec in enumerate(vectors):
        for w_i, w in enumerate(vec["x_words_raw"]):
            tb_content += f"        vec_in_rom[{v_i*4 + w_i}] = 32'h{w:08x};\n"
        for w_i, w in enumerate(vec["h1_words_raw"]):
            tb_content += f"        vec_h1_exp[{v_i*2 + w_i}] = 32'h{w:08x};\n"
        for w_i, w in enumerate(vec["y_words_raw"]):
            tb_content += f"        vec_out_exp[{v_i*1 + w_i}] = 32'h{w:08x};\n"

    tb_content += """
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
"""
    tb_content = tb_content.replace("tb_nna_trained_policy", module_name)
    with open(out_path, "w") as f:
        f.write(tb_content)
    print("Generated %s successfully!" % out_path)

if __name__ == "__main__":
    # Default (no args): regenerate the IL test exactly as before.
    # `--rl`: RL seed-1 test from sw/policy/rl_seed1_policy.json (see gen_rl_vectors.py).
    if "--rl" in sys.argv:
        generate_tb("sw/policy/rl_seed1_policy.json", "sim/test_vectors_rl_seed1.json",
                    "sim/tb_nna_rl_policy.v", "tb_nna_rl_policy")
    else:
        generate_tb()
