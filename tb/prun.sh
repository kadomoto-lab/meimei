#!/bin/sh
# parallel version of run.sh (same checks, same summary line); each seed runs in its own directory
#   usage: [MODE=...] [CYC=n] [JOBS=n] [STATS=1] prun.sh [N seeds] [first seed]   (MODE: see run.sh)
#   STATS=1: also print the tb/stats.txt event counters summed over all seeds
# build first with run.sh (REBUILD=1 tb/run.sh 1) - this script never rebuilds
cd "$(dirname "$0")/.."
[ -x obj/Vtb ] || { echo "obj/Vtb missing: build with REBUILD=1 tb/run.sh 1"; exit 1; }
N=${1:-100}; S=${2:-1}; JOBS=${JOBS:-$(( $(nproc) / 2 ))}
W=$(mktemp -d)
VTB=$(pwd)/obj/Vtb TB=$(pwd)/tb
seq $S $((S+N-1)) | xargs -P $JOBS -I{} sh -c '
  d='"$W"'/{}; mkdir -p $d; cd $d
  python3 '"$TB"'/gen.py {} '"$MODE"' && '"$VTB"' +CYC='"${CYC:-6000}"' >/dev/null
  if python3 '"$TB"'/cmp.py; then ok=1; else ok=0; fi
  c=$(cat cycles.txt); [ "$c" -gt 0 ] || ok=0
  echo "{} $ok $(cat iss_count.txt) $c" > ../{}.res; cp stats.txt ../{}.stats
  cd ..; [ $ok = 1 ] && rm -rf $d'
fail=0; ti=0; tc=0
for s in $(seq $S $((S+N-1))); do
  set -- $(cat $W/$s.res)
  [ "$2" = 1 ] || { echo "MISMATCH seed $s (kept in $W/$s)"; fail=$((fail+1)); }
  ti=$((ti+$3)); [ "$4" -gt 0 ] && tc=$((tc+$4))
done
[ -n "$STATS" ] && cat $W/*.stats | python3 -c "
import sys
t = {}
for l in sys.stdin:
    f = l.split()
    for k, v in zip(f[0::2], f[1::2]): t[k] = t.get(k, 0) + int(v)
print(' '.join('%s %d' % kv for kv in t.items()))"
echo "$((N-fail))/$N passed, IPC = $(python3 -c "print(round($ti/$tc,3))") ($ti insns / $tc cycles)"
[ $fail = 0 ] && rm -rf $W
