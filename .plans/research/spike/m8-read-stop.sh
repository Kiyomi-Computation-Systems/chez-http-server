#!/bin/sh
# M8.4, 2026-10-04: what stopping and restarting reading costs a request,
# weighed for decision 0004 item 3's alternative, reading during a handler.
# usage, from the repository's root, after `make build`:
#   sh .plans/research/spike/m8-read-stop.sh OHA [ROUNDS] [CHEZ]
# Two copies of HEAD's src and tests: one as it is, which stops reading at
# each message's end and starts again after the response (decision 0004
# item 1), and one patched by m8-read-stop.patch, whose shell never stops.
# oha's requests are not pipelined, so nothing arrives during a handler and
# the patched shell serves them as the other does: the difference is what
# the stop and the start cost, the most reading during a handler could save.
# Each serves tests/serve-child.sps 50,000 GETs kept alive at 1, 10 and 50
# connections, the copies' order alternating by round, with the server's
# CPU time a request (m8-load-common.sh).
set -eu
oha=$1; rounds=${2:-4}; chez=${3:-chez}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/m8-load-common.sh"
root=$(pwd)
vendor=$(make -s -p 2>/dev/null | awk -F' := ' '/^LIBDIRS :=/ {print $2; exit}' \
         | tr ':' '\n' | awk -v r="$root" '$0 != "src" && $0 != "tests" {print r "/" $0}' | paste -sd: -)
work=$(mktemp -d)
mkdir -p "$work/stops" "$work/reads"
git archive HEAD src tests | tar -x -C "$work/stops"
git archive HEAD src tests | tar -x -C "$work/reads"
(cd "$work/reads" && patch -p1 -s < "$here/m8-read-stop.patch")
echo "$(uname -srm), $($chez --version 2>&1), $($oha --version): HEAD $(git rev-parse --short HEAD)"
for round in $(seq 1 "$rounds"); do
  if [ $((round % 2)) = 1 ]; then trees="stops reads"; else trees="reads stops"; fi
  for c in 1 10 50; do
    for tree in $trees; do
      (cd "$work/$tree" && CHEZSCHEMELIBDIRS="$work/$tree/src:$work/$tree/tests:$vendor" \
         exec "$chez" --program tests/serve-child.sps) > "$work/server.txt" 2>&1 &
      pid=$!
      port=$(listening_port "$work/server.txt" $pid)
      c0=$(cpu $pid)
      "$oha" --no-tui -n 50000 -c $c --output-format json -t 10s "http://127.0.0.1:$port/" > "$work/oha.json" 2>&1 || true
      c1=$(cpu $pid)
      kill $pid; wait $pid 2>/dev/null || true
      summary "$work/oha.json" "$(printf 'round %s %-5s c=%3s' "$round" "$tree" "$c")" 50000 "$c0" "$c1"
    done
  done
done
rm -rf "$work"
