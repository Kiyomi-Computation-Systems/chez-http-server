#!/bin/sh
# tests/srfi-links.sh
#
# Checks that `make srfi` links SRFI-64 in a checkout whose path holds a space.
# The checkout is a scratch repository under "with space/", whose chez-srfi is
# a local submodule of a few files, so the check needs no network. It runs the
# Makefile given (SRFI_MAKEFILE, default this checkout's) there.
#
# Exits 0 when every check passes, 1 when one fails, and 2 when the scratch
# checkout cannot be made.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
makefile=${SRFI_MAKEFILE:-$root/Makefile}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/srfi-links.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

g() {
  git -c user.name=srfi-links -c user.email=srfi-links@example.invalid \
      -c init.defaultBranch=main -c protocol.file.allow=always "$@"
}

src="$tmp/srfi-src"
mkdir -p "$src/%3a64"
printf '(library (srfi :64) (export) (import (rnrs)))\n' > "$src/%3a64.sls"
printf '(library (srfi :64 testing) (export) (import (rnrs)))\n' > "$src/%3a64/testing.sls"
printf 'not a library\n' > "$src/README"
{ g -C "$src" init -q && g -C "$src" add -A && g -C "$src" commit -q -m srfi; } \
  || { echo "srfi-links: cannot make the submodule's repository" >&2; exit 2; }

repo="$tmp/with space/checkout"
mkdir -p "$repo"
{ g -C "$repo" init -q && g -C "$repo" submodule add -q "$src" vendor/chez-srfi \
    && g -C "$repo" commit -q -m checkout; } \
  || { echo "srfi-links: cannot make the checkout" >&2; exit 2; }

if make -s -C "$repo" -f "$makefile" srfi > "$tmp/make.log" 2>&1; then
  ok "make srfi exits 0 in a checkout under \"with space/\""
else
  sed 's/^/  /' "$tmp/make.log" >&2
  bad "make srfi failed in a checkout under \"with space/\""
fi

links="$repo/build/scheme-libs/srfi"
for name in %3a64.sls %3a64 README :64.sls :64; do
  case $name in
    :*) target="$repo/vendor/chez-srfi/%3a${name#:}" ;;
    *) target="$repo/vendor/chez-srfi/$name" ;;
  esac
  if [ -L "$links/$name" ] && [ "$(readlink "$links/$name")" = "$target" ]; then
    ok "$name links to the submodule's ${target##*/}"
  else
    bad "$name does not link to $target (it reads: $(readlink "$links/$name" 2>/dev/null || echo nothing))"
  fi
done

if [ -e "$links/:README" ] || [ -e "$links/README:" ]; then
  bad "a name with no %3a gained a decoded twin"
else
  ok "a name with no %3a has no decoded twin"
fi

echo "srfi-links: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "srfi-links: all checks passed"
[ "$fail" -eq 0 ]
