# Makefile for simulation and verification
# Path portable: works whether executed from repo root or sim/ directory

SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(SIM_DIR)/..)

IVERILOG ?= iverilog
VVP ?= vvp
PYTHON ?= python3

RTL_NNA_SRCS = $(ROOT_DIR)/rtl/nna/nna_mac4.v \
               $(ROOT_DIR)/rtl/nna/nna_regs.v \
               $(ROOT_DIR)/rtl/nna/nna_core.v \
               $(ROOT_DIR)/rtl/nna/nna_top.v

RTL_SAFETY_SRCS = $(ROOT_DIR)/rtl/safety/safety_filter.v

RTL_SOC_SRCS = $(ROOT_DIR)/rtl/cpu/picorv32.v \
               $(ROOT_DIR)/rtl/bus/soc_interconnect.v \
               $(ROOT_DIR)/rtl/mem/soc_rom.v \
               $(ROOT_DIR)/rtl/mem/soc_ram.v \
               $(ROOT_DIR)/rtl/periph/soc_timer.v \
               $(ROOT_DIR)/rtl/periph/soc_uart.v \
               $(ROOT_DIR)/rtl/periph/soc_pwm.v \
               $(RTL_NNA_SRCS) \
               $(RTL_SAFETY_SRCS) \
               $(ROOT_DIR)/rtl/soc_top.v

.PHONY: all test_py test_rtl test_nna test_safety test_soc test_nav clean firmware

all: test_py test_rtl test_nav

firmware:
	@echo "--- Assembling Bare-metal Firmware ---"
	$(PYTHON) $(ROOT_DIR)/sw/firmware/assemble.py $(ROOT_DIR)/sw/firmware/soc_firmware.s $(ROOT_DIR)/sw/firmware/firmware.hex
	cd $(ROOT_DIR)/sw/firmware && riscv-none-elf-as -march=rv32im -mabi=ilp32 robot_nav_firmware.s -o robot_nav.o && riscv-none-elf-ld -m elf32lriscv -T linker.ld robot_nav.o -o robot_nav.elf && riscv-none-elf-objcopy -O binary robot_nav.elf robot_nav.bin && $(PYTHON) make_hex.py robot_nav.bin robot_nav.hex && riscv-none-elf-objdump -d robot_nav.elf > robot_nav.dump

test_py:
	@echo "--- [1/3] Running INT8 Reference Model Test ---"
	$(PYTHON) $(ROOT_DIR)/sw/model/reference_model.py
	@echo "--- [2/3] Running Python Deterministic Safety Layer Test ---"
	$(PYTHON) $(ROOT_DIR)/sw/safety/safety_layer.py
	@echo "--- [3/3] Running End-to-End Navigation Policy Simulation ---"
	PYTHONPATH=$(ROOT_DIR)/sw/model:$(ROOT_DIR)/sw/safety $(PYTHON) $(ROOT_DIR)/sw/model/robot_policy_e2e.py

test_nna:
	@echo "--- Building and Running NNA Accelerator Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(SIM_DIR)/tb_nna_top.vvp $(RTL_NNA_SRCS) $(SIM_DIR)/tb_nna_top.v
	$(VVP) $(SIM_DIR)/tb_nna_top.vvp

test_safety:
	@echo "--- Building and Running Safety Filter Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -o $(SIM_DIR)/tb_safety_filter.vvp $(RTL_SAFETY_SRCS) $(SIM_DIR)/tb_safety_filter.v
	$(VVP) $(SIM_DIR)/tb_safety_filter.vvp

test_soc: firmware
	@echo "--- Building and Running Full SoC End-to-End Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/firmware.hex\" -o $(SIM_DIR)/tb_soc_top.vvp $(RTL_SOC_SRCS) $(SIM_DIR)/tb_soc_top.v
	$(VVP) $(SIM_DIR)/tb_soc_top.vvp

test_nav: firmware
	@echo "--- Building and Running Full Navigation SoC Testbench ---"
	$(IVERILOG) -I$(ROOT_DIR)/rtl -DROM_INIT_FILE=\"$(ROOT_DIR)/sw/firmware/robot_nav.hex\" -o $(SIM_DIR)/tb_soc_nav.vvp $(RTL_SOC_SRCS) $(SIM_DIR)/tb_soc_nav.v
	$(VVP) $(SIM_DIR)/tb_soc_nav.vvp

test_rtl: test_nna test_safety test_soc

clean:
	rm -f $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd
