#!/bin/sh
# Resumable: advance each seed by N iters until TARGET reached. Usage: m6_run_chunk.sh TARGET
cd "$(dirname "$0")"
for s in 1 2 3 4 5; do
  done_it=$(python3 -c "import numpy as n,os;p='m6_state/ars_seed$s.npz';print(int(n.load(p)['it']) if os.path.exists(p) else 0)")
  [ "$done_it" -lt "$1" ] && { timeout 100 python3 m6_rl_ars.py $s $(( $1 - done_it )) | tail -1; exit; }
done; echo ALLDONE
