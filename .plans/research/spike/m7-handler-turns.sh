#!/bin/sh
# M7, 2026-10-02: ab -k against m7-handler-turns.sps in each mode.
# usage, from the repository's root: sh .plans/research/spike/m7-handler-turns.sh [CHEZ] [REQUESTS]
# Builds the prototype coroutine shell from the libuv shell at 4a7748b and
# m7-coroutine-shell.patch, in a directory of its own, then for each of
# three rounds runs ab -k with 1 and with 32 connections against a server in
# each of the six modes, the modes' order rotating from round to round.
set -eu
chez=${1:-chez}
n=${2:-50000}
spike=.plans/research/spike
work=$(mktemp -d)
mkdir -p "$work/m7"
# A copy of the tree with no git history (the Linux run's) takes the shell
# from the tree, which must then be 4a7748b's.
git show 4a7748b:src/http-server/private/shell.sls > "$work/m7/coroutine-shell.sls" 2>/dev/null \
  || cp src/http-server/private/shell.sls "$work/m7/coroutine-shell.sls"
patch -s "$work/m7/coroutine-shell.sls" < "$spike/m7-coroutine-shell.patch"
cp "$spike/m7/scheduler.sls" "$work/m7/"
libs=src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests:$work
uname -srm; "$chez" --version 2>&1; ab -V | head -1
for round in 1 2 3; do
  case $round in
    1) modes="default once coroutine deferred every every-all" ;;
    2) modes="once coroutine deferred every every-all default" ;;
    3) modes="coroutine deferred every every-all default once" ;;
  esac
  for c in 1 32; do
    for mode in $modes; do
      CHEZSCHEMELIBDIRS=$libs "$chez" --program "$spike/m7-handler-turns.sps" "$mode" > "$work/server.txt" 2>&1 &
      pid=$!
      i=0
      until grep -q '^port' "$work/server.txt" 2>/dev/null; do
        sleep 0.1; i=$((i + 1))
        if [ $i -ge 300 ]; then echo "no port from $mode"; cat "$work/server.txt"; kill $pid; exit 2; fi
      done
      port=$(awk '/^port/ {print $2}' "$work/server.txt")
      ab -k -n "$n" -c "$c" "http://127.0.0.1:$port/" > "$work/ab.txt" 2>&1 || true
      kill $pid; wait $pid 2>/dev/null || true
      rps=$(awk '/^Requests per second/ {print $4}' "$work/ab.txt")
      mean=$(awk '/^Time per request/ && /\(mean\)$/ {print $4}' "$work/ab.txt")
      done_=$(awk '/^Complete requests/ {print $3}' "$work/ab.txt")
      failed=$(awk '/^Failed requests/ {print $3}' "$work/ab.txt")
      echo "round $round, $c connection(s), $mode: $rps req/s, $mean ms a request, $done_ complete, $failed failed"
    done
  done
done
rm -rf "$work"
