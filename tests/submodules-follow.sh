#!/bin/sh
# tests/submodules-follow.sh
#
# Checks that `make submodules` brings along an inner submodule already checked
# out when its parent's pin moves, as `git clone --recursive` leaves uriparse's
# byte-machine, and clones none that was not. The checkout is a scratch
# repository whose five submodules sit at the paths the Makefile names, each a
# local repository of a commit or two, so the check needs no network. It runs
# the Makefile given (SUBMODULES_MAKEFILE, default this checkout's) there.
#
# Exits 0 when every check passes, 1 when one fails, and 2 when the scratch
# checkout cannot be made.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
makefile=${SUBMODULES_MAKEFILE:-$root/Makefile}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/submodules-follow.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

# Every git here, the Makefile's included, may clone from a local path, signs
# nothing, and commits under a name of its own, whatever the user's config.
export GIT_CONFIG_COUNT=5 \
  GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
  GIT_CONFIG_KEY_1=commit.gpgsign GIT_CONFIG_VALUE_1=false \
  GIT_CONFIG_KEY_2=user.name GIT_CONFIG_VALUE_2=submodules-follow \
  GIT_CONFIG_KEY_3=user.email GIT_CONFIG_VALUE_3=submodules-follow@example.invalid \
  GIT_CONFIG_KEY_4=init.defaultBranch GIT_CONFIG_VALUE_4=main

broken() { echo "submodules-follow: cannot make the scratch checkout: $*" >&2; exit 2; }

# repo DIR WORD: a repository whose one file says WORD, committed.
repo() {
  mkdir -p "$1" && git -C "$1" init -q && echo "$2" > "$1/file" \
    && git -C "$1" add file && git -C "$1" commit -q -m "$2"
}
# commit DIR WORD: a further commit saying WORD.
commit() { echo "$2" > "$1/file" && git -C "$1" commit -q -am "$2"; }

bm=$tmp/byte-machine
{ repo "$bm" one && c1=$(git -C "$bm" rev-parse HEAD) \
    && commit "$bm" two && c2=$(git -C "$bm" rev-parse HEAD); } || broken byte-machine

uri=$tmp/uriparse
{ repo "$uri" one && git -C "$uri" submodule add -q "$bm" vendor/byte-machine \
    && git -C "$uri/vendor/byte-machine" checkout -q "$c1" \
    && git -C "$uri" add vendor/byte-machine && git -C "$uri" commit -q -m "byte-machine one" \
    && u1=$(git -C "$uri" rev-parse HEAD) \
    && git -C "$uri/vendor/byte-machine" checkout -q "$c2" \
    && git -C "$uri" add vendor/byte-machine && git -C "$uri" commit -q -m "byte-machine two" \
    && u2=$(git -C "$uri" rev-parse HEAD); } || broken uriparse

libuv=$tmp/chez-libuv
{ repo "$tmp/libuv-c" c && repo "$libuv" one \
    && git -C "$libuv" submodule add -q "$tmp/libuv-c" vendor/libuv \
    && git -C "$libuv" commit -q -m "libuv"; } || broken chez-libuv
for r in chez-srfi vtest2 chez-httparse; do repo "$tmp/$r" one || broken "$r"; done

# The checkout: uriparse at u1 with its byte-machine checked out (c1), then
# a commit moving uriparse's pin to u2, as a pull brings, and uriparse left
# at u1 as it was before `make submodules` runs.
co=$tmp/checkout
{ mkdir -p "$co" && git -C "$co" init -q \
    && git -C "$co" submodule add -q "$libuv" vendor/chez-libuv \
    && git -C "$co" submodule add -q "$uri" vendor/uriparse \
    && git -C "$co" submodule add -q "$tmp/chez-srfi" vendor/chez-srfi \
    && git -C "$co" submodule add -q "$tmp/vtest2" vendor/vtest2 \
    && git -C "$co" submodule add -q "$tmp/chez-httparse" vendor/chez-httparse \
    && git -C "$co/vendor/uriparse" checkout -q "$u1" \
    && git -C "$co" add vendor/uriparse && git -C "$co" commit -q -m "uriparse u1" \
    && git -C "$co" submodule update -q --init --recursive vendor/uriparse \
    && git -C "$co/vendor/uriparse" checkout -q "$u2" \
    && git -C "$co" add vendor/uriparse && git -C "$co" commit -q -m "uriparse u2" \
    && git -C "$co/vendor/uriparse" checkout -q "$u1"; } || broken checkout
[ "$(git -C "$co/vendor/uriparse/vendor/byte-machine" rev-parse HEAD)" = "$c1" ] \
  || broken "uriparse's byte-machine is not checked out at its first commit"

if make -s -C "$co" -f "$makefile" submodules > "$tmp/make.log" 2>&1; then
  ok "make submodules exits 0"
else
  sed 's/^/  /' "$tmp/make.log" >&2
  bad "make submodules failed"
fi

got=$(git -C "$co/vendor/uriparse" rev-parse HEAD)
[ "$got" = "$u2" ] && ok "uriparse is at its new pin" || bad "uriparse is at $got, not its new pin $u2"

got=$(git -C "$co/vendor/uriparse/vendor/byte-machine" rev-parse HEAD)
if [ "$got" = "$c2" ]; then
  ok "uriparse's byte-machine follows to the commit the new pin records"
else
  bad "uriparse's byte-machine stayed at $got, not the new pin's $c2"
fi

dirty=$(git -C "$co/vendor/uriparse" status --porcelain --untracked-files=no)
[ -z "$dirty" ] && ok "uriparse has no local edits, as make check-pins asks" \
  || bad "uriparse shows edits: $dirty"

if [ -e "$co/vendor/chez-libuv/vendor/libuv/file" ]; then
  bad "chez-libuv's inner submodule, never checked out, was cloned"
else
  ok "chez-libuv's inner submodule, never checked out, stays uncloned"
fi

echo "submodules-follow: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "submodules-follow: all checks passed"
[ "$fail" -eq 0 ]
