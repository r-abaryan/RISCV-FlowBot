#!/bin/sh
# M7B negative test: firmware built with a 2000-cycle watchdog (< loop period) MUST trip.
# Expect tb_soc_nav to $fatal with "watchdog tripped unexpectedly"; script succeeds only then.
set -e
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); cd "$T"
# M11b: the timeout is now the named constant WDT_TIMEOUT_CYCLES; override its definition.
sed 's/^\( *\.equ WDT_TIMEOUT_CYCLES,\).*/\1 2000/' "$R/sw/firmware/robot_nav_firmware.s" > nav_short.s
grep -q "^ *\.equ WDT_TIMEOUT_CYCLES, 2000$" nav_short.s
grep -q "li   t1, WDT_TIMEOUT_CYCLES" nav_short.s
riscv-none-elf-as -I "$R/sw/firmware" -march=rv32im -mabi=ilp32 nav_short.s -o n.o
riscv-none-elf-ld -m elf32lriscv -T "$R/sw/firmware/linker.ld" n.o -o n.elf
riscv-none-elf-objcopy -O binary n.elf n.bin
python3 "$R/sw/firmware/make_hex.py" n.bin n.hex
SRCS=$(find "$R/rtl" -name "*.v" ! -name "ibex_wb_adapter.v" | sort)
iverilog -I"$R/rtl" -DROM_INIT_FILE=\"$T/n.hex\" -o n.vvp $SRCS "$R/sim/tb_soc_nav.v"
# M11b harness fix 2: use the checked runner, so the trip message must be on the
# single terminal FATAL: line (an interrupted/killed run is rejected).
set +e; sh "$R/sim/run_vvp_checked.sh" --log out.log --expect-fail "watchdog tripped unexpectedly" n.vvp > run.out 2>&1; rc=$?; set -e
tail -5 out.log; tail -1 run.out
[ $rc -eq 0 ] && echo "NEGATIVE TEST PASS (trip detected on terminal FATAL line)" && exit 0
echo "NEGATIVE TEST FAIL"; exit 1
