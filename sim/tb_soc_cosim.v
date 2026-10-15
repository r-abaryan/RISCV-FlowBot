// ============================================================================
// File: tb_soc_cosim.v
// Description: Interactive Closed-Loop Hardware-in-the-Loop Co-Simulation Testbench
// Connects the RV32IM + rv_nna Robot SoC with an external Python physics simulation.
// Communication is performed over stdin/stdout using line-oriented text commands.
// ============================================================================

`timescale 1ns / 1ps

`ifndef ROM_INIT_FILE
`define ROM_INIT_FILE "/workspace/sw/firmware/soc_cosim.hex"
`endif

module tb_soc_cosim;

    reg clk;
    reg rst_n;
    reg ext_estop_n;

    wire uart_tx;
    wire pwm_left_out;
    wire pwm_right_out;
    wire [15:0] pwm_left_cmd;
    wire [15:0] pwm_right_cmd;
    wire actuator_disarm;

    // 50 MHz Clock generation (20 ns period)
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // Instantiate SoC Top
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

    // CPU trap detection
    always @(posedge clk) begin
        if (rst_n && dut.u_cpu.trap) begin
            $fatal(1, "[COSIM TB FATAL] CPU TRAPPED! pc=0x%08x, mem_addr=0x%08x, mem_wdata=0x%08x",
                   dut.u_cpu.picorv32_core.reg_pc, dut.u_cpu.mem_addr, dut.u_cpu.mem_wdata);
        end
    end

    // Co-simulation control variables
    integer scan_res;
    reg [255:0] cmd_str;
    reg [31:0] w0, w1, w2, w3;
    reg [31:0] v_raw, w_raw, v_cmd, w_cmd, safety_trip, pwm_l, pwm_r;
    integer step_cnt;
    integer timeout_cnt;

    initial begin
        rst_n = 1'b0;
        ext_estop_n = 1'b1;
        step_cnt = 0;

        // Initialize SRAM Mailbox with "SIM1" handshake flag before reset release
        dut.u_ram.ram_mem[1024] = 32'h53494D31; // SIM_MAGIC at 0x20001000
        dut.u_ram.ram_mem[1025] = 32'h0;        // STEP_CMD = 0
        dut.u_ram.ram_mem[1026] = 32'h0;        // STEP_STATUS = 0

        #100;
        rst_n = 1'b1;

        // Wait for CPU to boot and write STEP_STATUS = 0xA0 (BOOT_READY)
        timeout_cnt = 0;
        while (dut.u_ram.ram_mem[1026] != 32'hA0) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (timeout_cnt > 100000) begin
                $display("[COSIM TB ERROR] Timeout waiting for SoC firmware boot handshake!");
                $finish(1);
            end
        end

        // Signal Python orchestrator that SoC is initialized and ready
        $display("SOC_READY");
        $fflush();

        // Main command loop
        while (1) begin
            scan_res = $fscanf(32'h80000000, "%s", cmd_str);
            if (scan_res <= 0) begin
                $finish(0);
            end

            if (cmd_str == "STEP") begin
                scan_res = $fscanf(32'h80000000, "%x %x %x %x", w0, w1, w2, w3);
                step_cnt = step_cnt + 1;

                // Load sensor inputs into SRAM Mailbox
                dut.u_ram.ram_mem[1028] = w0;
                dut.u_ram.ram_mem[1029] = w1;
                dut.u_ram.ram_mem[1030] = w2;
                dut.u_ram.ram_mem[1031] = w3;

                // Trigger execution with sequence token
                dut.u_ram.ram_mem[1025] = step_cnt; // STEP_CMD = step_cnt

                // Wait until STEP_STATUS == step_cnt (firmware finished processing this exact token)
                timeout_cnt = 0;
                while (dut.u_ram.ram_mem[1026] != step_cnt) begin
                    @(posedge clk);
                    timeout_cnt = timeout_cnt + 1;
                    if (timeout_cnt > 200000) begin
                        $display("[COSIM TB ERROR] Timeout during step %0d execution!", step_cnt);
                        $finish(1);
                    end
                end

                // Read output results from Mailbox
                v_raw       = dut.u_ram.ram_mem[1032];
                w_raw       = dut.u_ram.ram_mem[1033];
                v_cmd       = dut.u_ram.ram_mem[1034];
                w_cmd       = dut.u_ram.ram_mem[1035];
                safety_trip = dut.u_ram.ram_mem[1036];
                pwm_l       = dut.u_ram.ram_mem[1037];
                pwm_r       = dut.u_ram.ram_mem[1038];

                $display("STEP_RESULT %0d %0d %0d %0d %0d %0d %0d %0d",
                         $signed(v_raw[7:0]),
                         $signed(w_raw[7:0]),
                         $signed(v_cmd[7:0]),
                         $signed(w_cmd[7:0]),
                         safety_trip,
                         pwm_l,
                         pwm_r, timeout_cnt);
                $fflush();

            end else if (cmd_str == "SHUTDOWN") begin
                dut.u_ram.ram_mem[1025] = 32'hFFFFFFFF;
                #1000;
                $display("SOC_SHUTDOWN_ACK");
                $fflush();
                $finish(0);
            end else begin
                $display("[COSIM TB ERROR] Unknown command: %s", cmd_str);
                $finish(1);
            end
        end
    end

endmodule
