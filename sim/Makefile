# Makefile for simulation and verification

IVERILOG = iverilog
VVP = vvp
PYTHON = python3

RTL_NNA_SRCS = /workspace/rtl/nna/nna_mac4.v \
               /workspace/rtl/nna/nna_regs.v \
               /workspace/rtl/nna/nna_core.v \
               /workspace/rtl/nna/nna_top.v

RTL_SAFETY_SRCS = /workspace/rtl/safety/safety_filter.v

RTL_SOC_SRCS = /workspace/rtl/cpu/picorv32.v \
               /workspace/rtl/bus/soc_interconnect.v \
               /workspace/rtl/mem/soc_rom.v \
               /workspace/rtl/mem/soc_ram.v \
               /workspace/rtl/periph/soc_timer.v \
               /workspace/rtl/periph/soc_uart.v \
               /workspace/rtl/periph/soc_pwm.v \
               $(RTL_SAFETY_SRCS) \
               $(RTL_NNA_SRCS) \
               /workspace/rtl/soc_top.v

all: test

test: test_py test_rtl

firmware:
	@echo "--- Assembling SoC Test Firmware ---"
	$(PYTHON) /workspace/sw/firmware/assemble.py /workspace/sw/firmware/soc_firmware.s /workspace/sw/firmware/firmware.hex

test_py:
	@echo "--- [1/3] Running INT8 Reference Model Test ---"
	$(PYTHON) /workspace/sw/model/reference_model.py
	@echo "--- [2/3] Running Deterministic Safety Layer Test ---"
	$(PYTHON) /workspace/sw/safety/safety_layer.py
	@echo "--- [3/3] Running End-to-End Robot Policy Pipeline ---"
	PYTHONPATH=/workspace/sw/model:/workspace/sw/safety $(PYTHON) /workspace/sw/model/robot_policy_e2e.py

test_rtl: test_rtl_nna test_rtl_safety test_soc test_soc_nav

test_rtl_nna:
	@echo "--- Building and Running NNA Accelerator Testbench ---"
	$(IVERILOG) -I/workspace/rtl -o /workspace/sim/tb_nna_top.vvp $(RTL_NNA_SRCS) /workspace/sim/tb_nna_top.v
	$(VVP) /workspace/sim/tb_nna_top.vvp

test_rtl_safety:
	@echo "--- Building and Running Safety Filter Testbench ---"
	$(IVERILOG) -I/workspace/rtl -o /workspace/sim/tb_safety_filter.vvp $(RTL_SAFETY_SRCS) /workspace/sim/tb_safety_filter.v
	$(VVP) /workspace/sim/tb_safety_filter.vvp

test_soc: firmware
	@echo "--- Building and Running Full SoC System Testbench ---"
	$(IVERILOG) -I/workspace/rtl -o /workspace/sim/tb_soc_top.vvp $(RTL_SOC_SRCS) /workspace/sim/tb_soc_top.v
	$(VVP) /workspace/sim/tb_soc_top.vvp

firmware_nav:
	@echo "--- Assembling Robot Navigation Firmware ---"
	cd /workspace/sw/firmware && riscv-none-elf-as -march=rv32im -mabi=ilp32 robot_nav_firmware.s -o robot_nav.o && riscv-none-elf-ld -m elf32lriscv -T linker.ld robot_nav.o -o robot_nav.elf && riscv-none-elf-objcopy -O binary robot_nav.elf robot_nav.bin && $(PYTHON) make_hex.py robot_nav.bin robot_nav.hex && riscv-none-elf-objdump -d robot_nav.elf > robot_nav.dump

test_soc_nav: firmware_nav
	@echo "--- Building and Running Full SoC Navigation Firmware Testbench ---"
	$(IVERILOG) -I/workspace/rtl -o /workspace/sim/tb_soc_nav.vvp $(RTL_SOC_SRCS) /workspace/sim/tb_soc_nav.v
	$(VVP) /workspace/sim/tb_soc_nav.vvp

clean:
	rm -f /workspace/sim/*.vvp /workspace/sim/*.vcd
