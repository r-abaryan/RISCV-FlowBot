#!/bin/sh
# Resumable, staged Yosys synth_ecp5 of ONE top module, for environments with a per-call time limit (~120 s).
#
# Usage (repo root):  scripts/synth_staged.sh <top> "<extra yosys cmds or empty>" <verilog files...>
#   extra yosys cmds run after read_verilog and before `hierarchy`, e.g. "chparam -set ENABLE_MUL 1 picorv32_wb;"
# Env: BUDGET  seconds this call may use in total (default 100; raise it on a machine without a call limit)
#      STAGE_TIMEOUT  max seconds for one stage (default = remaining BUDGET)
#
# Exit status (check it, do not grep for "DONE"):
#   0  COMPLETED   all stages finished; final stats in build/syn/<top>/stat.txt
#   2  INCOMPLETE  a stage hit the time budget/timeout (or budget ran out between stages). Not an error:
#                  re-run the identical command; finished stages are skipped (checkpoints are kept).
#   1  FAILED      yosys exited with an error (or bad usage). The failing log is kept as
#                  build/syn/<top>/log<N>.txt and the checkpoints of earlier stages are kept.
#   Anything else (no status file, or status RUNNING left behind by a killed shell) = INCOMPLETE, never COMPLETED.
#   137/143 (SIGKILL/SIGTERM) is INCOMPLETE only if the stage used its whole time allowance; an early kill (OOM) is FAILED.
# State is also written to build/syn/<top>/status  (RUNNING stage=N | COMPLETED | INCOMPLETE stage=N | FAILED stage=N rc=R).
# A stage log is never deleted; the stage that did not finish leaves log<N>.txt (partial) for inspection.
# Stats are only trustworthy if status == COMPLETED. Yosys must be on PATH (. /opt/yroot/env.sh; see docs/19 and docs/20).
# RUN_TAG (env) overrides the work directory name build/syn/<RUN_TAG> (default <top>) so variants do not share checkpoints.
# SYNTH_OPTS (env) adds synth_ecp5 options, e.g. -noflatten (changes the signature, so checkpoints are not mixed).
# Note: -noabc9 is used (ABC9 did not finish in the call limit in earlier attempts).
[ $# -ge 3 ] || { echo "usage: $0 <top> \"<extra cmds>\" <verilog files...>" >&2; exit 1; }
top=$1; cp=$2; shift; shift
command -v yosys >/dev/null 2>&1 || { echo "FAILED: yosys not on PATH (see docs/20_runbook_for_future_sessions.md)" >&2; exit 1; }
d=build/syn/${RUN_TAG:-$top}; mkdir -p "$d"
# Invalidate checkpoints if the inputs changed (RTL text, extra cmds, top, or Yosys version): stale checkpoints would
# silently produce stats for different RTL (checkpoints without a signature are also discarded). Old logs are overwritten.
sig=$( { echo "$top"; echo "$cp"; echo "$SYNTH_OPTS"; yosys -V; cat "$@"; } | cksum | tr ' ' '_')
if { [ -f "$d/inputs.sig" ] && [ "$(cat "$d/inputs.sig")" != "$sig" ]; } || { [ ! -f "$d/inputs.sig" ] && [ -f "$d/done.1" ]; }; then
  echo "inputs changed since last run: discarding old checkpoints in $d" >&2
  rm -f "$d"/done.* "$d"/s*.il "$d"/status
fi
echo "$sig" > "$d/inputs.sig"
BUDGET=${BUDGET:-100}
start=$(date +%s)
stages="begin:coarse coarse:map_ram map_ram:map_gates map_gates:map_luts map_luts:map_cells map_cells:check check:"
prev=""; i=0
for st in $stages; do
  i=$((i+1))
  if [ -f "$d/done.$i" ]; then prev=$d/s$i.il; continue; fi
  left=$((BUDGET - ($(date +%s) - start)))
  if [ $left -lt 5 ]; then
    echo "INCOMPLETE stage=$i (call budget used up before starting it) - re-run the same command" | tee "$d/status"
    exit 2
  fi
  to=${STAGE_TIMEOUT:-$left}; [ "$to" -gt "$left" ] && to=$left
  if [ $i = 1 ]; then pre="read_verilog -DSYNTHESIS -Irtl $*; $cp hierarchy -check -top $top"; else pre="read_rtlil $prev"; fi
  [ $i -ge 5 ] && pre="$pre; read_verilog -lib -specify -overwrite +/ecp5/cells_sim.v +/ecp5/cells_bb.v"
  if [ $i = 7 ]; then post="tee -o $d/stat.txt stat; tee -o $d/stat_hier.txt stat -top $top; write_rtlil $d/netlist.il"; else post="write_rtlil $d/s$i.il"; fi
  echo "RUNNING stage=$i" > "$d/status"
  t0=$(date +%s)
  timeout -k 3 "$to" yosys -q -l "$d/log$i.txt" -p "$pre; synth_ecp5 -top $top -noabc9 $SYNTH_OPTS -run $st; $post" >"$d/stdout$i.txt" 2>&1
  rc=$?
  el=$(( $(date +%s) - t0 ))
  if [ $rc = 0 ]; then
    touch "$d/done.$i"; echo "stage $i ok"; prev=$d/s$i.il
  elif [ $rc = 124 ] || { { [ $rc = 137 ] || [ $rc = 143 ]; } && [ $el -ge $((to - 1)) ]; }; then
    # 124 = timeout(1) expired. 137/143 count as a timeout only if the stage ran for (about) the whole allowance;
    # otherwise the process was killed early (e.g. out of memory) and is reported as FAILED below.
    echo "INCOMPLETE stage=$i (timed out after ${to}s; partial log $d/log$i.txt) - re-run the same command" | tee "$d/status"
    exit 2
  else
    echo "FAILED stage=$i rc=$rc (see $d/log$i.txt and $d/stdout$i.txt)" | tee "$d/status" >&2
    exit 1
  fi
done
echo COMPLETED | tee "$d/status"
exit 0
