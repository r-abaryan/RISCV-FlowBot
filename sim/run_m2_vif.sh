#!/bin/sh
# M11b M2: run one shard of the exhaustive V-IF checks (sim/tb_m2_vif.v). SIMULATION ONLY.
# usage: run_m2_vif.sh VIF1|VIF2|VIF3 PERIOD LOG [plusargs...]   (e.g. +LO=-1000 +HI=1000 +MODES=7 / +SIDES=1)
# Exit 0 iff vvp rc=0, a [VIF-PASS] line is present and no FATAL. The full exhaustive set is the union of shards
# listed in make test_m2_vif_full (about 70 min at 0.25 vCPU); make test_m2_vif runs V-IF3 + sampled shards + NCs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); IVERILOG=${IVERILOG:-iverilog}
K=$1; P=$2; LOG=$3; shift 3
W=$(mktemp -d /tmp/m2vif.XXXXXX); trap 'rm -rf "$W"' EXIT
"$IVERILOG" -g2012 -DP=$P -D$K -o "$W/t.vvp" "$ROOT/rtl/periph/soc_pwm.v" "$ROOT/sim/tb_m2_vif.v" || exit 2
vvp -N "$W/t.vvp" "$@" > "$LOG" 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q "\[VIF-PASS\]" "$LOG" && ! grep -q FATAL "$LOG"; then grep "VIF-PASS" "$LOG"; exit 0; fi
echo "[VIF-SHARD-FAIL] $K P=$P rc=$rc $*"; tail -3 "$LOG"; exit 1
