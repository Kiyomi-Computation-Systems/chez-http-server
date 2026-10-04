#!/bin/sh
# M8.4, 2026-10-04: the first throughput numbers, oha against `serve` beside
# Node's http module, for the ledger and CHANGELOG.md.
# usage, from the repository's root, after `make build`:
#   sh .plans/research/spike/m8-load.sh OHA [ROUNDS] [CHEZ]
# tests/serve-child.sps, which uses the facade alone and answers "served",
# and m8-load-node.js, Node's http answering the same, each serve 50,000
# GETs from oha on connections kept alive, at 1, 10, 50, 100 and 500 at a
# time, the two servers' order alternating by round.  Each line gives oha's
# rate and latencies, and the server's CPU time a request, read before and
# after the run (m8-load-common.sh).
set -eu
oha=$1; rounds=${2:-3}; chez=${3:-chez}
here=$(dirname "$0")
. "$here/m8-load-common.sh"
libdirs=$(make -s -p 2>/dev/null | awk -F' := ' '/^LIBDIRS :=/ {print $2; exit}')
work=$(mktemp -d)
echo "$(uname -srm), $($chez --version 2>&1), node $(node --version 2>/dev/null), $($oha --version)"
for round in $(seq 1 "$rounds"); do
  if [ $((round % 2)) = 1 ]; then servers="chez node"; else servers="node chez"; fi
  for c in 1 10 50 100 500; do
    for server in $servers; do
      if [ $server = chez ]; then
        CHEZSCHEMELIBDIRS=$libdirs "$chez" --program tests/serve-child.sps > "$work/server.txt" 2>&1 &
      else
        node "$here/m8-load-node.js" > "$work/server.txt" 2>&1 &
      fi
      pid=$!
      port=$(listening_port "$work/server.txt" $pid)
      c0=$(cpu $pid)
      "$oha" --no-tui -n 50000 -c $c --output-format json -t 10s "http://127.0.0.1:$port/" > "$work/oha.json" 2>&1 || true
      c1=$(cpu $pid)
      kill $pid; wait $pid 2>/dev/null || true
      summary "$work/oha.json" "$(printf 'round %s %-4s c=%3s' "$round" "$server" "$c")" 50000 "$c0" "$c1"
    done
  done
done
rm -rf "$work"
