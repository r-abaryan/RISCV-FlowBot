# Sim Makefile for RISC-V Robot SoC

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
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
	$(VVP) $(ROOT_DIR)/sim/tb_soc_nav.vvp

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

.PHONY: test_rom_layout test_wdt_negative
test_rom_layout: firmware
	python3 $(ROOT_DIR)/sw/test/test_rom_layout.py && python3 $(ROOT_DIR)/sw/test/test_rom_layout.py --selftest
	python3 $(ROOT_DIR)/sw/test/test_nav_expected.py

test_wdt_negative: firmware
	sh $(ROOT_DIR)/sim/run_wdt_negative.sh

# M7D: SoC-executed assembly safety boundary tests (slow: ~50 s per simulated item; run subsets via ARGS="scen:slew_open")
test_nav_boundaries:
	python3 ../sw/test/test_nav_boundaries.py $(ARGS)
test_front_sensor_mapping:
	python3 ../sw/test/test_front_sensor_mapping.py
.PHONY: test_nav_boundaries test_front_sensor_mapping
