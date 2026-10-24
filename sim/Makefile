# Sim Makefile for RISC-V Robot SoC

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

PYTHON ?= python3
IVERILOG ?= iverilog
# M11b closure: -N makes vvp exit non-zero on $$stop / interrupt (plain vvp traps
# SIGTERM from `timeout` and exits 0, so a killed run could look like a pass).
VVP ?= vvp -N
# Checked runner: PASS only if vvp rc==0 AND explicit success markers are present.
VVP_CHECKED = sh $(ROOT_DIR)/sim/run_vvp_checked.sh
YOSYS ?= yosys

RTL_SRCS = \
	$(ROOT_DIR)/rtl/nna/nna_mac4.v \
	$(ROOT_DIR)/rtl/nna/nna_regs.v \
	$(ROOT_DIR)/rtl/nna/nna_core.v \
	$(ROOT_DIR)/rtl/nna/nna_top.v \
	$(ROOT_DIR)/rtl/safety/safety_filter.v \
	$(ROOT_DIR)/rtl/periph/soc_uart.v \
	$(ROOT_DIR)/rtl/periph/soc_timer.v \
	$(ROOT_DIR)/rtl/periph/soc_pwm.v \
	$(ROOT_DIR)/rtl/bus/soc_interconnect.v \
	$(ROOT_DIR)/rtl/mem/soc_rom.v \
	$(ROOT_DIR)/rtl/mem/soc_ram.v \
	$(ROOT_DIR)/rtl/cpu/picorv32.v \
	$(ROOT_DIR)/rtl/soc_top.v

.PHONY: test_rl_nna test_safety_hw all sim firmware test_py test_nna_corners test_nna test_safety test_soc test_nav test_nna_corners_sim test_safety_adv test_trained_nna test_quant test_cosim test_uart test_ulx3s_top synth_check clean

all: test_py test_nna_corners test_quant test_rtl test_trained_nna test_rl_nna test_nav

firmware:
	@echo "--- Assembling Bare-metal Firmware ---"
	$(PYTHON) $(ROOT_DIR)/sw/firmware/assemble.py $(ROOT_DIR)/sw/firmware/soc_firmware.s $(ROOT_DIR)/sw/firmware/firmware.hex
	@if command -v riscv-none-elf-as >/dev/null 2>&1; then \
		cd $(ROOT_DIR)/sw/firmware && \
		riscv-none-elf-as -march=rv32im -mabi=ilp32 robot_nav_firmware.s -o robot_nav.o && \
		riscv-none-elf-ld -m elf32lriscv -T linker.ld robot_nav.o -o robot_nav.elf && \
		riscv-none-elf-objcopy -O binary robot_nav.elf robot_nav.bin && \
		$(PYTHON) make_hex.py robot_nav.bin robot_nav.hex && \
		(riscv-none-elf-objdump -d robot_nav.elf > robot_nav.dump 2>/dev/null || true) && \
		riscv-none-elf-as -march=rv32im -mabi=ilp32 soc_cosim_firmware.s -o soc_cosim.o && \
		riscv-none-elf-ld -m elf32lriscv -T linker.ld soc_cosim.o -o soc_cosim.elf && \
		riscv-none-elf-objcopy -O binary soc_cosim.elf soc_cosim.bin && \
		$(PYTHON) make_hex.py soc_cosim.bin soc_cosim.hex && \
		(riscv-none-elf-objdump -d soc_cosim.elf > soc_cosim.dump 2>/dev/null || true); \
	elif [ -f $(ROOT_DIR)/sw/firmware/robot_nav.hex ] && [ -f $(ROOT_DIR)/sw/firmware/soc_cosim.hex ]; then \
		echo "Using pre-built hex files (riscv-none-elf-as not found in PATH)"; \
	else \
		echo "Error: riscv-none-elf-as not found and prebuilt hex missing" >&2; exit 1; \
	fi

test_py:
	@echo "--- [1/4] Running INT8 Reference Model Test ---"
	$(PYTHON) $(ROOT_DIR)/sw/model/reference_model.py
	@echo "--- [2/4] Running Independent Vector Verification ---"
	$(PYTHON) $(ROOT_DIR)/sim/verify_independent_vectors.py
	@echo "--- [3/4] Running Python Deterministic Safety Layer Test ---"
	$(PYTHON) $(ROOT_DIR)/sw/safety/safety_layer.py
	$(PYTHON) $(ROOT_DIR)/sw/test/test_safety_fault_injection.py
	$(PYTHON) $(ROOT_DIR)/sw/test/test_safety_c_mirror.py
	$(PYTHON) $(ROOT_DIR)/sw/test/test_safety_c_compiled.py
	$(PYTHON) $(ROOT_DIR)/sw/test/test_rl_export.py
	$(PYTHON) $(ROOT_DIR)/sw/test/test_rom_bounds.py
	@echo "--- [4/4] Running End-to-End Navigation Policy Simulation ---"
	PYTHONPATH=$(ROOT_DIR)/sw/model:$(ROOT_DIR)/sw/safety $(PYTHON) $(ROOT_DIR)/sw/model/robot_policy_e2e.py

test_nna_corners:
	@echo "--- Running Python INT8 Accelerator Corner-Case & Fuzzing Suite ---"
	$(PYTHON) $(ROOT_DIR)/sw/test/test_nna_corners.py

test_quant:
	@echo "--- Running INT8 Policy Quantization Loss & Fidelity Suite ---"
	$(PYTHON) $(ROOT_DIR)/sw/test/verify_quantization.py

test_nna:
	@echo "--- Building and Running NNA Accelerator Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_nna_top.vvp \
		$(ROOT_DIR)/rtl/nna/nna_mac4.v \
		$(ROOT_DIR)/rtl/nna/nna_regs.v \
		$(ROOT_DIR)/rtl/nna/nna_core.v \
		$(ROOT_DIR)/rtl/nna/nna_top.v \
		$(ROOT_DIR)/sim/tb_nna_top.v
	$(VVP) $(ROOT_DIR)/sim/tb_nna_top.vvp

test_safety:
	@echo "--- Building and Running Safety Filter Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_safety_filter.vvp \
		$(ROOT_DIR)/rtl/safety/safety_filter.v \
		$(ROOT_DIR)/sim/tb_safety_filter.v
	$(VVP) $(ROOT_DIR)/sim/tb_safety_filter.vvp

test_nna_corners_sim:
	@echo "--- Building and Running NNA RTL Corner-Case Verification Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_nna_corner_cases.vvp \
		$(ROOT_DIR)/rtl/nna/nna_mac4.v \
		$(ROOT_DIR)/rtl/nna/nna_regs.v \
		$(ROOT_DIR)/rtl/nna/nna_core.v \
		$(ROOT_DIR)/rtl/nna/nna_top.v \
		$(ROOT_DIR)/sim/tb_nna_corner_cases.v
	$(VVP) $(ROOT_DIR)/sim/tb_nna_corner_cases.vvp

test_safety_hw:
	@echo "--- Building and Running Safety HW Register Interface Testbench (M7A) ---"
	$(IVERILOG) -g2012 -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_safety_hw_interface.vvp \
		$(ROOT_DIR)/rtl/safety/safety_filter.v \
		$(ROOT_DIR)/sim/tb_safety_hw_interface.v
	$(VVP) $(ROOT_DIR)/sim/tb_safety_hw_interface.vvp

test_safety_adv:
	@echo "--- Building and Running Adversarial Safety Filter Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_safety_adversarial.vvp \
		$(ROOT_DIR)/rtl/safety/safety_filter.v \
		$(ROOT_DIR)/sim/tb_safety_adversarial.v
	$(VVP) $(ROOT_DIR)/sim/tb_safety_adversarial.vvp

test_trained_nna:
	@echo "--- Building and Running Trained Policy rv_nna Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_nna_trained_policy.vvp \
		$(ROOT_DIR)/rtl/nna/nna_mac4.v \
		$(ROOT_DIR)/rtl/nna/nna_regs.v \
		$(ROOT_DIR)/rtl/nna/nna_core.v \
		$(ROOT_DIR)/rtl/nna/nna_top.v \
		$(ROOT_DIR)/sim/tb_nna_trained_policy.v
	$(VVP) $(ROOT_DIR)/sim/tb_nna_trained_policy.vvp

# RL seed-1 bit-exact test (weights from rl_seed1_policy.json, cross-checked vs nav_weights.inc by gen_rl_vectors.py)
test_rl_nna:
	@echo "--- Building and Running RL seed-1 Policy rv_nna Testbench ---"
	$(PYTHON) $(ROOT_DIR)/sim/gen_rl_vectors.py
	cd $(ROOT_DIR) && $(PYTHON) sim/generate_tb_trained.py --rl
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(ROOT_DIR)/sim/tb_nna_rl_policy.vvp \
		$(ROOT_DIR)/rtl/nna/nna_mac4.v \
		$(ROOT_DIR)/rtl/nna/nna_regs.v \
		$(ROOT_DIR)/rtl/nna/nna_core.v \
		$(ROOT_DIR)/rtl/nna/nna_top.v \
		$(ROOT_DIR)/sim/tb_nna_rl_policy.v
	$(VVP) $(ROOT_DIR)/sim/tb_nna_rl_policy.vvp

test_soc: firmware
	@echo "--- Building and Running Full SoC Integration Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/firmware.hex\" \
		-o $(ROOT_DIR)/sim/tb_soc_top.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_top.v
	$(VVP) $(ROOT_DIR)/sim/tb_soc_top.vvp

test_nav: firmware
	@echo "--- Building and Running End-to-End Robot Navigation Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/robot_nav.hex\" \
		-o $(ROOT_DIR)/sim/tb_soc_nav.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_soc_nav.log \
		--require "SUCCESS: All 8 Navigation SoC Hardware Assertions PASSED!" \
		$(ROOT_DIR)/sim/tb_soc_nav.vvp

# M11b watchdog-budget regression at the board UART divider (217 = 25 MHz / 115200).
# Runs the navigation firmware past the PASS token (pass banner + idle loop) with a
# passive monitor that fails on any watchdog trip or a refresh gap > 250,000 cycles
# (50% of the firmware's 500,000-cycle timeout). Slow (~minutes); not in test_rtl.
# DIV217_POST_PASS shortens the post-pass window on slow hosts. The ~162-char
# pass banner takes ~352k cycles at div 217 (10 bits x 217 per char), and the
# original trip happened inside it, so keep it >= 400000 for a regression run;
# shorter windows only smoke-test the harness.
DIV217_POST_PASS ?= 1000000
test_nav_div217: firmware
	@echo "--- Navigation firmware at UART_DIV=217 with watchdog-budget monitor ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/robot_nav.hex\" \
		-DUART_DIV=217 -DNAV_MAX_CYCLES=3000000 -DNAV_TIME_LIMIT_NS=200000000 -DNAV_POST_PASS_CYCLES=$(DIV217_POST_PASS) \
		-o $(ROOT_DIR)/sim/tb_soc_nav_div217.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v $(ROOT_DIR)/sim/wdt_kick_monitor.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_soc_nav_div217.log \
		--require "SUCCESS: All 8 Navigation SoC Hardware Assertions PASSED!" \
		--require "[WDTMON-PASS]" \
		$(ROOT_DIR)/sim/tb_soc_nav_div217.vvp

# ---------------------------------------------------------------------------
# M11b Milestone 1 closure tests (simulation only; slow, not in test_rtl).
# Shared defines for the post-pass window runs (same as test_nav_div217).
NAV_LONG_DEFS = -DNAV_MAX_CYCLES=3000000 -DNAV_TIME_LIMIT_NS=200000000 -DNAV_POST_PASS_CYCLES=1000000
NAV_HEX_DEF = -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/robot_nav.hex\"

# Negative controls: force u_uart.busy=1 (UART stuck busy) from reset (mode 0) or
# from the pass token (mode 1) at UART_DIV=16. The firmware's UART wait loop must
# NOT keep the watchdog alive: PASS iff the watchdog trips, the TB $fatal's with a
# non-signal exit code, and the [STALL] trip line is logged.
test_wdt_uart_stall: firmware
	@echo "--- UART-stall negative control, mode 0 (stuck from reset) ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl $(NAV_HEX_DEF) -DUART_DIV=16 $(NAV_LONG_DEFS) -DSTALL_MODE=0 \
		-o $(ROOT_DIR)/sim/tb_uart_stall_m0.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v $(ROOT_DIR)/sim/uart_stall_inject.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_uart_stall_m0.log \
		--expect-fail "flag_wdt_expired=1 disarm=1 pwm_cmd L=0 R=0" --expect-fail "watchdog tripped unexpectedly" \
		$(ROOT_DIR)/sim/tb_uart_stall_m0.vvp
	@echo "--- UART-stall negative control, mode 1 (stuck at pass token) ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl $(NAV_HEX_DEF) -DUART_DIV=16 $(NAV_LONG_DEFS) -DSTALL_MODE=1 \
		-o $(ROOT_DIR)/sim/tb_uart_stall_m1.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v $(ROOT_DIR)/sim/uart_stall_inject.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_uart_stall_m1.log \
		--expect-fail "flag_wdt_expired=1 disarm=1 pwm_cmd L=0 R=0" --expect-fail "watchdog tripped unexpectedly" \
		$(ROOT_DIR)/sim/tb_uart_stall_m1.vvp

# Characterization (NOT an acceptance test): records the known idle-state PWM
# persistence (duty L=410/R=589, pwm_en=1 after the pass token) at UART_DIV=16
# and 217. Passes as long as the run completes; read [PWMPROBE-END] in the logs.
# Overridable for slow hosts, e.g. make char_pwm_idle CHAR_DIVS=217
# CHAR_POST_PASS=200000 CHAR_PROBE_WIN=131072 (window = 2 PWM periods of 65536).
CHAR_DIVS ?= 16 217
CHAR_POST_PASS ?= 1000000
CHAR_PROBE_WIN ?= 524288
char_pwm_idle: firmware
	@for d in $(CHAR_DIVS); do \
		echo "--- Idle-state PWM characterization, UART_DIV=$$d ---"; \
		$(IVERILOG) -I$(ROOT_DIR)/rtl $(NAV_HEX_DEF) -DUART_DIV=$$d \
			-DNAV_MAX_CYCLES=3000000 -DNAV_TIME_LIMIT_NS=200000000 \
			-DNAV_POST_PASS_CYCLES=$(CHAR_POST_PASS) -DPROBE_WIN=$(CHAR_PROBE_WIN) \
			-o $(ROOT_DIR)/sim/tb_pwm_idle_div$$d.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v \
			$(ROOT_DIR)/sim/wdt_kick_monitor.v $(ROOT_DIR)/sim/pwm_idle_probe.v || exit 1; \
		$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_pwm_idle_div$$d.log \
			--require "SUCCESS: All 8 Navigation SoC Hardware Assertions PASSED!" \
			--require "[WDTMON-PASS]" --require "[PWMPROBE-END]" \
			$(ROOT_DIR)/sim/tb_pwm_idle_div$$d.vvp || exit 1; \
		grep "PWMPROBE-END" $(ROOT_DIR)/sim/tb_pwm_idle_div$$d.log; \
	done

# Termination-path checks: each run is deliberately broken and MUST fail with a
# non-signal exit code and no PASS verdict.
#  T1 gap budget 100 cycles (< any real gap), 50k-cycle window -> [WDTMON-FAIL]
#  T2 NAV_MAX_CYCLES=60000 (< pass token ~122k; the TB cycle counter stops at
#     the pass token, so the limit only applies before it) -> [WDTMON-INCOMPLETE] cycle limit
#  T3 NAV_TIME_LIMIT_NS=2 ms (~100k cyc, before the pass token) -> [WDTMON-INCOMPLETE] time limit
test_sim_termination: firmware
	$(IVERILOG) -I$(ROOT_DIR)/rtl $(NAV_HEX_DEF) -DUART_DIV=16 -DNAV_MAX_CYCLES=3000000 -DNAV_TIME_LIMIT_NS=200000000 -DNAV_POST_PASS_CYCLES=50000 -DWDT_MAX_GAP_CYCLES=100 \
		-o $(ROOT_DIR)/sim/tb_term_t1.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v $(ROOT_DIR)/sim/wdt_kick_monitor.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_term_t1.log --expect-fail "[WDTMON-FAIL] max refresh gap" $(ROOT_DIR)/sim/tb_term_t1.vvp
	$(IVERILOG) -I$(ROOT_DIR)/rtl $(NAV_HEX_DEF) -DUART_DIV=16 -DNAV_MAX_CYCLES=60000 -DNAV_TIME_LIMIT_NS=200000000 -DNAV_POST_PASS_CYCLES=1000000 \
		-o $(ROOT_DIR)/sim/tb_term_t2.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v $(ROOT_DIR)/sim/wdt_kick_monitor.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_term_t2.log --expect-fail "[WDTMON-INCOMPLETE] run ended by TB cycle limit" $(ROOT_DIR)/sim/tb_term_t2.vvp
	@! grep -q "WDTMON-PASS" $(ROOT_DIR)/sim/tb_term_t2.log
	$(IVERILOG) -I$(ROOT_DIR)/rtl $(NAV_HEX_DEF) -DUART_DIV=16 -DNAV_MAX_CYCLES=3000000 -DNAV_TIME_LIMIT_NS=2000000 -DNAV_POST_PASS_CYCLES=1000000 \
		-o $(ROOT_DIR)/sim/tb_term_t3.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_nav.v $(ROOT_DIR)/sim/wdt_kick_monitor.v
	$(VVP_CHECKED) --log $(ROOT_DIR)/sim/tb_term_t3.log --expect-fail "[WDTMON-INCOMPLETE] run ended by TB time limit" \
		--expect-fail "[TB] TIME LIMIT:" $(ROOT_DIR)/sim/tb_term_t3.vvp
	@! grep -q "WDTMON-PASS" $(ROOT_DIR)/sim/tb_term_t3.log

# Self-test of the checked runner itself (seconds): a run killed by SIGTERM, a
# missing success marker and a $$fatal must all be rejected; a clean run accepted.
test_vvp_runner: 
	sh $(ROOT_DIR)/sim/test_run_vvp_checked.sh

test_cosim: firmware
	@echo "--- Building and Running Closed-Loop Co-Simulation Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/soc_cosim.hex\" \
		-o $(ROOT_DIR)/sim/tb_soc_cosim.vvp $(RTL_SRCS) $(ROOT_DIR)/sim/tb_soc_cosim.v
	$(PYTHON) $(ROOT_DIR)/sim/soc_closed_loop_cosim.py --steps 10 --episodes 1

test_rtl: test_nna test_safety test_safety_hw test_nna_corners_sim test_safety_adv test_soc test_uart

# D-B UART unit test (divider 8)
test_uart:
	@echo "--- Running UART unit testbench (divider 8) ---"
	$(IVERILOG) -g2012 -o $(ROOT_DIR)/sim/tb_soc_uart.vvp $(ROOT_DIR)/rtl/periph/soc_uart.v $(ROOT_DIR)/sim/tb_soc_uart.v
	$(VVP) $(ROOT_DIR)/sim/tb_soc_uart.vvp | tee $(ROOT_DIR)/sim/tb_soc_uart.log
	@grep -q "TB_SOC_UART PASS" $(ROOT_DIR)/sim/tb_soc_uart.log

# ULX3S wrapper pin-decode test (slow, ~minutes; not in test_rtl). Run from repo root cwd.
test_ulx3s_top:
	cd $(ROOT_DIR) && $(IVERILOG) -g2012 -I rtl -o sim/tb_ulx3s_top.vvp $(RTL_SRCS) fpga/ulx3s/ulx3s_top.v sim/tb_ulx3s_top.v
	cd $(ROOT_DIR) && $(VVP) sim/tb_ulx3s_top.vvp | tee sim/tb_ulx3s_top.log
	@grep -q "fails=0" $(ROOT_DIR)/sim/tb_ulx3s_top.log

synth_check:
	@echo "--- Running Yosys RTL Syntax & Elaboration Check ---"
	$(YOSYS) -p "read_verilog -I$(ROOT_DIR)/rtl $(RTL_SRCS); hierarchy -check -top soc_top; check"

clean:
	rm -f $(ROOT_DIR)/sim/*.vvp $(ROOT_DIR)/sim/*.vcd

.PHONY: test_rom_layout test_wdt_negative test_nav_div217 test_wdt_uart_stall char_pwm_idle test_sim_termination test_vvp_runner
test_rom_layout: firmware
	python3 $(ROOT_DIR)/sw/test/test_rom_layout.py && python3 $(ROOT_DIR)/sw/test/test_rom_layout.py --selftest
	python3 $(ROOT_DIR)/sw/test/test_nav_expected.py

test_wdt_negative: firmware
	sh $(ROOT_DIR)/sim/run_wdt_negative.sh

# M7D/M10b/M10c: SoC-executed assembly safety boundary tests. Default = full coverage (15 items, ~7 min,
# incl. rev/revmut/revbase); run subsets via ARGS="scen:slew_open"
test_nav_boundaries:
	python3 ../sw/test/test_nav_boundaries.py $(ARGS)
test_front_sensor_mapping:
	python3 ../sw/test/test_front_sensor_mapping.py
.PHONY: test_nav_boundaries test_front_sensor_mapping
