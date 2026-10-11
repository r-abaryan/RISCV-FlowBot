// ============================================================================
// Module: nna_mac4
// Description: 4-Way Parallel Signed INT8 Dot-Product Unit
// Computes: sum4 = (a0*b0) + (a1*b1) + (a2*b2) + (a3*b3)
// ============================================================================

`timescale 1ns / 1ps

module nna_mac4 (
    input  wire signed [7:0]  a0,
    input  wire signed [7:0]  a1,
    input  wire signed [7:0]  a2,
    input  wire signed [7:0]  a3,
    input  wire signed [7:0]  b0,
    input  wire signed [7:0]  b1,
    input  wire signed [7:0]  b2,
    input  wire signed [7:0]  b3,
    output wire signed [17:0] sum4
);

    // 16-bit signed products
    wire signed [15:0] prod0 = a0 * b0;
    wire signed [15:0] prod1 = a1 * b1;
    wire signed [15:0] prod2 = a2 * b2;
    wire signed [15:0] prod3 = a3 * b3;

    // 17-bit intermediate sums
    wire signed [16:0] sum_lo = prod0 + prod1;
    wire signed [16:0] sum_hi = prod2 + prod3;

    // 18-bit total dot product
    assign sum4 = sum_lo + sum_hi;

endmodule
