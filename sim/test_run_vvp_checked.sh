#!/bin/sh
# M11b closure: self-test of sim/run_vvp_checked.sh (takes seconds, needs iverilog/vvp).
# Proves that a SIGTERM-killed run, a missing success marker and a $fatal are all
# rejected, and that only a clean, complete run with its marker is accepted.
R=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUN="sh $R/run_vvp_checked.sh"
cat > "$T/ok.v" <<'V'
module ok; initial begin #10 $display(" SUCCESS: done"); $finish(0); end endmodule
V
cat > "$T/fatal.v" <<'V'
module fatal; initial begin #10 $display("about to fail"); $fatal(1, "[TB FATAL] boom"); end endmodule
V
cat > "$T/hang.v" <<'V'
module hang; reg c = 0; always #1 c = ~c; endmodule
V
cat > "$T/nomark.v" <<'V'
module nomark; initial begin #10 $display("finished without marker"); $finish(0); end endmodule
V
for m in ok fatal hang nomark; do iverilog -o "$T/$m.vvp" "$T/$m.v" || exit 1; done
fails=0
check() { # name expected_rc cmd...
    name=$1; exp=$2; shift 2
    "$@" > "$T/$name.out" 2>&1; rc=$?
    if [ $rc -eq $exp ]; then echo "SELFTEST ok   $name (rc=$rc)"; else echo "SELFTEST FAIL $name (rc=$rc, expected $exp)"; cat "$T/$name.out"; fails=1; fi
}
check clean_pass         0 $RUN --log "$T/1.log" --require "SUCCESS: done" "$T/ok.vvp"
check missing_marker     1 $RUN --log "$T/2.log" --require "SUCCESS: done" "$T/nomark.vvp"
check fatal_is_fail      1 $RUN --log "$T/3.log" --require "SUCCESS: done" "$T/fatal.vvp"
check sigterm_is_fail    1 env VVP_BIN="timeout -s TERM 2 vvp" $RUN --log "$T/4.log" --require "SUCCESS: done" "$T/hang.vvp"
check sigkill_is_fail    1 env VVP_BIN="timeout -s KILL 2 vvp" $RUN --log "$T/5.log" --require "SUCCESS: done" "$T/hang.vvp"
check neg_fatal_ok       0 $RUN --log "$T/6.log" --expect-fail "[TB FATAL] boom" "$T/fatal.vvp"
check neg_clean_rejected 1 $RUN --log "$T/7.log" --expect-fail "[TB FATAL] boom" "$T/ok.vvp"
check neg_killed_rejected 1 env VVP_BIN="timeout -s TERM 2 vvp" $RUN --log "$T/8.log" --expect-fail "x" "$T/hang.vvp"
check usage_no_marker    2 $RUN "$T/ok.vvp"
if [ $fails -eq 0 ]; then echo "RUNNER SELFTEST PASS"; exit 0; fi
echo "RUNNER SELFTEST FAIL"; exit 1
