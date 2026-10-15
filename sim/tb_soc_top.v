// ============================================================================
// Testbench: tb_soc_top
// Description: End-to-End Simulation of RV32IM Mobile Robot SoC
// Executes ROM Firmware -> rv_nna Policy Inference -> Safety Check -> PWM Drive
// Hardened with watchdog timer, strict assertions, and fatal exit codes.
// ============================================================================

`timescale 1ns / 1ps

`ifndef ROM_INIT_FILE
    `define ROM_INIT_FILE "../sw/firmware/firmware.hex"
`endif

module tb_soc_top;

    reg clk;
    reg rst_n;
    reg ext_estop_n;

    wire uart_tx;
    wire pwm_left_out;
    wire pwm_right_out;
    wire [15:0] pwm_left_cmd;
    wire [15:0] pwm_right_cmd;
    wire actuator_disarm;

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // Watchdog Timeout (100,000 cycles / 2ms)
    initial begin
        #2000000;
        $fatal(1, "[TB FATAL] Simulation watchdog timeout reached (2ms) in tb_soc_top!");
    end

    // DUT Instance
    soc_top #(
        .ROM_INIT_FILE(`ROM_INIT_FILE),
        .UART_CLKS_PER_BIT(4) // fast UART keeps legacy sim budgets (M8E)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .ext_estop_n     (ext_estop_n),
        .uart_tx         (uart_tx),
        .pwm_left_out    (pwm_left_out),
        .pwm_right_out   (pwm_right_out),
        .pwm_left_cmd    (pwm_left_cmd),
        .pwm_right_cmd   (pwm_right_cmd),
        .actuator_disarm (actuator_disarm)
    );

    // Trap monitor
    always @(posedge clk) begin
        if (rst_n && dut.u_cpu.trap) begin
            $fatal(1, "[TB FATAL] CPU TRAP Asserted at time %0t! PC=0x%08x", $time, dut.u_cpu.picorv32_core.reg_pc);
        end
    end

    // Monitor RAM writes for magic success token 0xCAFEBABE
    integer cycle_count;
    reg test_passed;

    initial begin
        clk = 0;
        rst_n = 0;
        ext_estop_n = 1; // E-Stop not pressed
        cycle_count = 0;
        test_passed = 0;

        $display("\n=======================================================");
        $display("   STARTING RISC-V ROBOT SOC FULL SYSTEM SIMULATION    ");
        $display("   ROM: %s", `ROM_INIT_FILE);
        $display("=======================================================");

        // Hold reset for 5 cycles
        #100;
        rst_n = 1;
        $display("[TB] System reset deasserted at time %0t ns", $time);

        // Simulation loop with 15,000 cycle timeout
        while (cycle_count < 15000 && !test_passed) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            // Check if CPU wrote 0xCAFEBABE to RAM at word address 0x3FFC
            // Word address 0x3FFC in RAM is ram_mem[4095]
            if (dut.u_ram.ram_mem[4095] == 32'hCAFEBABE) begin
                test_passed = 1;
            end
        end

        if (test_passed) begin
            $display("\n=======================================================");
            $display(" SUCCESS: Robot SoC End-to-End System Test PASSED!    ");
            $display(" Cycles taken: %0d", cycle_count);
            $display(" NNA Inference Result in RAM[0x100]: 0x%08x", dut.u_ram.ram_mem[64]);
            $display(" NNA Execution Latency in RAM[0x104]: %0d cycles", dut.u_ram.ram_mem[65]);
            $display(" PWM Left Command:  %0d (0x%04x)", pwm_left_cmd, pwm_left_cmd);
            $display(" PWM Right Command: %0d (0x%04x)", pwm_right_cmd, pwm_right_cmd);
            $display(" Safety Interlock Disarmed: %0b (0 = Armed/Operational)", actuator_disarm);
            $display("=======================================================\n");
            $finish(0);
        end else begin
            $display("\n=======================================================");
            $display(" TIMEOUT / FAILURE: SoC did not reach completion token!");
            $display(" Cycles: %0d, RAM[4095]: 0x%08x", cycle_count, dut.u_ram.ram_mem[4095]);
            $display("=======================================================\n");
            $fatal(1, "[TB FATAL] SoC firmware failed to write CAFEBABE completion token!");
        end
    end

endmodule
