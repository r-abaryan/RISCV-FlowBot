// ============================================================================
// Module: soc_pwm
// Description: Wishbone B4 Motor PWM Peripheral with Hardware Interlock Gating
// Base Address: 0x5000_0200
// ============================================================================

`timescale 1ns / 1ps

module soc_pwm (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone Slave
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output reg         wb_ack_o,

    // Hardware Safety Disarm input from safety_filter
    input  wire        disarm_in,

    // PWM / Motor Outputs
    output reg  [15:0] pwm_left_cmd,
    output reg  [15:0] pwm_right_cmd,
    output wire        pwm_left_out,
    output wire        pwm_right_out
);

    reg        pwm_en;
    reg [15:0] reg_left_duty;
    reg [15:0] reg_right_duty;
    reg [15:0] pwm_counter;

    // Safety Interlock Gate: if disarm_in is high, zero out the commands immediately!
    always @(*) begin
        if (disarm_in || !pwm_en) begin
            pwm_left_cmd  = 16'h0000;
            pwm_right_cmd = 16'h0000;
        end else begin
            pwm_left_cmd  = reg_left_duty;
            pwm_right_cmd = reg_right_duty;
        end
    end

    // Simple 16-bit PWM counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm_counter <= 16'h0;
        end else begin
            pwm_counter <= pwm_counter + 16'd1;
        end
    end

    assign pwm_left_out  = (!disarm_in && pwm_en) ? (pwm_counter < pwm_left_cmd)  : 1'b0;
    assign pwm_right_out = (!disarm_in && pwm_en) ? (pwm_counter < pwm_right_cmd) : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm_en         <= 1'b0;
            reg_left_duty  <= 16'h0;
            reg_right_duty <= 16'h0;
            wb_dat_o       <= 32'h0;
            wb_ack_o       <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;

            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (wb_adr_i[7:0])
                        8'h00: pwm_en         <= wb_dat_i[0];
                        8'h04: reg_left_duty  <= wb_dat_i[15:0];
                        8'h08: reg_right_duty <= wb_dat_i[15:0];
                        default: ;
                    endcase
                end else begin
                    case (wb_adr_i[7:0])
                        8'h00: wb_dat_o <= {31'h0, pwm_en};
                        8'h04: wb_dat_o <= {16'h0, reg_left_duty};
                        8'h08: wb_dat_o <= {16'h0, reg_right_duty};
                        8'h0C: wb_dat_o <= {31'h0, disarm_in};
                        default: wb_dat_o <= 32'h0;
                    endcase
                end
            end
        end
    end

endmodule
