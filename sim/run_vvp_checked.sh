#!/bin/sh
# M11b closure: run a compiled Icarus simulation and decide PASS/FAIL from BOTH the
# process exit status and explicit log markers, so that a killed, timed-out or
# incomplete simulation can never be reported as PASS.
#
# Why: plain `vvp` traps SIGTERM (e.g. from `timeout`) and exits 0. `vvp -N`
# makes $stop / an interrupt exit non-zero. We use -N and additionally require
# an explicit success marker that is only printed at the very end of a run.
#
# Usage:
#   run_vvp_checked.sh [--log FILE] --require MARKER [--require MARKER ...] SIM.vvp [plusargs]
#       PASS iff vvp exit code == 0, every MARKER (fixed string) is in the log,
#       and the log contains no "FATAL" / "[WDTMON-FAIL]" / "[WDTMON-INCOMPLETE]".
#   run_vvp_checked.sh [--log FILE] --expect-fail MARKER [--expect-fail MARKER ...] SIM.vvp [plusargs]
#       Negative control. PASS iff vvp exit code is non-zero, is NOT a signal /
#       timeout code (124, 128+n), and every MARKER is in the log.
# Exit: 0 = check passed, 1 = check failed, 2 = usage error.
# VVP_BIN may hold a wrapper command, e.g. "timeout -s TERM 600 vvp" (word-split on purpose).
VVP_BIN=${VVP_BIN:-vvp}
LOG=""
MODE=""
REQ_FILE=$(mktemp) || exit 2
trap 'rm -f "$REQ_FILE"' EXIT
while [ $# -gt 0 ]; do
    case "$1" in
        --log) LOG=$2; shift 2 ;;
        --require)
            [ "$MODE" = fail ] && { echo "run_vvp_checked: cannot mix --require and --expect-fail" >&2; exit 2; }
            MODE=pass; printf '%s\n' "$2" >> "$REQ_FILE"; shift 2 ;;
        --expect-fail)
            [ "$MODE" = pass ] && { echo "run_vvp_checked: cannot mix --require and --expect-fail" >&2; exit 2; }
            MODE=fail; printf '%s\n' "$2" >> "$REQ_FILE"; shift 2 ;;
        --) shift; break ;;
        -*) echo "run_vvp_checked: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || { echo "usage: $0 [--log F] (--require M ... | --expect-fail M ...) SIM.vvp [args]" >&2; exit 2; }
[ -n "$MODE" ] || { echo "run_vvp_checked: need at least one --require or --expect-fail marker" >&2; exit 2; }
[ -n "$LOG" ] || LOG="${1%.vvp}.checked.log"

$VVP_BIN -N "$@" > "$LOG" 2>&1
rc=$?
tail -n 12 "$LOG"

missing=0
while IFS= read -r m; do
    if ! grep -qF -- "$m" "$LOG"; then
        echo "run_vvp_checked: required marker NOT found: $m"
        missing=1
    fi
done < "$REQ_FILE"

if [ "$MODE" = pass ]; then
    bad=0
    if grep -qE 'FATAL|\[WDTMON-FAIL\]|\[WDTMON-INCOMPLETE\]' "$LOG"; then
        echo "run_vvp_checked: failure marker present in log"; bad=1
    fi
    if [ $rc -eq 0 ] && [ $missing -eq 0 ] && [ $bad -eq 0 ]; then
        echo "CHECKED PASS: $1 (vvp rc=0, all success markers present, log $LOG)"
        exit 0
    fi
    echo "CHECKED FAIL: $1 (vvp rc=$rc, missing_marker=$missing, failure_marker=$bad, log $LOG)"
    exit 1
else
    if [ $rc -eq 0 ]; then
        echo "CHECKED FAIL (negative control): $1 exited 0 but was expected to fail (log $LOG)"; exit 1
    fi
    if [ $rc -eq 124 ] || [ $rc -gt 128 ]; then
        echo "CHECKED FAIL (negative control): $1 rc=$rc looks like a kill/timeout, not a detected failure (log $LOG)"; exit 1
    fi
    if [ $missing -ne 0 ]; then
        echo "CHECKED FAIL (negative control): $1 rc=$rc but expected failure marker(s) missing (log $LOG)"; exit 1
    fi
    echo "CHECKED PASS (negative control): $1 failed as expected (vvp rc=$rc, markers present, log $LOG)"
    exit 0
fi
