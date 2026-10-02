#!/bin/sh
# M7.2, 2026-10-02: m7-waits.sps twice on the tree's scheduler, and twice on
# it patched by m7-scheduler-escape.patch, alternating.
# usage, from the repository's root: sh .plans/research/spike/m7-waits.sh [CHEZ]
set -eu
chez=${1:-chez}
spike=.plans/research/spike
work=$(mktemp -d)
mkdir -p "$work/http-server/private"
cp src/http-server/private/scheduler.sls "$work/http-server/private/"
patch -s "$work/http-server/private/scheduler.sls" < "$spike/m7-scheduler-escape.patch"
libs=src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs
uname -srm
for run in 1 2; do
  echo "=== the tree's scheduler, run $run"
  CHEZSCHEMELIBDIRS=$libs "$chez" --program "$spike/m7-waits.sps"
  echo "=== the scheduler patched, run $run"
  CHEZSCHEMELIBDIRS=$work:$libs "$chez" --program "$spike/m7-waits.sps"
done
rm -rf "$work"
