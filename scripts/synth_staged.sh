#!/bin/sh
# Resumable, staged Yosys synth_ecp5 of ONE module (for sandboxes with a ~120 s per-call limit).
# Usage (repo root): scripts/synth_staged.sh <top> "<extra yosys cmds or empty>" <verilog files...>
# Re-run the same command until it prints DONE. Each stage is checkpointed in build/syn/<top>/.
# Final cell statistics: build/syn/<top>/stat.txt
# Notes: -noabc9 is used; Yosys must be on PATH (this sandbox: . /opt/y/env.sh).
top=$1; cp=$2; shift; shift
d=build/syn/$top; mkdir -p $d
stages="begin:coarse coarse:map_ram map_ram:map_gates map_gates:map_luts map_luts:map_cells map_cells:check check:"
prev=""; i=0
for st in $stages; do
  i=$((i+1))
  [ -f $d/done.$i ] && { prev=$d/s$i.il; continue; }
  if [ $i = 1 ]; then pre="read_verilog -DSYNTHESIS -Irtl $*; $cp hierarchy -check -top $top"; else pre="read_rtlil $prev"; fi
  [ $i -ge 5 ] && pre="$pre; read_verilog -lib -specify -overwrite +/ecp5/cells_sim.v +/ecp5/cells_bb.v"
  if [ $i = 7 ]; then post="tee -o $d/stat.txt stat"; else post="write_rtlil $d/s$i.il"; fi
  timeout 100 yosys -q -l $d/log$i.txt -p "$pre; synth_ecp5 -top $top -noabc9 -run $st; $post" >/dev/null 2>&1
  [ $? = 0 ] && touch $d/done.$i && echo "stage $i ok" || { echo "stage $i incomplete/failed - re-run"; exit 0; }
  prev=$d/s$i.il
done
echo DONE
