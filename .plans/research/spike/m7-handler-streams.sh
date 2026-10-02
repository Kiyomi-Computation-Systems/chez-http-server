#!/bin/sh
# M7, 2026-10-02: 16 MiB each way with curl against m7-handler-turns.sps.
# usage, from the repository's root: sh .plans/research/spike/m7-handler-streams.sh [CHEZ]
# Builds the prototype coroutine shell as m7-handler-turns.sh does, then for
# each of three rounds starts a server in each of four modes, the order
# rotating: default (today's), deferred (the handler after the turn, in
# place), every (every call on a coroutine, the reader on credit) and
# every-all (the same, each drain run until nothing is ready).
# Against each, curl uploads 16 MiB three times (-T, a Content-Length body)
# to /up, and downloads 16 MiB three times from /down, unlimited, each
# printing its seconds and bytes a second.
set -eu
chez=${1:-chez}
spike=.plans/research/spike
work=$(mktemp -d)
mkdir -p "$work/m7"
git show 4a7748b:src/http-server/private/shell.sls > "$work/m7/coroutine-shell.sls" 2>/dev/null \
  || cp src/http-server/private/shell.sls "$work/m7/coroutine-shell.sls"
patch -s "$work/m7/coroutine-shell.sls" < "$spike/m7-coroutine-shell.patch"
cp "$spike/m7/scheduler.sls" "$work/m7/"
head -c 16777216 /dev/zero > "$work/sixteen"
libs=src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests:$work
uname -srm; "$chez" --version 2>&1; curl --version | head -1
for round in 1 2 3; do
  case $round in
    1) modes="default deferred every every-all" ;;
    2) modes="deferred every every-all default" ;;
    3) modes="every every-all default deferred" ;;
  esac
  for mode in $modes; do
    CHEZSCHEMELIBDIRS=$libs "$chez" --program "$spike/m7-handler-turns.sps" "$mode" > "$work/server.txt" 2>&1 &
    pid=$!
    i=0
    until grep -q '^port' "$work/server.txt" 2>/dev/null; do
      sleep 0.1; i=$((i + 1))
      if [ $i -ge 300 ]; then echo "no port from $mode"; cat "$work/server.txt"; kill $pid; exit 2; fi
    done
    port=$(awk '/^port/ {print $2}' "$work/server.txt")
    for k in 1 2 3; do
      up=$(curl -sS -w ' %{time_total} s %{speed_upload} B/s' -T "$work/sixteen" "http://127.0.0.1:$port/up" | tr -d '\n')
      echo "round $round, $mode, upload $k: answered $up"
    done
    for k in 1 2 3; do
      down=$(curl -sS -o /dev/null -w '%{size_download} B in %{time_total} s %{speed_download} B/s' "http://127.0.0.1:$port/down")
      echo "round $round, $mode, download $k: $down"
    done
    kill $pid; wait $pid 2>/dev/null || true
  done
done
rm -rf "$work"
