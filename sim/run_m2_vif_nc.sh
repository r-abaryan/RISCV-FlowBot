#!/bin/sh
# M11b M2: negative controls for sim/tb_m2_vif.v. Each must FATAL with a [VIF-FAIL] line. SIMULATION ONLY.
# NC-a perturbed expected value (V-IF1); NC5 range check disabled in a temporary soc_pwm copy (V-IF2 and V-IF3);
# NC-b PWM compare off by one in a temporary copy (V-IF1). rtl/periph/soc_pwm.v is never modified.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); IVERILOG=${IVERILOG:-iverilog}
W=$(mktemp -d /tmp/m2vifnc.XXXXXX); trap 'rm -rf "$W"' EXIT
R=$ROOT/rtl/periph/soc_pwm.v; TB=$ROOT/sim/tb_m2_vif.v; fail=0
mk() { # name src old new
  c=$(grep -cF "$3" "$2"); [ "$c" -eq 1 ] || { echo "[$1] PATTERN COUNT $c"; exit 2; }
  python3 -c "import sys;s=open(sys.argv[1]).read();open(sys.argv[2],'w').write(s.replace(sys.argv[3],sys.argv[4]))" "$2" "$W/$1.v" "$3" "$4"; }
expect() { # name rtl defines plusargs...
  n=$1; r=$2; d=$3; shift 3
  "$IVERILOG" -g2012 -DP=1000 $d -o "$W/$n.vvp" "$r" "$TB" || exit 2
  vvp -N "$W/$n.vvp" "$@" > "$W/$n.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -q "FATAL: .*\[VIF-FAIL\]" "$W/$n.log" && ! grep -q "VIF-PASS" "$W/$n.log"; then
    echo "[$n] NC FAILED AS REQUIRED rc=$rc: $(grep -m1 'VIF-FAIL' "$W/$n.log" | sed 's/.*\[VIF-FAIL\]//')"
  else echo "[$n] NC NOT DETECTED rc=$rc"; fail=1; fi; }
expect NCa_vif1_expect_plus1 "$R" "-DVIF1 -DNC_EXPECT_PLUS1=-333" +LO=-340 +HI=-330 +MODES=1
mk nc5 "$R" "wire range_bad   = wr_commit && " "wire range_bad   = 1'b0 && "
expect NC5_range_off_vif2 "$W/nc5.v" "-DVIF2" +LO=1001 +HI=1010
expect NC5_range_off_vif3 "$W/nc5.v" "-DVIF3"
mk ncb "$R" "(lhs <= rhs_l)" "(lhs < rhs_l)"
expect NCb_pwm_off_by_one_vif1 "$W/ncb.v" "-DVIF1" +LO=-5 +HI=5
[ $fail -eq 0 ] && echo "[M2_VIF_NC PASS]" || echo "[M2_VIF_NC FAIL]"; exit $fail
