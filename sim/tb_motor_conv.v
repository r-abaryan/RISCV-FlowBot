// ============================================================================
// Testbench: tb_motor_conv  (M11b M2 step 3a, V-CONV)
// Runs sw/firmware/conv_test.hex on the full soc_top (PicoRV32 RV32IM) and
// dumps the 512 firmware conversion results (v_wheel -256..255) to
// CONV_OUT (one signed decimal per line: "<v> <cmd>"). The comparison with
// the Python reference is done by sw/test/test_motor_conv_parity.py.
// Also asserts the motors stay disarmed/zero (test ROM never arms).
// SIMULATION ONLY.
// ============================================================================
`timescale 1ns / 1ps
`ifndef ROM_INIT_FILE
    `define ROM_INIT_FILE "../sw/firmware/conv_test.hex"
`endif
`ifndef CONV_OUT
    `define CONV_OUT "tb_motor_conv.out"
`endif
module tb_motor_conv;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;               // 25 MHz nominal
    wire uart_tx, pl, pr, dl, dr, en, disarm;
    wire [15:0] cl, cr;
    soc_top #(.ROM_INIT_FILE(`ROM_INIT_FILE), .UART_CLKS_PER_BIT(16)) dut (
        .clk(clk), .rst_n(rst_n), .ext_estop_n(1'b1), .uart_tx(uart_tx),
        .pwm_left_out(pl), .pwm_right_out(pr), .pwm_left_cmd(cl), .pwm_right_cmd(cr),
        .dir_left_out(dl), .dir_right_out(dr), .motor_en_out(en),
        .actuator_disarm(disarm));
    integer cyc = 0, i, fd;
    always @(posedge clk) begin
        if (rst_n) cyc <= cyc + 1;
        if (rst_n && dut.u_cpu.trap) $fatal(1, "FATAL: CPU trap");
        if (rst_n && (en || pl || pr)) $fatal(1, "FATAL: motor output active in conv test (en=%b pl=%b pr=%b)", en, pl, pr);
        if (cyc > 400000) $fatal(1, "FATAL: conv test timeout (no token)");
    end
    initial begin
        #200 rst_n = 1;
        wait (dut.u_ram.ram_mem[4095] == 32'hC0BDC0DE);
        @(posedge clk);
        fd = $fopen(`CONV_OUT, "w");
        for (i = 0; i < 512; i = i + 1)
            $fdisplay(fd, "%0d %0d", i - 256, $signed(dut.u_ram.ram_mem[1024 + i]));
        $fclose(fd);
        $display("[CONV] cycles=%0d dumped 512 values to %s", cyc, `CONV_OUT);
        $display("[CONV-DUMP-DONE]");
        $finish;
    end
endmodule
