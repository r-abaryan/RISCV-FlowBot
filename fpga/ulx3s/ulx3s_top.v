// ULX3S (LFE5U-85F) board wrapper for soc_top. M8C feasibility only: NOT hardware-tested.
// - 25 MHz board oscillator used directly (no PLL).
// - rst_n: BTN_PWRn (btn[0]); per emard LPF it is "inverted logic", assumed high when released. UNVERIFIED on hardware.
// - ext_estop_n: DIP sw[0]. Polarity of "on" is UNVERIFIED; sw[0]=0 is treated as E-stop tripped (fail-safe default).
// - PWM/disarm shown on LEDs; the 32 *_cmd monitor bits are intentionally left unconnected.
module ulx3s_top (
    input  wire       clk_25mhz,
    input  wire       btn0,
    input  wire       sw0,
    output wire       ftdi_rxd,   // FPGA -> FTDI (our uart_tx)
    output wire [7:0] led
);
    // 2-FF synchronisers. Both inputs are asynchronous to clk.
    reg [1:0] rst_sync   = 2'b00;
    reg [1:0] estop_sync = 2'b00;  // power-up state: E-stop tripped, reset asserted
    always @(posedge clk_25mhz) begin
        rst_sync   <= {rst_sync[0],   btn0};
        estop_sync <= {estop_sync[0], sw0};
    end
    wire rst_n_s = rst_sync[1];
    wire estop_n_s = estop_sync[1];

    wire pwm_l, pwm_r, disarm;
    wire [15:0] cmd_l_unused, cmd_r_unused;

    soc_top #(.ROM_INIT_FILE("sw/firmware/robot_nav.hex")) u_soc (
        .clk(clk_25mhz), .rst_n(rst_n_s), .ext_estop_n(estop_n_s),
        .uart_tx(ftdi_rxd),
        .pwm_left_out(pwm_l), .pwm_right_out(pwm_r),
        .pwm_left_cmd(cmd_l_unused), .pwm_right_cmd(cmd_r_unused),
        .actuator_disarm(disarm)
    );
    assign led = {5'b0, pwm_r, pwm_l, disarm};
endmodule
