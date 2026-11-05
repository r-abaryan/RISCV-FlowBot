// ============================================================================
// Module: soc_pwm  (M11b Milestone 2 motor-command contract v3)
// Description: Wishbone B4 sign-magnitude motor PWM with arm/commit/stale
//              protection and hardware interlock gating.
// Base Address: 0x5000_0200
//
// Contract: /workspace/m11b_evidence/M2_CONTRACT_V3.md (+ V2 register map,
//           + M2_STEP1_DECISIONS.md rules R1-R4, zero-arm sequence).
// SIMULATION ONLY so far. STALE_CYCLES default (1,250,000) is a sim-only
// placeholder, NOT a physical safety value (B1 open). PERIOD is not the
// approved PWM frequency (B2 open). Polarity/coast/brake undecided.
//
// Register map (byte offsets):
//   0x00 CTRL    W  bit0 ARM_REQ, bit1 DISARM, bit2 FAULT_CLR (reads 0)
//   0x04 CMD_L   RW signed 16-bit staging value, sign-extended on read
//   0x08 CMD_R   RW as CMD_L
//   0x0C COMMIT  W  any value: atomic CMD_L/R -> ACTIVE_L/R (if allowed)
//   0x10 STATUS  RO bit0 ARMED, bit1 FAULT_STALE, bit2 FAULT_RANGE,
//                   bit3 WDT_TRIP (live mirror), bit4 ESTOP (live mirror),
//                   bit5 SAFE, bit6 ACTIVE_ZERO, bit7 ARM_REJECTED,
//                   bit8 ESTOP_SEEN (latched), bit9 SHADOW_ZERO,
//                   bit10 DISARM_IN (live), bits14:12 reject reason
//   0x14 ACTIVE  RO {ACTIVE_R, ACTIVE_L}
//   0x18 PARAMS  RO STALE_CYCLES
//   0x1C PERIOD  RO PERIOD
//   others: read 0, writes ignored.
//
// Per-edge priority (contract v3 section 3):
//   0 async reset
//   1 KILL = disarm_in | stale_hit | range_bad | CTRL.DISARM | fault latched
//      -> ARMED, ACTIVE, SHADOW, CMD <= 0; latch causes; same-edge
//         COMMIT/ARM_REQ discarded (ARM_REQ/FAULT_CLR -> ARM_REJECTED).
//      Exception: FAULT_CLR is evaluated when the only KILL term is
//      "fault already latched" (rule R1).
//   2 FAULT_CLR (preconditions: disarm_in=0, estop=0, ARMED=0, ACTIVE=0,
//      CMD=0). Never arms.
//   3 ARM_REQ (no fault, disarm_in=0, not already armed, ACTIVE=SHADOW=0,
//      CMD=0) -> ARMED, stale counter <= STALE_CYCLES. Never copies CMD.
//   4 COMMIT armed, in range -> ACTIVE <= CMD, stale counter reload
//   5 COMMIT not armed, in range -> ignored, no fault
//   rollover: SHADOW <= (KILL ? 0 : ACTIVE_next)
// ============================================================================

`timescale 1ns / 1ps

module soc_pwm #(
    parameter integer PERIOD       = 1000,     // PWM period in clk cycles (>= 2)
    parameter integer STALE_CYCLES = 1250000   // sim-only placeholder (>= 2)
) (
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

    // Hardware safety inputs
    input  wire        disarm_in,     // safety_filter actuator_disarm (WDT | !enable | E-stop | reset)
    input  wire        estop_in,      // live E-stop (synchronised, active-high) for ESTOP_SEEN/status
    input  wire        wdt_trip_in,   // live safety_filter trip flag, status mirror only

    // Motor outputs (sign-magnitude, logical levels; physical polarity undecided)
    output wire        pwm_left_out,
    output wire        pwm_right_out,
    output wire        dir_left_out,  // 1 = negative command
    output wire        dir_right_out,
    output wire        motor_en_out,  // 1 = outputs allowed (inactive whenever SAFE)

    // Monitors: the signed value the PWM is using this period (0 when SAFE)
    output wire [15:0] pwm_left_cmd,
    output wire [15:0] pwm_right_cmd
);

    localparam integer CMD_MAX = 1000;

    // Reject reason codes (STATUS[14:12]), first failing check wins
    localparam [2:0] RJ_NONE        = 3'd0,
                     RJ_KILL_EDGE   = 3'd1,  // request on an edge with a live KILL term
                     RJ_FAULT       = 3'd2,  // fault latched (ARM_REQ)
                     RJ_DISARM_IN   = 3'd3,  // safety_filter disarming / E-stop live
                     RJ_ARMED       = 3'd4,  // already armed
                     RJ_ACTIVE_NZ   = 3'd5,  // ACTIVE or SHADOW non-zero
                     RJ_CMD_NZ      = 3'd6;  // staged CMD non-zero

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg               armed;
    reg               fault_stale;
    reg               fault_range;
    reg               estop_seen;
    reg               arm_rejected;
    reg        [2:0]  reject_reason;
    reg signed [15:0] cmd_l, cmd_r;        // staged
    reg signed [15:0] active_l, active_r;  // committed
    reg signed [15:0] shadow_l, shadow_r;  // used by the PWM this period
    reg        [31:0] stale_cnt;
    reg        [31:0] pwm_counter;

    // ------------------------------------------------------------------
    // Bus decode (a write takes effect on the edge that sets wb_ack_o)
    // ------------------------------------------------------------------
    wire       bus_req   = wb_cyc_i && wb_stb_i && !wb_ack_o;
    wire       bus_wr    = bus_req &&  wb_we_i;
    wire       bus_rd    = bus_req && !wb_we_i;
    wire [7:0] off       = wb_adr_i[7:0];

    wire wr_ctrl   = bus_wr && (off == 8'h00);
    wire wr_cmd_l  = bus_wr && (off == 8'h04);
    wire wr_cmd_r  = bus_wr && (off == 8'h08);
    wire wr_commit = bus_wr && (off == 8'h0C);

    wire ctl_arm   = wr_ctrl && wb_dat_i[0];
    wire ctl_dis   = wr_ctrl && wb_dat_i[1];
    wire ctl_fclr  = wr_ctrl && wb_dat_i[2];

    function in_range;
        input signed [15:0] v;
        begin
            in_range = (v >= -CMD_MAX) && (v <= CMD_MAX);
        end
    endfunction

    // ------------------------------------------------------------------
    // Kill terms
    // ------------------------------------------------------------------
    wire fault_any   = fault_stale || fault_range || estop_seen;
    wire range_bad   = wr_commit && !(in_range(cmd_l) && in_range(cmd_r));   // armed or not (decision F)
    wire stale_hit   = armed && (stale_cnt == 32'd1);                        // stale wins over same-edge COMMIT
    wire kill_live   = disarm_in || stale_hit || range_bad || ctl_dis;       // terms other than "fault latched"
    wire kill        = kill_live || fault_any;

    wire active_zero = (active_l == 16'sd0) && (active_r == 16'sd0);
    wire shadow_zero = (shadow_l == 16'sd0) && (shadow_r == 16'sd0);
    wire cmd_zero    = (cmd_l == 16'sd0) && (cmd_r == 16'sd0);

    // FAULT_CLR evaluation (only reached when kill_live == 0)
    wire [2:0] fclr_reason =
        estop_in     ? RJ_DISARM_IN :
        disarm_in    ? RJ_DISARM_IN :
        armed        ? RJ_ARMED     :
        !active_zero ? RJ_ACTIVE_NZ :
        !cmd_zero    ? RJ_CMD_NZ    : RJ_NONE;

    // ARM_REQ evaluation against pre-edge state (so FAULT_CLR + ARM_REQ in one
    // write is rejected when a fault was latched; firmware uses separate writes)
    wire [2:0] arm_reason =
        fault_any                    ? RJ_FAULT     :
        disarm_in                    ? RJ_DISARM_IN :
        armed                        ? RJ_ARMED     :
        !(active_zero && shadow_zero)? RJ_ACTIVE_NZ :
        !cmd_zero                    ? RJ_CMD_NZ    : RJ_NONE;

    wire commit_ok  = wr_commit && armed && !kill;   // range ok is implied by !kill
    wire rollover   = (pwm_counter == PERIOD - 1);

    // ------------------------------------------------------------------
    // Output gating (combinational from registered flags + live disarm_in)
    // ------------------------------------------------------------------
    wire safe = !armed || fault_any || disarm_in;

    function [31:0] mag;
        input signed [15:0] v;
        begin
            mag = (v < 0) ? -{{16{v[15]}}, v} : {16'h0, v};
        end
    endfunction

    // high iff counter < floor(|s|*PERIOD/1000)  <=>  (counter+1)*1000 <= |s|*PERIOD
    wire [47:0] lhs = (pwm_counter + 48'd1) * 48'd1000;
    wire [47:0] rhs_l = mag(shadow_l) * PERIOD;
    wire [47:0] rhs_r = mag(shadow_r) * PERIOD;

    assign pwm_left_out  = !safe && (lhs <= rhs_l);
    assign pwm_right_out = !safe && (lhs <= rhs_r);
    assign dir_left_out  = !safe && shadow_l[15];
    assign dir_right_out = !safe && shadow_r[15];
    assign motor_en_out  = !safe;
    assign pwm_left_cmd  = safe ? 16'h0 : shadow_l;
    assign pwm_right_cmd = safe ? 16'h0 : shadow_r;

    // ------------------------------------------------------------------
    // PWM counter (free-running 0..PERIOD-1)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        pwm_counter <= 32'd0;
        else if (rollover) pwm_counter <= 32'd0;
        else               pwm_counter <= pwm_counter + 32'd1;
    end

    // ------------------------------------------------------------------
    // Control state
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed         <= 1'b0;
            fault_stale   <= 1'b0;
            fault_range   <= 1'b0;
            estop_seen    <= 1'b0;
            arm_rejected  <= 1'b0;
            reject_reason <= RJ_NONE;
            cmd_l         <= 16'sd0;
            cmd_r         <= 16'sd0;
            active_l      <= 16'sd0;
            active_r      <= 16'sd0;
            shadow_l      <= 16'sd0;
            shadow_r      <= 16'sd0;
            stale_cnt     <= 32'd0;
        end else begin
            // ARM_REJECTED is sticky until the next CTRL write, which re-evaluates it
            if (wr_ctrl) begin
                arm_rejected  <= 1'b0;
                reject_reason <= RJ_NONE;
            end

            // stale counter decrements every clock while armed
            if (armed && stale_cnt != 32'd0)
                stale_cnt <= stale_cnt - 32'd1;

            if (kill) begin
                // ---- Row 1: KILL ----
                armed    <= 1'b0;
                active_l <= 16'sd0;  active_r <= 16'sd0;
                shadow_l <= 16'sd0;  shadow_r <= 16'sd0;
                cmd_l    <= 16'sd0;  cmd_r    <= 16'sd0;
                stale_cnt <= 32'd0;
                if (stale_hit) fault_stale <= 1'b1;
                if (range_bad) fault_range <= 1'b1;
                if (estop_in)  estop_seen  <= 1'b1;

                if (wr_ctrl && (ctl_arm || ctl_fclr)) begin
                    if (!kill_live && ctl_fclr && !ctl_dis) begin
                        // ---- Row 2 via R1 exception: only "fault latched" ----
                        if (fclr_reason == RJ_NONE) begin
                            fault_stale <= 1'b0;
                            fault_range <= 1'b0;
                            estop_seen  <= 1'b0;
                            if (ctl_arm) begin   // ARM_REQ in same write: evaluated pre-edge -> fault
                                arm_rejected  <= 1'b1;
                                reject_reason <= RJ_FAULT;
                            end
                        end else begin
                            arm_rejected  <= 1'b1;
                            reject_reason <= fclr_reason;
                        end
                    end else if (!(ctl_dis && !ctl_arm && !ctl_fclr)) begin
                        arm_rejected  <= 1'b1;
                        reject_reason <= kill_live ? RJ_KILL_EDGE : RJ_FAULT;
                    end
                end
            end else begin
                // ---- Row 2: FAULT_CLR with no fault latched (nothing to clear) ----
                if (ctl_fclr && fclr_reason != RJ_NONE) begin
                    arm_rejected  <= 1'b1;
                    reject_reason <= fclr_reason;
                end

                // ---- Row 3: ARM_REQ ----
                if (ctl_arm) begin
                    if (arm_reason == RJ_NONE && !(ctl_fclr && fclr_reason != RJ_NONE)) begin
                        armed     <= 1'b1;
                        stale_cnt <= STALE_CYCLES;
                    end else if (arm_reason != RJ_NONE) begin
                        arm_rejected  <= 1'b1;
                        reject_reason <= arm_reason;
                    end
                end

                // ---- Staging writes (no fault, no disarm: guaranteed by !kill) ----
                if (wr_cmd_l) cmd_l <= wb_dat_i[15:0];
                if (wr_cmd_r) cmd_r <= wb_dat_i[15:0];

                // ---- Row 4/5: COMMIT ----
                if (commit_ok) begin
                    active_l  <= cmd_l;
                    active_r  <= cmd_r;
                    stale_cnt <= STALE_CYCLES;
                end

                // ---- Rollover: load the period shadow ----
                if (rollover) begin
                    shadow_l <= commit_ok ? cmd_l : active_l;
                    shadow_r <= commit_ok ? cmd_r : active_r;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Wishbone ack / read data
    // ------------------------------------------------------------------
    wire [31:0] status_word = {17'h0,
                               reject_reason,      // 14:12
                               1'b0,               // 11
                               disarm_in,          // 10
                               shadow_zero,        // 9
                               estop_seen,         // 8
                               arm_rejected,       // 7
                               active_zero,        // 6
                               safe,               // 5
                               estop_in,           // 4
                               wdt_trip_in,        // 3
                               fault_range,        // 2
                               fault_stale,        // 1
                               armed};             // 0

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= 32'h0;
        end else begin
            wb_ack_o <= bus_req;
            if (bus_rd) begin
                case (off)
                    8'h04:   wb_dat_o <= {{16{cmd_l[15]}}, cmd_l};
                    8'h08:   wb_dat_o <= {{16{cmd_r[15]}}, cmd_r};
                    8'h10:   wb_dat_o <= status_word;
                    8'h14:   wb_dat_o <= {active_r, active_l};
                    8'h18:   wb_dat_o <= STALE_CYCLES;
                    8'h1C:   wb_dat_o <= PERIOD;
                    default: wb_dat_o <= 32'h0;
                endcase
            end
        end
    end

endmodule
