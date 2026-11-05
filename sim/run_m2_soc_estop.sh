#!/bin/sh
# M11b M2 Step 1b (owner decision F2): integrated-SoC E-stop/WDT => disarm assertion + broken-connection
# negative controls. SIMULATION ONLY. Production rtl/soc_top.v is never modified: each negative control
# compiles a temporary copy with exactly one connection broken, and must FATAL with the named check.
# Exit: 0 = real SoC passes and every NC fails as required; 1 otherwise; 2 = tool/pattern error.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IVERILOG=${IVERILOG:-iverilog}
N=${N_CYCLES:-200000}
W=$(mktemp -d /tmp/m2socestop.XXXXXX); trap 'rm -rf "$W"' EXIT
LIB="nna/nna_mac4.v nna/nna_regs.v nna/nna_core.v nna/nna_top.v safety/safety_filter.v periph/soc_uart.v
periph/soc_timer.v periph/soc_pwm.v bus/soc_interconnect.v mem/soc_rom.v mem/soc_ram.v cpu/picorv32.v"
SRCS=""; for f in $LIB; do SRCS="$SRCS $ROOT/rtl/$f"; done
HEX="$ROOT/sw/firmware/firmware.hex"
H0=$(sha256sum "$ROOT/rtl/soc_top.v" | cut -d' ' -f1)
run() { # name top.v expect(PASS|marker)
  "$IVERILOG" -g2012 -I"$ROOT/rtl" -DROM_INIT_FILE=\"$HEX\" -DN_CYCLES=$N -o "$W/$1.vvp" $SRCS "$2" \
      "$ROOT/sim/tb_m2_soc_estop.v" > "$W/$1.clog" 2>&1 || { echo "[$1] COMPILE ERROR"; cat "$W/$1.clog"; return 2; }
  vvp -N "$W/$1.vvp" > "$W/$1.log" 2>&1; rc=$?
  grep -E "SOCESTOP" "$W/$1.log" | sed "s/^/  [$1] /"
  if [ "$3" = PASS ]; then
    [ $rc -eq 0 ] && grep -q "\[SOCESTOP-PASS\]" "$W/$1.log" && ! grep -q FATAL "$W/$1.log" && { echo "[$1] PASS rc=$rc"; return 0; }
    echo "[$1] FAIL rc=$rc"; return 1
  fi
  n=$(grep -c "FATAL: " "$W/$1.log")   # UART text may precede FATAL on the same line
  if [ $rc -ne 0 ] && [ $rc -lt 124 ] && [ "$n" -eq 1 ] && grep "FATAL: " "$W/$1.log" | grep -q "$3"; then
    echo "[$1] NC FAILED AS REQUIRED rc=$rc ($3)"; return 0; fi
  echo "[$1] NC NOT DETECTED rc=$rc fatal_lines=$n (wanted $3)"; tail -3 "$W/$1.log"; return 1
}
mut() { # name old new  -> temporary soc_top copy
  c=$(grep -cF "$2" "$ROOT/rtl/soc_top.v")
  [ "$c" -eq 1 ] || { echo "[$1] PATTERN COUNT $c (harness error)"; return 2; }
  python3 -c "import sys;s=open(sys.argv[1]).read();open(sys.argv[2],'w').write(s.replace(sys.argv[3],sys.argv[4]))" \
      "$ROOT/rtl/soc_top.v" "$W/$1_top.v" "$2" "$3"
}
fail=0
run REAL "$ROOT/rtl/soc_top.v" PASS || fail=1
# NC1: soc_pwm.disarm_in disconnected (tied 0)                              -> S1
mut NC1_pwm_disarm_tied0 ".disarm_in     (actuator_disarm)," ".disarm_in     (1'b0)," || exit 2
run NC1_pwm_disarm_tied0 "$W/NC1_pwm_disarm_tied0_top.v" "S1 estop_in=1 with disarm_in=0" || fail=1
# NC2: safety_filter E-stop pin disconnected (soc_pwm still sees E-stop)     -> S1
mut NC2_safety_estop_pin_tied0 ".pin_estop_button (estop_tripped)," ".pin_estop_button (1'b0)," || exit 2
run NC2_safety_estop_pin_tied0 "$W/NC2_safety_estop_pin_tied0_top.v" "S1 estop_in=1 with disarm_in=0" || fail=1
# NC3: soc_pwm.estop_in from a different net (inverted E-stop)              -> S3 (shared-net check)
mut NC3_pwm_estop_inverted ".estop_in      (estop_tripped)," ".estop_in      (!estop_tripped)," || exit 2
run NC3_pwm_estop_inverted "$W/NC3_pwm_estop_inverted_top.v" "S3 E-stop net differs" || fail=1
# NC4: WDT trip path broken out of the disarm (disarm ignores the WDT-tripped state) -> S2
mut NC4_disarm_ignores_wdt ".disarm_in     (actuator_disarm)," ".disarm_in     (actuator_disarm && !safety_wdt_expired)," || exit 2
run NC4_disarm_ignores_wdt "$W/NC4_disarm_ignores_wdt_top.v" "S2 wdt_trip_in=1 with disarm_in=0" || fail=1
H1=$(sha256sum "$ROOT/rtl/soc_top.v" | cut -d' ' -f1)
[ "$H0" = "$H1" ] || { echo "soc_top.v changed during run"; fail=1; }
echo "soc_top.v sha256 $H1"
[ $fail -eq 0 ] && echo "[TEST_M2_SOC_ESTOP PASS]" || echo "[TEST_M2_SOC_ESTOP FAIL]"
exit $fail
