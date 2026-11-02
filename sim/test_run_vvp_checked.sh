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
cat > "$T/early.v" <<'V'
module early; reg c = 0; always #1 c = ~c;
initial begin #10 $display("[MARK] early context"); #200000000 $fatal(1, "[TB FATAL] late cause"); end
final $display("final block ran");
endmodule
V
cat > "$T/twofatal.v" <<'V'
module twofatal; initial begin #10 $display("FATAL: fake earlier line"); $fatal(1, "[TB FATAL] boom"); end endmodule
V
cat > "$T/nomark.v" <<'V'
module nomark; initial begin #10 $display("finished without marker"); $finish(0); end endmodule
V
for m in ok fatal hang nomark twofatal; do iverilog -o "$T/$m.vvp" "$T/$m.v" || exit 1; done
iverilog -g2012 -o "$T/early.vvp" "$T/early.v" || exit 1
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
# M11b harness fix 2: an external interruption after an early context marker must
# not pass as the expected failure. --preserve-status hands vvp's own rc (1 under
# -N, the same as $fatal) to the runner, which is exactly the case that used to pass.
check neg_sigint_after_ctx 1 env VVP_BIN="timeout --preserve-status -s INT 2 vvp" $RUN --log "$T/9.log" --expect-fail "[MARK] early context" "$T/early.vvp"
check neg_sigint_seen_only 1 env VVP_BIN="timeout --preserve-status -s INT 2 vvp" $RUN --log "$T/10.log" --expect-fail "late cause" --expect-seen "[MARK] early context" "$T/early.vvp"
check neg_sigterm_preserved 1 env VVP_BIN="timeout --preserve-status -s TERM 2 vvp" $RUN --log "$T/11.log" --expect-fail "late cause" --expect-seen "[MARK] early context" "$T/early.vvp"
check neg_cause_not_on_fatal 1 $RUN --log "$T/12.log" --expect-fail "about to fail" "$T/fatal.vvp"
check neg_seen_ok        0 $RUN --log "$T/13.log" --expect-fail "[TB FATAL] boom" --expect-seen "about to fail" "$T/fatal.vvp"
check neg_seen_missing   1 $RUN --log "$T/14.log" --expect-fail "[TB FATAL] boom" --expect-seen "never printed" "$T/fatal.vvp"
check neg_two_fatal_lines 1 $RUN --log "$T/15.log" --expect-fail "[TB FATAL] boom" "$T/twofatal.vvp"
check usage_no_marker    2 $RUN "$T/ok.vvp"
check usage_seen_with_require 2 $RUN --require "SUCCESS: done" --expect-seen "x" "$T/ok.vvp"
check usage_seen_alone   2 $RUN --expect-seen "x" "$T/ok.vvp"
if [ $fails -eq 0 ]; then echo "RUNNER SELFTEST PASS"; exit 0; fi
echo "RUNNER SELFTEST FAIL"; exit 1
