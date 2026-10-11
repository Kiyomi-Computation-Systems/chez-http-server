#!/bin/sh
# The lost close, one measurement: taker-close-server.sps in MODE (cap or
# control), and RUNS clients against it, each sending TOTAL bytes in
# CHUNK-byte writes.  SHAPE picks the client: `threads` (the default) and
# `serial`, taker-close-client.c's two, or `node`, taker-close-client.mjs.
# The server runs on CHEZSCHEMELIBDIRS (the project's library path, or a
# shadow root before it) with ${CHEZ:-chez}; the C client is built into OUT
# (a fresh temporary directory by default).
#
#   CHEZSCHEMELIBDIRS=... sh taker-close-run.sh cap 100 4194304 65536 [SHAPE]
set -eu
mode=${1:?mode} runs=${2:?runs} total=${3:?total} chunk=${4:?chunk} shape=${5:-threads}
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$(mktemp -d)}
cc -O2 -pthread -o "$out/taker-close-client" "$here/taker-close-client.c"
log="$out/taker-close-server.$$.log"
"${CHEZ:-chez}" --program "$here/taker-close-server.sps" "$mode" > "$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
port=
i=0
while [ -z "$port" ] && [ "$i" -lt 200 ]; do
  port=$(sed -n 's/^listening 127\.0\.0\.1 \([0-9]*\)$/\1/p' "$log" | head -n 1)
  [ -n "$port" ] || { sleep 0.05; i=$((i + 1)); }
done
[ -n "$port" ] || { echo "the server did not listen:"; cat "$log"; exit 2; }
case "$shape" in
  node) node "$here/taker-close-client.mjs" "$port" "$runs" "$total" "$chunk" ;;
  serial) "$out/taker-close-client" "$port" "$runs" "$total" "$chunk" serial ;;
  *) "$out/taker-close-client" "$port" "$runs" "$total" "$chunk" ;;
esac
