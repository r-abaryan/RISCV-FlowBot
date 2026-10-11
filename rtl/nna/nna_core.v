// ============================================================================
// Module: nna_core
// Description: Sequencing FSM, Accumulator, and Requantization Engine
// ============================================================================

`timescale 1ns / 1ps
`include "soc_pkg.sv"

module nna_core (
    input  wire        clk,
    input  wire        rst_n,

    // Control from Registers
    input  wire        core_start,
    input  wire        core_copy_out_to_in,
    input  wire        core_irq_en,
    input  wire        core_soft_rst,
    input  wire [15:0] core_k_dim,
    input  wire [15:0] core_m_dim,
    input  wire [1:0]  core_act_type,
    input  wire [15:0] core_scale_mult,
    input  wire [4:0]  core_scale_shift,

    // Status to Registers
    output reg         core_busy,
    output reg         core_done,
    output reg         core_err,
    output reg  [31:0] core_cycle_count,
    output reg         irq_pulse,

    // Port B Memory Read Interfaces
    output wire [4:0]  core_in_raddr,
    input  wire [31:0] core_in_rdata,

    output wire [5:0]  core_bias_raddr,
    input  wire [31:0] core_bias_rdata,

    output wire [7:0]  core_weight_raddr,
    input  wire [31:0] core_weight_rdata,

    // Port B Output Buffer Write Interface
    output reg         core_out_we,
    output reg  [4:0]  core_out_waddr,
    output wire [31:0] core_out_wdata,
    output reg  [3:0]  core_out_wstrb,

    // Hardware Auto-Copy: Output to Input
    output reg         core_copy_step,
    output reg  [4:0]  core_copy_addr
);

    // ------------------------------------------------------------------------
    // FSM States
    // ------------------------------------------------------------------------
    localparam [2:0]
        ST_IDLE      = 3'd0,
        ST_LOAD_BIAS = 3'd1,
        ST_MAC_CALC  = 3'd2,
        ST_POST_PROC = 3'd3,
        ST_COPY_LOOP = 3'd4,
        ST_FINISH    = 3'd5;

    reg [2:0] state;

    // Loop indices
    reg [5:0] m_cnt;   // Output neuron index [0 .. M-1]
    reg [7:0] k_cnt;   // Input activation index [0 .. K-1], step 4
    reg [4:0] copy_cnt;

    // Cycle counter
    reg [31:0] cur_cycles;

    // 32-bit Accumulator
    reg signed [31:0] acc;

    // ------------------------------------------------------------------------
    // Addressing Logic
    // ------------------------------------------------------------------------
    assign core_bias_raddr   = m_cnt;
    assign core_in_raddr     = k_cnt[6:2];

    // Weight address: row m * (K/4) + (k/4)
    wire [13:0] weight_idx_calc = ({8'd0, m_cnt} * {8'd0, core_k_dim[7:2]}) + {9'd0, k_cnt[6:2]};
    assign core_weight_raddr   = weight_idx_calc[7:0];

    // ------------------------------------------------------------------------
    // MAC Engine Instance
    // ------------------------------------------------------------------------
    wire signed [7:0] in0 = core_in_rdata[7:0];
    wire signed [7:0] in1 = core_in_rdata[15:8];
    wire signed [7:0] in2 = core_in_rdata[23:16];
    wire signed [7:0] in3 = core_in_rdata[31:24];

    wire signed [7:0] w0  = core_weight_rdata[7:0];
    wire signed [7:0] w1  = core_weight_rdata[15:8];
    wire signed [7:0] w2  = core_weight_rdata[23:16];
    wire signed [7:0] w3  = core_weight_rdata[31:24];

    wire signed [17:0] mac_sum4;

    nna_mac4 u_mac4 (
        .a0(in0), .a1(in1), .a2(in2), .a3(in3),
        .b0(w0),  .b1(w1),  .b2(w2),  .b3(w3),
        .sum4(mac_sum4)
    );

    // ------------------------------------------------------------------------
    // Fixed-Point Requantization & Activation Logic
    // ------------------------------------------------------------------------
    wire signed [48:0] scaled_acc = $signed(acc) * $signed({1'b0, core_scale_mult});
    
    // Rounding: add 1 << (shift - 1) if shift > 0
    wire signed [48:0] rounding_term = (core_scale_shift > 5'd0) ?
                                       ($signed(49'sd1) <<< (core_scale_shift - 5'd1)) : 49'sd0;
    wire signed [48:0] rounded_acc   = scaled_acc + rounding_term;
    wire signed [48:0] shifted_acc   = rounded_acc >>> core_scale_shift;

    // Activation & Clamping
    reg signed [7:0] act_val;
    always @(*) begin
        case (core_act_type)
            `ACT_RELU: begin
                if (shifted_acc < 49'sd0)
                    act_val = 8'sd0;
                else if (shifted_acc > 49'sd127)
                    act_val = 8'sd127;
                else
                    act_val = shifted_acc[7:0];
            end
            `ACT_CLIP, `ACT_PASSTHROUGH: begin
                if (shifted_acc < -49'sd128)
                    act_val = -8'sd128;
                else if (shifted_acc > 49'sd127)
                    act_val = 8'sd127;
                else
                    act_val = shifted_acc[7:0];
            end
            default: begin
                // Safe default: saturate to full INT8 signed bounds [-128, +127]
                if (shifted_acc < -49'sd128)
                    act_val = 8'sh80;
                else if (shifted_acc > 49'sd127)
                    act_val = 8'sh7f;
                else
                    act_val = shifted_acc[7:0];
            end
        endcase
    end

    // Broadcast 8-bit output to all 4 bytes; byte strobe selects the active byte
    assign core_out_wdata = {4{act_val}};

    wire [4:0] max_copy_words = ((core_m_dim[6:0] - 7'd1) >> 2);

    // ------------------------------------------------------------------------
    // Main Control FSM
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || core_soft_rst) begin
            state            <= ST_IDLE;
            core_busy        <= 1'b0;
            core_done        <= 1'b0;
            core_err         <= 1'b0;
            core_cycle_count <= 32'd0;
            cur_cycles       <= 32'd0;
            irq_pulse        <= 1'b0;
            m_cnt            <= 6'd0;
            k_cnt            <= 8'd0;
            copy_cnt         <= 5'd0;
            acc              <= 32'sd0;
            core_out_we      <= 1'b0;
            core_out_waddr   <= 5'd0;
            core_out_wstrb   <= 4'b0000;
            core_copy_step   <= 1'b0;
            core_copy_addr   <= 5'd0;
        end else begin
            irq_pulse      <= 1'b0;
            core_out_we    <= 1'b0;
            core_copy_step <= 1'b0;

            if (core_busy) begin
                cur_cycles <= cur_cycles + 32'd1;
            end

            case (state)
                ST_IDLE: begin
                    if (core_start) begin
                        // Validate dimensions: K in [4..64] and multiple of 4, M in [1..64]
                        if ((core_k_dim == 0) || (core_k_dim[1:0] != 2'b00) || (core_k_dim > 16'd64) ||
                            (core_m_dim == 0) || (core_m_dim > 16'd64) ||
                            ((core_m_dim * (core_k_dim >> 2)) > 16'd256)) begin
                            core_err  <= 1'b1;
                            core_done <= 1'b1;
                            core_busy <= 1'b0;
                        end else begin
                            core_err   <= 1'b0;
                            core_done  <= 1'b0;
                            core_busy  <= 1'b1;
                            cur_cycles <= 32'd0;
                            m_cnt      <= 6'd0;
                            state      <= ST_LOAD_BIAS;
                        end
                    end
                end

                ST_LOAD_BIAS: begin
                    // Load bias into accumulator
                    acc   <= $signed(core_bias_rdata);
                    k_cnt <= 8'd0;
                    state <= ST_MAC_CALC;
                end

                ST_MAC_CALC: begin
                    // Accumulate 4-way product
                    acc   <= acc + $signed({{14{mac_sum4[17]}}, mac_sum4});
                    k_cnt <= k_cnt + 8'd4;

                    if ((k_cnt + 8'd4) >= core_k_dim[7:0]) begin
                        state <= ST_POST_PROC;
                    end
                end

                ST_POST_PROC: begin
                    // Write back activated result to Output Buffer
                    core_out_we    <= 1'b1;
                    core_out_waddr <= {1'b0, m_cnt[5:2]};
                    core_out_wstrb <= 4'b0001 << m_cnt[1:0];

                    if ((m_cnt + 6'd1) >= core_m_dim[5:0]) begin
                        if (core_copy_out_to_in) begin
                            copy_cnt <= 5'd0;
                            state    <= ST_COPY_LOOP;
                        end else begin
                            state <= ST_FINISH;
                        end
                    end else begin
                        m_cnt <= m_cnt + 6'd1;
                        state <= ST_LOAD_BIAS;
                    end
                end

                ST_COPY_LOOP: begin
                    core_copy_step <= 1'b1;
                    core_copy_addr <= copy_cnt;

                    if (copy_cnt >= max_copy_words) begin
                        state <= ST_FINISH;
                    end else begin
                        copy_cnt <= copy_cnt + 5'd1;
                    end
                end

                ST_FINISH: begin
                    core_busy        <= 1'b0;
                    core_done        <= 1'b1;
                    core_cycle_count <= cur_cycles;
                    if (core_irq_en) begin
                        irq_pulse <= 1'b1;
                    end
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
