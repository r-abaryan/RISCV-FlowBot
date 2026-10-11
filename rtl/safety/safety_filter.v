// ============================================================================
// Module: safety_filter
// Description: Deterministic Hardware Safety Watchdog and Interlock Module
// Automatically isolates actuators if software hangs or E-Stop is asserted
// ============================================================================

`timescale 1ns / 1ps

module safety_filter (
    input  wire        clk,
    input  wire        rst_n,

    // Bus Interface (Slave)
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,
    output wire        bus_ready,

    // External Physical Safety Pins
    input  wire        pin_estop_button,    // External active-high E-Stop bumper
    output wire        actuator_disarm      // Forced high on trip to disarm PWM gates
);

    wire bus_sel = bus_req && (bus_addr[31:8] == 24'h500006);
    assign bus_ready = bus_sel;

    // Secret unlock key to refresh watchdog
    localparam [31:0] HEARTBEAT_KEY = 32'h5AFE_C0DE;

    reg        reg_enable;
    reg [31:0] reg_timeout_val;
    reg [31:0] wdt_countdown;
    reg        flag_wdt_expired;
    reg        flag_tripped;

    assign actuator_disarm = (!rst_n) || (!reg_enable) || flag_tripped || pin_estop_button;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_enable       <= 1'b1;         // Enabled by default on reset
            reg_timeout_val  <= 32'd2500000;  // Default 50ms at 50MHz
            wdt_countdown    <= 32'd2500000;
            flag_wdt_expired <= 1'b0;
            flag_tripped     <= 1'b0;
        end else begin
            // Watchdog Countdown
            if (reg_enable && !flag_tripped) begin
                if (pin_estop_button) begin
                    flag_tripped <= 1'b1;
                end else if (wdt_countdown > 32'd0) begin
                    wdt_countdown <= wdt_countdown - 32'd1;
                end else begin
                    flag_wdt_expired <= 1'b1;
                    flag_tripped     <= 1'b1;
                end
            end

            // Bus Register Writes
            if (bus_sel && bus_we) begin
                case (bus_addr[7:0])
                    8'h00: begin // SAFETY_CTRL
                        if (bus_wstrb[0]) begin
                            reg_enable <= bus_wdata[0];
                            if (bus_wdata[1]) begin // Clear trip
                                flag_tripped     <= 1'b0;
                                flag_wdt_expired <= 1'b0;
                                wdt_countdown    <= reg_timeout_val;
                            end
                        end
                    end
                    8'h04: begin // HEARTBEAT REFRESH
                        if (bus_wdata == HEARTBEAT_KEY) begin
                            wdt_countdown <= reg_timeout_val;
                        end
                    end
                    8'h0C: begin // TIMEOUT_VAL
                        reg_timeout_val <= bus_wdata;
                    end
                    default: ;
                endcase
            end
        end
    end

    // Bus Register Reads
    always @(*) begin
        case (bus_addr[7:0])
            8'h00: bus_rdata = {31'h0, reg_enable};
            8'h04: bus_rdata = wdt_countdown;
            8'h08: bus_rdata = {28'h0, pin_estop_button, flag_wdt_expired, flag_tripped, reg_enable};
            8'h0C: bus_rdata = reg_timeout_val;
            default: bus_rdata = 32'h0;
        endcase
    end

endmodule
