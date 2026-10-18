#!/usr/bin/env bash
# M11a: ONE bounded synth -> PNR -> bitstream for ulx3s_top on LFE5U-85F-6BG381C, 25 MHz, fixed seed.
# Usage: OSS=/path/to/oss-cad-suite OUT=out_m11a scripts/build_ulx3s_bitstream.sh [all|synth|pnr|pack|report]
#   all (default, used by CI): clean OUT, then synth+ROM check+LPF check -> nextpnr -> timing classify -> ecppack -> report.
#   synth/pnr/pack standalone: pnr and pack REFUSE to run on missing or stale intermediates (inputs.sha256 must match
#   the current git HEAD and source hashes, and the previous gate must be PASS).
# Gates (each recorded independently in $OUT/status/<name>, PASS or FAIL; absent = MISSING = failure):
#   synth (yosys exit 0), rom (check_rom_mapped.py), lpf (check_lpf_ports.py), timing (pnr_classify.py == TIMING_MET at 25 MHz),
#   pack (ecppack exit 0 and bitstream exists). Any non-PASS => nonzero exit, no later stage runs.
# Output is an UNVALIDATED bitstream CANDIDATE. Not board-tested. Not a hardware result.
set -uo pipefail
STEP=${1:-all}; OUT=${OUT-out_m11a}; SEED=1; FREQ=25
LPF=fpga/ulx3s/ulx3s_85f.lpf; HEX=sw/firmware/robot_nav.hex
ROM_CHECK=${ROM_CHECK:-python3 scripts/check_rom_mapped.py}
LPF_CHECK=${LPF_CHECK:-python3 scripts/check_lpf_ports.py}
CLASSIFY=${CLASSIFY:-python3 scripts/pnr_classify.py}
SRC="rtl/nna/*.v rtl/safety/*.v rtl/periph/*.v rtl/mem/*.v rtl/bus/*.v rtl/cpu/picorv32.v rtl/soc_top.v"
ST="$OUT/status"; PNR="$OUT/pnr"
GATES="synth rom lpf timing pack"

setst() { mkdir -p "$ST"; echo "$2" > "$ST/$1"; }
getst() { cat "$ST/$1" 2>/dev/null || echo MISSING; }
# Hash EVERY synthesis input from the working tree (so uncommitted / untracked edits are detected): the explicit file
# list Yosys reads (every file matched by every $SRC glob; an unmatched glob is an error) plus every file under rtl/
# (includes, nested dirs), the top-level inputs, and the build scripts. HEAD is recorded too.
src_files() {
  local g m
  for g in $SRC; do m=$(compgen -G "$g") || { echo "MISSING-GLOB:$g"; continue; }; echo "$m"; done
  find rtl -type f 2>/dev/null; echo $HEX; echo $LPF; echo fpga/ulx3s/ulx3s_top.v
  echo scripts/build_ulx3s_bitstream.sh; echo scripts/pnr_classify.py
}
inputs_hash() { { git rev-parse HEAD; src_files | LC_ALL=C sort -u | while read -r f; do
    if [ -f "$f" ]; then sha256sum "$f"; else echo "ABSENT $f"; fi; done; } 2>&1; }

# Refuse unsafe OUT before anything is deleted. OUT must resolve to a strict subdirectory of the repo root.
check_out() {
  local root abs
  [ -n "${OUT:-}" ] || { echo "REFUSE: OUT is empty"; return 1; }
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "REFUSE: not in a git repo"; return 1; }
  root=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$root"); abs=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OUT")
  case "$OUT" in -*) echo "REFUSE: OUT starts with '-'"; return 1;; esac
  case "/$OUT/" in */../*|*/./*) echo "REFUSE: OUT contains . or .. component: $OUT"; return 1;; esac
  [ "$abs" != / ] || { echo "REFUSE: OUT is filesystem root"; return 1; }
  [ "$abs" != "$root" ] || { echo "REFUSE: OUT is the repository root"; return 1; }
  case "$abs/" in "$root"/*) ;; *) echo "REFUSE: OUT ($abs) is outside the repository root or a parent of it"; return 1;; esac
  case "$abs/" in "$root"/.git/*) echo "REFUSE: OUT inside .git"; return 1;; esac
  if [ -n "$(git ls-files -- "$abs" 2>/dev/null | head -1)" ]; then echo "REFUSE: OUT contains git-tracked files"; return 1; fi
  case "$abs" in "$root"/rtl|"$root"/rtl/*|"$root"/sw|"$root"/sw/*|"$root"/fpga|"$root"/fpga/*|"$root"/scripts|"$root"/scripts/*|"$root"/tests|"$root"/tests/*|"$root"/docs|"$root"/docs/*) echo "REFUSE: OUT inside a source directory"; return 1;; esac
  return 0
}

report() {   # always safe to call; exit 0 only if every gate is PASS
  mkdir -p "$OUT"; local all=PASS g s
  { echo "# M11a bitstream candidate report (UNVALIDATED, not board-tested)"
    echo "source_sha: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "firmware_sha256: $(sha256sum $HEX 2>/dev/null | cut -d' ' -f1)"
    echo "tools: $(sed -n '/^yosys\|^Yosys\|^nextpnr\|^Project\|ecppack/p' "$OUT/metadata.txt" 2>/dev/null | tr '\n' ';')"
    for g in $GATES; do s=$(getst $g); echo "$g: $s"; [ "$s" = PASS ] || all=FAIL; done
    echo "timing_class: $(head -1 "$PNR/result.txt" 2>/dev/null || echo MISSING)"
    if [ "$all" = PASS ] && [ -s "$OUT/ulx3s_top.bit" ]; then echo "bitstream_sha256: $(sha256sum "$OUT/ulx3s_top.bit" | cut -d' ' -f1)"
    else echo "bitstream_sha256: none"; [ "$all" = PASS ] && all=FAIL; fi
    echo "OVERALL: $all"
  } > "$OUT/summary.txt"
  cat "$OUT/summary.txt"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && { echo '```'; cat "$OUT/summary.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
  [ "$all" = PASS ]
}

need_fresh() {  # $1 = required previous gates
  local g
  [ -s "$OUT/inputs.sha256" ] || { echo "REFUSE: missing $OUT/inputs.sha256 (run synth first)"; return 1; }
  [ "$(inputs_hash)" = "$(cat "$OUT/inputs.sha256")" ] || { echo "REFUSE: stale intermediates (HEAD or input hashes changed)"; return 1; }
  for g in $1; do [ "$(getst $g)" = PASS ] || { echo "REFUSE: gate $g is $(getst $g)"; return 1; }; done
}

do_synth() {
  check_out || return 1
  [ "$STEP" = all ] && rm -rf "$OUT"
  mkdir -p "$ST" "$PNR"
  for g in $GATES; do rm -f "$ST/$g"; done
  rm -f "$OUT/ulx3s_top.bit" "$OUT/ulx3s_top.config" "$OUT/soc_top.json" "$OUT/netlist.il"
  for f in $HEX $LPF fpga/ulx3s/ulx3s_top.v rtl/soc_top.v; do [ -s "$f" ] || { echo "missing input $f"; setst synth FAIL; return 1; }; done
  inputs_hash > "$OUT/inputs.sha256"
  { cat "$OUT/inputs.sha256"; yosys -V; nextpnr-ecp5 --version 2>&1|head -1; ecppack --version 2>&1|head -1; } > "$OUT/metadata.txt" 2>&1
  yosys -l "$OUT/synth.log" -p "read_verilog -DSYNTHESIS -Irtl fpga/ulx3s/ulx3s_top.v $SRC; hierarchy -check -top ulx3s_top; synth_ecp5 -top ulx3s_top -noabc9; tee -o $OUT/stat.txt stat; write_rtlil $OUT/netlist.il; write_json $OUT/soc_top.json" > "$OUT/yosys_stdout.txt" 2>&1
  local rc=$?; echo $rc > "$OUT/yosys_exit.txt"
  if [ $rc -ne 0 ] || [ ! -s "$OUT/soc_top.json" ] || [ ! -s "$OUT/netlist.il" ]; then setst synth FAIL; return 1; fi
  setst synth PASS
  # ROM and LPF gates are independent: both are run and recorded, either failing stops the build.
  $ROM_CHECK $HEX "$OUT/netlist.il:u_soc.u_rom." > "$OUT/rom_mapped_check.txt" 2>&1; local r=$?
  $LPF_CHECK "$OUT/soc_top.json" ulx3s_top $LPF > "$OUT/lpf_port_check.txt" 2>&1; local l=$?
  [ $r -eq 0 ] && setst rom PASS || setst rom FAIL
  [ $l -eq 0 ] && setst lpf PASS || setst lpf FAIL
  [ $r -eq 0 ] && [ $l -eq 0 ]
}

do_pnr() {
  need_fresh "synth rom lpf" || return 1
  [ -s "$OUT/soc_top.json" ] || { echo "REFUSE: soc_top.json missing"; return 1; }
  rm -rf "$PNR"; mkdir -p "$PNR"; rm -f "$OUT/ulx3s_top.config" "$OUT/ulx3s_top.bit"; setst timing FAIL; setst pack FAIL
  nextpnr-ecp5 --85k --package CABGA381 --speed 6 --json "$OUT/soc_top.json" --lpf $LPF --freq $FREQ --seed $SEED --timing-allow-fail --report "$PNR/report.json" --textcfg "$OUT/ulx3s_top.config" --log "$PNR/nextpnr.log" > "$PNR/stdout.txt" 2>&1
  echo $? > "$PNR/exit.txt"
  # PNR exit 0 alone is NOT sufficient: pnr_classify.py must say TIMING_MET (criteria unchanged).
  $CLASSIFY "$PNR" > "$OUT/pnr_classify_stdout.txt" 2>&1; local c=$?
  cat "$OUT/pnr_classify_stdout.txt"
  [ $c -eq 0 ] && [ "$(head -1 "$PNR/result.txt" 2>/dev/null)" = TIMING_MET ] && [ -s "$OUT/ulx3s_top.config" ] && { setst timing PASS; return 0; }
  setst timing FAIL; return 1
}

do_pack() {
  need_fresh "synth rom lpf timing" || return 1
  [ "$(head -1 "$PNR/result.txt" 2>/dev/null)" = TIMING_MET ] || { echo "REFUSE: no TIMING_MET result"; return 1; }
  [ -s "$OUT/ulx3s_top.config" ] || { echo "REFUSE: ulx3s_top.config missing"; return 1; }
  [ "$OUT/ulx3s_top.config" -nt "$OUT/soc_top.json" ] || [ "$OUT/ulx3s_top.config" -ef "$OUT/soc_top.json" ] || { echo "REFUSE: config older than netlist"; return 1; }
  setst pack FAIL; rm -f "$OUT/ulx3s_top.bit"
  ecppack --compress --idcode 0x41113043 "$OUT/ulx3s_top.config" "$OUT/ulx3s_top.bit" > "$OUT/ecppack.log" 2>&1
  local rc=$?; echo $rc > "$OUT/ecppack_exit.txt"
  if [ $rc -eq 0 ] && [ -s "$OUT/ulx3s_top.bit" ]; then sha256sum "$OUT/ulx3s_top.bit" | tee "$OUT/bit.sha256"; setst pack PASS; return 0; fi
  setst pack FAIL; return 1
}

case "$STEP" in report|synth|pnr|pack|all) check_out || exit 2;; esac
case "$STEP" in
  report) report; exit $? ;;
  synth|pnr|pack) OSS=${OSS:?set OSS}; export PATH=$OSS/bin:$PATH
    do_$STEP; rc=$?; report >/dev/null 2>&1; exit $rc ;;
  all) OSS=${OSS:?set OSS}; export PATH=$OSS/bin:$PATH
    do_synth && do_pnr && do_pack; rc=$?; report; r2=$?; [ $rc -eq 0 ] && exit $r2; exit $rc ;;
  *) echo "usage: $0 [all|synth|pnr|pack|report]"; exit 2 ;;
esac
