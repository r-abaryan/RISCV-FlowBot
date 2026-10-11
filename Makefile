# Top-level Makefile for RISC-V Robot SoC

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys

.PHONY: all sim sim_nna sim_safety sim_soc sim_nav sim_all test_py firmware synth_check clean

all: test_py sim_nna sim_safety sim_soc synth_check

firmware:
	$(MAKE) -C $(ROOT_DIR)/sim firmware

test_py:
	$(MAKE) -C $(ROOT_DIR)/sim test_py

sim_nna:
	$(MAKE) -C $(ROOT_DIR)/sim test_nna

sim_safety:
	$(MAKE) -C $(ROOT_DIR)/sim test_safety

sim_soc:
	$(MAKE) -C $(ROOT_DIR)/sim test_soc

sim_nav:
	$(MAKE) -C $(ROOT_DIR)/sim test_nav

sim: sim_nna sim_safety sim_soc

sim_all: sim sim_nav

synth_check:
	@echo "--- Running Yosys RTL Syntax & Elaboration Check ---"
	$(YOSYS) -p "read_verilog -I$(ROOT_DIR)/rtl $(ROOT_DIR)/rtl/nna/*.v $(ROOT_DIR)/rtl/safety/*.v $(ROOT_DIR)/rtl/periph/*.v $(ROOT_DIR)/rtl/mem/*.v $(ROOT_DIR)/rtl/bus/*.v $(ROOT_DIR)/rtl/cpu/picorv32.v $(ROOT_DIR)/rtl/soc_top.v; hierarchy -check -top soc_top; check"

clean:
	$(MAKE) -C $(ROOT_DIR)/sim clean
	rm -f $(ROOT_DIR)/sw/firmware/*.o $(ROOT_DIR)/sw/firmware/*.elf $(ROOT_DIR)/sw/firmware/*.bin $(ROOT_DIR)/sw/firmware/*.dump
