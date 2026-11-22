#!/bin/sh
# await-outside, 2026-11-22: outside-waits.sps twice, the platform first
# and the load average before and after each run.
# usage, from the repository's root: sh .plans/research/spike/outside-waits.sh [CHEZ]
# On a Guix host: scripts/guix-env sh .plans/research/spike/outside-waits.sh
# (the container's CHEZ is the default there).  PART 4 needs oha at
# build/oha (`make oha`), or OHA naming another.
set -eu
chez=${1:-${CHEZ:-chez}}
spike=.plans/research/spike
libs=src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests
load() { uptime 2>/dev/null || echo "load average: $(cut -d' ' -f1-3 /proc/loadavg)"; }
uname -srm
echo "Chez $("$chez" --version 2>&1)"
for run in 1 2; do
  echo "=== run $run, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  load
  CHEZSCHEMELIBDIRS=$libs "$chez" --program "$spike/outside-waits.sps"
  load
done
