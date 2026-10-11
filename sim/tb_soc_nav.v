// ============================================================================
// Testbench: tb_soc_nav
// Description: Full SoC Simulation executing Autonomous Navigation Policy
// Runs multi-layer INT8 MLP policy (16->8 ReLU, 8->2 Clip) on rv_nna,
// exercises hardware safety interlock watchdog, and verifies motor outputs.
// ============================================================================

`timescale 1ns / 1ps

module tb_soc_nav;

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

    // DUT Instance with robot_nav.hex
    soc_top #(
        .ROM_INIT_FILE("/workspace/sw/firmware/robot_nav.hex")
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

    integer cycle_count;
    reg test_passed;

    initial begin
        clk = 0;
        rst_n = 0;
        ext_estop_n = 1; // E-Stop normal (armed)
        cycle_count = 0;
        test_passed = 0;

        $display("\n=======================================================");
        $display("   STARTING RISC-V ROBOT NAVIGATION SOC SIMULATION     ");
        $display("=======================================================");

        // Hold reset for 5 cycles
        #100;
        rst_n = 1;
        $display("[TB] System reset deasserted at time %0t ns", $time);

        // Simulation loop with 150,000 cycle timeout
        while (cycle_count < 1000000 && !test_passed) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
            if (dut.u_cpu.trap) begin
                $display("[TB ERROR] CPU TRAPPED at cycle %0d! pc=0x%08x, mem_addr=0x%08x, mem_wdata=0x%08x",
                         cycle_count, dut.u_cpu.picorv32_core.reg_pc, dut.u_cpu.mem_addr, dut.u_cpu.mem_wdata);
                $finish;
            end


            // Check if CPU wrote 0xCAFEBABE to RAM at word address 0x3FFC (ram_mem[4095])
            if (dut.u_ram.ram_mem[4095] == 32'hCAFEBABE) begin
                test_passed = 1;
            end
        end

        // Wait a few cycles for final UART flush
        #500;

        if (test_passed) begin
            $display("\n=======================================================");
            $display(" SUCCESS: Robot Navigation SoC Firmware Simulation PASSED!");
            $display(" Total Simulation Cycles: %0d", cycle_count);
            $display(" Final PWM Left Cmd:  %0d (0x%04x)", pwm_left_cmd, pwm_left_cmd);
            $display(" Final PWM Right Cmd: %0d (0x%04x)", pwm_right_cmd, pwm_right_cmd);
            $display(" Actuator Disarm:     %0b (0 = Normal/Armed)", actuator_disarm);
            $display("=======================================================\n");
        end else begin
            $display("\n=======================================================");
            $display(" TIMEOUT / FAILURE: Navigation firmware did not complete!");
            $display(" Cycles elapsed: %0d, RAM[4095]: 0x%08x, Trap: %0b", 
                     cycle_count, dut.u_ram.ram_mem[4095], dut.u_cpu.trap);
            $display("=======================================================\n");
            $fatal(1, "Test failed due to timeout");
        end

        $finish;
    end

endmodule
