#!/bin/sh
# Strict simulation runner. Usage: run_vvp.sh <file.vvp> <pass-regex> [timeout_s]
# Exits nonzero on: vvp nonzero status, wall-clock timeout, any assertion/failure
# marker in the log, nonzero "fails=N"/"errors=N" counters, or missing pass marker.
VVP_BIN=${VVP:-vvp}
VVPFILE=$1; PASS=$2; TMO=${3:-${SIM_TIMEOUT:-280}}
[ -f "$VVPFILE" ] && [ -n "$PASS" ] || { echo "usage: run_vvp.sh file.vvp pass-regex [timeout_s]" >&2; exit 2; }
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
timeout "$TMO" "$VVP_BIN" "$VVPFILE" </dev/null > "$LOG" 2>&1; rc=$?
cat "$LOG"
if [ $rc -eq 124 ]; then echo "RUN_VVP FAIL: wall-clock timeout after ${TMO}s"; exit 1; fi
if [ $rc -ne 0 ]; then echo "RUN_VVP FAIL: simulator exit status $rc"; exit 1; fi
if grep -Eq 'FATAL|\[FAIL\]|FAILED|\[ERROR\]|TB ERROR|TIMEOUT / FAILURE|VVP Stop|\$stop called|Assertion failed|ERROR:' "$LOG"; then
  echo "RUN_VVP FAIL: failure marker in log"; exit 1; fi
if grep -Eq '(fails|errors|mism)=[1-9]' "$LOG"; then echo "RUN_VVP FAIL: nonzero fails/errors counter"; exit 1; fi
if ! grep -Eq "$PASS" "$LOG"; then echo "RUN_VVP FAIL: pass marker '$PASS' not found (silent/early exit)"; exit 1; fi
echo "RUN_VVP OK"
