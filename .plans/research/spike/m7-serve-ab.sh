#!/bin/sh
# M7.1, 2026-10-02: the finished tree's `serve` beside main's, for the ledger.
# usage, from the repository's root: sh .plans/research/spike/m7-serve-ab.sh MAIN-TREE [CHEZ]
# MAIN-TREE holds main's src and tests at 4a7748b, made by
#   git archive 4a7748b src tests | tar -x -C MAIN-TREE
# tests/serve-child.sps, which uses the facade alone, runs on each tree's
# library path; ab -k sends it 50,000 GETs at 1 and at 32 connections, in
# three rounds, the trees' order alternating.
set -eu
main=$1; chez=${2:-chez}
prog=tests/serve-child.sps
vendor=vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests
work=$(mktemp -d)
for round in 1 2 3; do
  if [ $round = 2 ]; then trees="branch main"; else trees="main branch"; fi
  for c in 1 32; do
    for tree in $trees; do
      if [ $tree = main ]; then libs=$main/src:$main/tests:$vendor; else libs=src:tests:$vendor; fi
      CHEZSCHEMELIBDIRS=$libs "$chez" --program "$prog" > "$work/server.txt" 2>&1 &
      pid=$!
      i=0
      until grep -q '^listening' "$work/server.txt" 2>/dev/null; do
        sleep 0.1; i=$((i + 1)); if [ $i -ge 300 ]; then cat "$work/server.txt"; kill $pid; exit 2; fi
      done
      port=$(awk '/^listening/ {print $3}' "$work/server.txt")
      ab -k -n 50000 -c "$c" "http://127.0.0.1:$port/" > "$work/ab.txt" 2>&1 || true
      kill $pid; wait $pid 2>/dev/null || true
      echo "round $round, $c connection(s), $tree: $(awk '/^Requests per second/ {print $4}' "$work/ab.txt") req/s, $(awk '/^Complete requests/ {print $3}' "$work/ab.txt") complete, $(awk '/^Failed requests/ {print $3}' "$work/ab.txt") failed"
    done
  done
done
rm -rf "$work"
