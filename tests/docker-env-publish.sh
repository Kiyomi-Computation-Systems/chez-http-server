#!/bin/sh
# Host-side, with Docker: `scripts/docker-env -p PORT` serves to the host.
# Starts examples/hello.sps through the launcher, asks it from the host
# with curl, then sends the launcher SIGTERM, as `kill` would, and waits
# for the container to go and the port to be free. `make check-docker`
# runs this after the container's self-test, so the image is built.
#
# Not a drain: SIGTERM reaches make alone, which leaves its recipe running
# here as it does on a host, and the container ends with make. Ctrl-C at a
# terminal signals the server too, and it drains.
#
# CHECK_DOCKER_PORT picks the port, 18080 by default; it must be free on
# the host's 127.0.0.1.
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
port=${CHECK_DOCKER_PORT:-18080}

tmp=$(mktemp -d)
pid=
cleanup() {
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail=0
ok()  { echo "check-docker: ok $*"; }
bad() { echo "check-docker: FAILED $*" >&2; fail=1; }

command -v curl >/dev/null 2>&1 || { bad "publish: no curl on the host to ask the server with"; exit 1; }

scripts/docker-env -p "$port" make --no-print-directory run PROGRAM=examples/hello.sps \
  </dev/null >"$tmp/server.log" 2>&1 &
pid=$!

# The first run builds the shim; later ones start in seconds.
body=
i=0
while [ "$i" -lt 180 ]; do
  body=$(curl -s -m 2 "http://127.0.0.1:$port/") && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
  i=$((i + 1))
done
if [ "$body" = Hello ]; then
  ok "publish (curl http://127.0.0.1:$port/ from the host answered Hello)"
else
  bad "publish: curl http://127.0.0.1:$port/ from the host got '${body:-nothing}'; the launcher's output:"
  sed 's/^/  /' "$tmp/server.log" >&2
fi

kill -TERM "$pid" 2>/dev/null
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  bad "publish-stop: the launcher still runs 30 s after SIGTERM"
elif curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/"; then
  pid=
  bad "publish-stop: the launcher is gone, but 127.0.0.1:$port still answers"
else
  pid=
  ok "publish-stop (SIGTERM ended the container and freed 127.0.0.1:$port)"
fi

exit "$fail"
