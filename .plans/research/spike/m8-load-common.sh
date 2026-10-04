# M8.4, 2026-10-04: what m8-load.sh, m8-read-stop.sh and m8-no-keepalive.sh
# share, sourced by each.

# cpu : Pid -> Seconds — the process's CPU time, user and system: from
# /proc on Linux, from ps's time elsewhere, each to 10 ms.
cpu() {
  if [ -r "/proc/$1/stat" ]; then
    awk -v t="$(getconf CLK_TCK)" '{print ($14 + $15) / t}' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk -F: '{s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s}'
  fi
}

# listening_port : File Pid -> Port — the port the server started as Pid
# logs to File, waited for up to 30 s; the server is killed and the script
# exits 2 if it never says.
listening_port() {
  i=0
  until grep -q '^listening' "$1" 2>/dev/null; do
    sleep 0.1; i=$((i + 1))
    if [ $i -ge 300 ]; then cat "$1" >&2; kill "$2"; exit 2; fi
  done
  awk '/^listening/ {print $3}' "$1"
}

# summary : File Label Requests Cpu0 Cpu1 -> Line — oha's JSON report as
# one line: the rate, the latencies, the server's CPU time a request from
# its CPU time before and after, and oha's tallies.
summary() {
  python3 - "$@" <<'PY'
import json, sys
path, label, n, c0, c1 = sys.argv[1:]
d = json.load(open(path)); m = d['metrics']; l = m['latency_ms']
us = (float(c1) - float(c0)) / int(n) * 1e6
print(f"{label}: {m['requests_per_sec']:7.0f} req/s  p50 {l['p50']:6.3f} ms  "
      f"p99 {l['p99']:7.3f} ms  server CPU {us:5.1f} us/req  codes {d['statusCodeDistribution']}  "
      f"errors {d['errorDistribution']}")
PY
}

# tallies : File -> Line — oha's JSON report's two tallies, or its first
# line when it wrote no report.
tallies() {
  python3 - "$1" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
try:
    d = json.loads(text)
    print(f"codes {d['statusCodeDistribution']}  errors {d['errorDistribution']}")
except ValueError:
    print("no report: " + (text.splitlines() or [''])[0])
PY
}
