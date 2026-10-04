#!/bin/sh
# M8.4, 2026-10-04: what fails when oha opens a connection for each request,
# on Darwin, for the ledger (the review's first finding).
# usage, from the repository's root, after `make build`:
#   sh .plans/research/spike/m8-no-keepalive.sh OHA [ROUNDS] [CHEZ]
# oha sends 20,000 GETs to tests/serve-child.sps, each on a connection of
# its own, at 10, 100 and 500 at a time.  While it runs, netstat is read
# every half second for the connections on loopback in TIME_WAIT: those
# whose local port is the server's, closed first by the server, and those
# whose remote port is, closed first by oha.  Each line gives the most of
# each, the kernel's listen-queue overflows over the run, and oha's tallies.
# Before each run it waits, up to a minute, for the last run's TIME_WAITs
# to clear.  macOS's netstat only: Linux's TIME_WAIT reads differently.
set -eu
oha=$1; rounds=${2:-2}; chez=${3:-chez}
here=$(dirname "$0")
. "$here/m8-load-common.sh"
libdirs=$(make -s -p 2>/dev/null | awk -F' := ' '/^LIBDIRS :=/ {print $2; exit}')
work=$(mktemp -d)
# time_waits : -> "SERVER CLIENT ALL", the loopback TIME_WAITs by side, for port $1.
time_waits() {
  netstat -an -p tcp | awk -v p="$1" '
    $6 == "TIME_WAIT" && $4 ~ /^127\.0\.0\.1\./ {
      n = split($4, a, "."); m = split($5, b, ".");
      all++; if (a[n] == p) s++; else if (b[m] == p) c++ }
    END { print s + 0, c + 0, all + 0 }'
}
overflows() { netstat -s -p tcp | awk '/listen queue overflow/ {print $1}'; }
echo "$(uname -srm), $($chez --version 2>&1), $($oha --version); somaxconn $(sysctl -n kern.ipc.somaxconn), ports $(sysctl -n net.inet.ip.portrange.first)-$(sysctl -n net.inet.ip.portrange.last), msl $(sysctl -n net.inet.tcp.msl) ms"
for round in $(seq 1 "$rounds"); do
  for c in 10 100 500; do
    i=0
    while [ "$(time_waits 0 | awk '{print $3}')" -gt 100 ] && [ $i -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
    CHEZSCHEMELIBDIRS=$libdirs "$chez" --program tests/serve-child.sps > "$work/server.txt" 2>&1 &
    pid=$!
    port=$(listening_port "$work/server.txt" $pid)
    o0=$(overflows)
    "$oha" --no-tui -n 20000 -c $c --disable-keepalive --output-format json -t 10s \
      "http://127.0.0.1:$port/" > "$work/oha.json" 2>&1 &
    opid=$!
    most_s=0; most_c=0
    while kill -0 $opid 2>/dev/null; do
      set -- $(time_waits "$port")
      [ "$1" -gt $most_s ] && most_s=$1
      [ "$2" -gt $most_c ] && most_c=$2
      sleep 0.5
    done
    wait $opid || true
    o1=$(overflows)
    kill $pid; wait $pid 2>/dev/null || true
    printf 'round %s c=%3s: TIME_WAIT at most %s on the server side, %s on the client side; listen-queue overflows %s; ' \
      "$round" "$c" "$most_s" "$most_c" $((o1 - o0))
    tallies "$work/oha.json"
  done
done
rm -rf "$work"
