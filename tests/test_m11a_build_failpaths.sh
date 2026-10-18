#!/usr/bin/env bash
# Mocked failure-path test for scripts/build_ulx3s_bitstream.sh. Uses FAKE yosys/nextpnr/ecppack; runs NO real tools.
# Usage: tests/test_m11a_build_failpaths.sh   (from repo root)
set -u
REPO=$PWD; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/oss/bin" "$T/w/sw/firmware" "$T/w/fpga/ulx3s" "$T/w/rtl" "$T/w/scripts"
cd "$T/w"; git init -q; git config user.email t@t; git config user.name t
cp "$REPO/scripts/build_ulx3s_bitstream.sh" "$REPO/scripts/pnr_classify.py" scripts/
echo 00000013 > sw/firmware/robot_nav.hex; echo 'LOCATE' > fpga/ulx3s/ulx3s_85f.lpf; echo m > fpga/ulx3s/ulx3s_top.v; echo m > rtl/soc_top.v
for d in nna safety periph mem bus cpu; do mkdir -p rtl/$d; done; echo m > rtl/cpu/picorv32.v
for d in nna safety periph mem bus; do echo m > rtl/$d/x.v; done
git add -A; git commit -qm t
# fake tools; behaviour from env: MOCK_YOSYS, MOCK_FMAX, MOCK_PNR_EXIT, MOCK_PACK
cat > "$T/oss/bin/yosys" <<'X'
#!/bin/sh
[ "$1" = -V ] && { echo "Yosys MOCK"; exit 0; }
if [ "${MOCK_YOSYS:-0}" = 0 ]; then
  for a in "$@"; do case "$a" in write_rtlil*) ;; esac; done
  O=$(echo "$*" | sed 's/.*write_rtlil \([^;]*\);.*/\1/'); J=$(echo "$*" | sed 's/.*write_json \([^ ]*\).*/\1/')
  echo il > "$O"; echo '{}' > "$J"
fi
exit ${MOCK_YOSYS:-0}
X
cat > "$T/oss/bin/nextpnr-ecp5" <<'X'
#!/bin/sh
[ "$1" = --version ] && { echo "nextpnr-ecp5 MOCK"; exit 0; }
while [ $# -gt 0 ]; do case $1 in --report) R=$2;; --textcfg) C=$2;; --log) L=$2;; esac; shift; done
[ "${MOCK_NO_REPORT:-0}" = 1 ] || echo "{\"fmax\":{\"clk\":{\"achieved\":${MOCK_FMAX:-34.0},\"constraint\":25.0}}}" > "$R"
echo "Routing complete." > "$L"; echo "Router1 time 1s" >> "$L"; echo cfg > "$C"
exit ${MOCK_PNR_EXIT:-0}
X
cat > "$T/oss/bin/ecppack" <<'X'
#!/bin/sh
[ "$1" = --version ] && { echo "ecppack MOCK"; exit 0; }
[ "${MOCK_PACK:-0}" = 0 ] && for a in "$@"; do last=$a; done && echo bit > "$last"
exit ${MOCK_PACK:-0}
X
chmod +x "$T/oss/bin/"*
echo 'exit 0' > "$T/ok.sh"; echo 'exit 1' > "$T/bad.sh"; echo 'exit 0' > "$T/okpy"; chmod +x "$T/ok.sh" "$T/bad.sh"
export ROM_CHECK="bash $T/ok.sh" LPF_CHECK="bash $T/ok.sh"
fail=0
run() { # name expect(0|nz) env... -- args
  local name=$1 exp=$2; shift 2
  env OSS="$T/oss" OUT=o "$@" >/dev/null 2>&1; local rc=$?
  if { [ "$exp" = 0 ] && [ $rc -eq 0 ]; } || { [ "$exp" = nz ] && [ $rc -ne 0 ]; }; then echo "PASS  $name (rc=$rc)"; else echo "FAIL  $name (rc=$rc, expected $exp)"; fail=1; fi
}
B="bash scripts/build_ulx3s_bitstream.sh"
run "happy path all"            0  $B all;  grep -q 'OVERALL: PASS' o/summary.txt || { echo "FAIL happy summary"; fail=1; }; [ -s o/ulx3s_top.bit ] || { echo FAIL nobit; fail=1; }
run "ROM check failure"         nz ROM_CHECK="bash $T/bad.sh" $B all; grep -q 'rom: FAIL' o/summary.txt && grep -q 'OVERALL: FAIL' o/summary.txt && [ ! -e o/pnr/exit.txt ] && [ ! -e o/ulx3s_top.bit ] || { echo "FAIL rom: PNR/bit not blocked"; fail=1; }
run "LPF check failure"         nz LPF_CHECK="bash $T/bad.sh" $B all; grep -q 'lpf: FAIL' o/summary.txt && [ ! -e o/pnr/exit.txt ] && [ ! -e o/ulx3s_top.bit ] || { echo "FAIL lpf: PNR/bit not blocked"; fail=1; }
run "yosys failure"             nz MOCK_YOSYS=1 $B all; [ ! -e o/ulx3s_top.bit ] || { echo FAIL; fail=1; }
run "PNR timing failure (exit 0, fmax<25)" nz MOCK_FMAX=20.0 $B all; grep -q TIMING_FAILED o/pnr/result.txt && grep -q 'timing: FAIL' o/summary.txt && [ ! -e o/ulx3s_top.bit ] || { echo "FAIL timing: bit produced"; fail=1; }
run "PNR nonzero exit"          nz MOCK_PNR_EXIT=1 $B all; [ ! -e o/ulx3s_top.bit ] || { echo FAIL; fail=1; }
run "missing timing report"     nz MOCK_NO_REPORT=1 $B all; grep -q SETUP_FAILURE o/pnr/result.txt && [ ! -e o/ulx3s_top.bit ] || { echo "FAIL noreport"; fail=1; }
run "packing failure"           nz MOCK_PACK=1 $B all; grep -q 'pack: FAIL' o/summary.txt && grep -q 'OVERALL: FAIL' o/summary.txt && grep -q 'bitstream_sha256: none' o/summary.txt || { echo "FAIL pack"; fail=1; }
# standalone modes
rm -rf o; run "standalone pnr, no intermediates" nz $B pnr
rm -rf o; run "standalone pack, no intermediates" nz $B pack
run "synth (setup for stale test)" 0 $B synth
echo changed >> rtl/soc_top.v
run "standalone pnr, stale inputs" nz $B pnr
git checkout -q rtl/soc_top.v
run "synth again" 0 $B synth; run "pnr after synth" 0 $B pnr
rm o/status/rom; run "standalone pnr, missing rom status" nz $B pnr
run "synth again 2" 0 $B synth; run "pnr 2" 0 $B pnr; rm o/pnr/result.txt; run "pack without timing result" nz $B pack
run "pnr 3" 0 $B pnr; rm o/ulx3s_top.config; run "pack without config" nz $B pack
# --- unsafe OUT values: must be refused (rc!=0) BEFORE any deletion; sentinels must survive ---
rm -rf o; mkdir -p "$T/w/keep"; echo s > "$T/w/keep/sentinel"; echo s > "$T/sentinel_parent"; git add -A; git commit -qm keep
for bad in "" "/" "." ".." "../x" "$T" "$T/w" "$T/w/" "$T/w/." "$T/w/keep/.." "rtl" "sw/firmware" "keep/../rtl" "/tmp/../" "-rf"; do
  env OSS="$T/oss" OUT="$bad" bash scripts/build_ulx3s_bitstream.sh all >"$T/unsafe.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -q REFUSE "$T/unsafe.log" && [ -s rtl/soc_top.v ] && [ -s "$T/w/keep/sentinel" ] && [ -s "$T/sentinel_parent" ] && [ -d .git ]; then echo "PASS  unsafe OUT refused: '$bad' (rc=$rc)"; else echo "FAIL  unsafe OUT '$bad' rc=$rc"; cat "$T/unsafe.log"; fail=1; fi
done
# a tracked-file directory as OUT, and an OUT symlink pointing at the repo root
ln -s "$T/w" "$T/w/lnk"; env OSS="$T/oss" OUT=lnk bash scripts/build_ulx3s_bitstream.sh all >/dev/null 2>&1; [ $? -ne 0 ] && [ -s rtl/soc_top.v ] && echo "PASS  symlink OUT to repo root refused" || { echo "FAIL symlink OUT"; fail=1; }; rm -f "$T/w/lnk"
env OSS="$T/oss" OUT=keep bash scripts/build_ulx3s_bitstream.sh all >/dev/null 2>&1; [ $? -ne 0 ] && [ -s keep/sentinel ] && echo "PASS  OUT with tracked files refused" || { echo "FAIL tracked OUT"; fail=1; }
for m in synth pnr pack report; do env OSS="$T/oss" OUT= bash scripts/build_ulx3s_bitstream.sh $m >/dev/null 2>&1; [ $? -ne 0 ] && [ ! -e /summary.txt ] && echo "PASS  empty OUT refused in $m mode" || { echo "FAIL empty OUT $m"; fail=1; }; done
# --- stale-input detection on non-top-level / uncommitted / untracked synthesis inputs ---
stale() { # name, mutate-cmd, restore-cmd
  rm -rf o; run "synth for stale test: $1" 0 $B synth; run "pnr fresh: $1" 0 $B pnr
  eval "$2"; run "standalone pnr refuses: $1" nz $B pnr
  run "standalone pack refuses: $1" nz $B pack
  eval "$3"; rm -rf o
}
stale "modified rtl/nna/x.v (uncommitted)" 'echo chg >> rtl/nna/x.v' 'git checkout -q rtl/nna/x.v'
stale "modified rtl/cpu/picorv32.v (uncommitted)" 'echo chg >> rtl/cpu/picorv32.v' 'git checkout -q rtl/cpu/picorv32.v'
stale "modified rtl/bus/x.v" 'echo chg >> rtl/bus/x.v' 'git checkout -q rtl/bus/x.v'
stale "new untracked rtl/safety/y.v" 'echo m > rtl/safety/y.v' 'rm -f rtl/safety/y.v'
stale "new untracked nested rtl/periph/sub/z.v" 'mkdir -p rtl/periph/sub; echo m > rtl/periph/sub/z.v' 'rm -rf rtl/periph/sub'
stale "deleted rtl/mem/x.v" 'rm rtl/mem/x.v' 'git checkout -q rtl/mem/x.v'
stale "modified fpga/ulx3s/ulx3s_top.v" 'echo chg >> fpga/ulx3s/ulx3s_top.v' 'git checkout -q fpga/ulx3s/ulx3s_top.v'
stale "modified firmware hex" 'echo chg >> sw/firmware/robot_nav.hex' 'git checkout -q sw/firmware/robot_nav.hex'
run "report with no run" nz $B report
[ $fail -eq 0 ] && echo "ALL MOCK FAIL-PATH CHECKS PASSED" || echo "SOME CHECKS FAILED"; exit $fail
