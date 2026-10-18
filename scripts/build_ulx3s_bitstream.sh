#!/usr/bin/env bash
# M11a: ONE bounded synth -> PNR -> bitstream for ulx3s_top on LFE5U-85F-6BG381C, 25 MHz, fixed seed.
# Usage: OSS=/path/to/oss-cad-suite OUT=out_m11a scripts/build_ulx3s_bitstream.sh [synth|pnr|pack|all]
# Same commands as .github/workflows/pnr-soc-top.yml (seed fixed to 1), plus ecppack. Not a board result.
set -uo pipefail
OSS=${OSS:?set OSS to oss-cad-suite dir}; OUT=${OUT:-out_m11a}; SEED=1; STEP=${1:-all}
export PATH=$OSS/bin:$PATH; mkdir -p "$OUT"
SRC="rtl/nna/*.v rtl/safety/*.v rtl/periph/*.v rtl/mem/*.v rtl/bus/*.v rtl/cpu/picorv32.v rtl/soc_top.v"
if [ "$STEP" = synth ] || [ "$STEP" = all ]; then
  { git rev-parse HEAD; sha256sum sw/firmware/robot_nav.hex fpga/ulx3s/ulx3s_85f.lpf fpga/ulx3s/ulx3s_top.v rtl/soc_top.v; yosys -V; nextpnr-ecp5 --version 2>&1|head -1; ecppack --version 2>&1|head -1; } > "$OUT/metadata.txt"
  yosys -l "$OUT/synth.log" -p "read_verilog -DSYNTHESIS -Irtl fpga/ulx3s/ulx3s_top.v $SRC; hierarchy -check -top ulx3s_top; synth_ecp5 -top ulx3s_top -noabc9; tee -o $OUT/stat.txt stat; write_rtlil $OUT/netlist.il; write_json $OUT/soc_top.json" > "$OUT/yosys_stdout.txt" 2>&1; echo $? > "$OUT/yosys_exit.txt"
  [ "$(cat "$OUT/yosys_exit.txt")" = 0 ] || exit 1
  python3 scripts/check_rom_mapped.py sw/firmware/robot_nav.hex "$OUT/netlist.il:u_soc.u_rom." 2>&1 | tee "$OUT/rom_mapped_check.txt"
  python3 scripts/check_lpf_ports.py "$OUT/soc_top.json" ulx3s_top fpga/ulx3s/ulx3s_85f.lpf 2>&1 | tee "$OUT/lpf_port_check.txt"
fi
if [ "$STEP" = pnr ] || [ "$STEP" = all ]; then
  nextpnr-ecp5 --85k --package CABGA381 --speed 6 --json "$OUT/soc_top.json" --lpf fpga/ulx3s/ulx3s_85f.lpf --freq 25 --seed $SEED --timing-allow-fail --report "$OUT/report.json" --textcfg "$OUT/ulx3s_top.config" --log "$OUT/nextpnr.log" > "$OUT/pnr_stdout.txt" 2>&1; echo $? > "$OUT/pnr_exit.txt"
fi
if [ "$STEP" = pack ] || [ "$STEP" = all ]; then
  ecppack --compress --idcode 0x41113043 "$OUT/ulx3s_top.config" "$OUT/ulx3s_top.bit" > "$OUT/ecppack.log" 2>&1; echo $? > "$OUT/ecppack_exit.txt"
  sha256sum "$OUT/ulx3s_top.bit" | tee "$OUT/bit.sha256"
fi
