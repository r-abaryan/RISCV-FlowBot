#!/bin/sh
# Proves the strict runner (../run_vvp.sh) detects every failure class.
# Each neg_*.v (except neg_pass) MUST make run_vvp.sh exit nonzero; neg_pass MUST succeed.
D=$(cd "$(dirname "$0")" && pwd); bad=0
for f in "$D"/neg_*.v; do
  n=$(basename "$f" .v); out="$D/$n.vvp"
  if ! iverilog -g2012 -o "$out" "$f" >/dev/null 2>&1; then
    rc=1; why="compile failed (iverilog nonzero)"
  else
    case $n in neg_hang) T=3;; *) T=20;; esac
    # hang bench: infinite clock, so vvp never ends -> runner timeout
    "$D/../run_vvp.sh" "$out" "ALL PASSED" $T >/dev/null 2>&1; rc=$?; why="runner rc=$rc"
  fi
  rm -f "$out"
  if [ "$n" = neg_pass ]; then
    [ $rc -eq 0 ] && echo "ok   $n accepted ($why)" || { echo "BAD  $n should pass ($why)"; bad=1; }
  else
    [ $rc -ne 0 ] && echo "ok   $n detected ($why)" || { echo "BAD  $n NOT detected"; bad=1; }
  fi
done
[ $bad -eq 0 ] && echo "NEGATIVE TESTS OK" || { echo "NEGATIVE TESTS FAILED"; exit 1; }
