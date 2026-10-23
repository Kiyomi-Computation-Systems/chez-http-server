#!/bin/sh
# tests/check-akku-manifest.sh: what scripts/check-akku-manifest.ss promises,
# checked on small trees of its own, so it needs no submodule and no akku.
# Each row starts from a tree where everything agrees, changes one thing, and
# runs the check in it. `make check-site-deps` runs it.
set -u

CHEZ=${CHEZ:-chez}
script=$PWD/scripts/check-akku-manifest.ss
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; fails=$((fails + 1)); }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-akku-manifest-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# manifest FILE NAME VERSION [DEPENDS...]: an Akku.manifest; each DEPENDS is
# NAME:RANGE. A development dependency rides along in every one.
manifest() {
  out=$1 name=$2 version=$3; shift 3
  deps=
  for d in "$@"; do deps="$deps (\"${d%%:*}\" \"${d#*:}\")"; done
  { echo '#!r6rs ; -*- scheme -*-'
    echo '(import (akku format manifest))'
    echo ';; a comment, as the real one has'
    echo "(akku-package (\"$name\" \"$version\")"
    echo '  (synopsis "s") (authors "a") (license "BSD-3-Clause")'
    [ -z "$deps" ] || echo "  (depends$deps)"
    echo '  (depends/dev ("dev-c" "^2.0.0")))'; } > "$out"
}

# lock FILE [NAME:VERSION...]: a lock in `akku lock`'s layout.
lock() {
  out=$1; shift
  { echo '#!r6rs ; -*- mode: scheme; coding: utf-8 -*-'
    echo '(import (akku format lockfile))'
    echo '(projects'
    for p in "$@"; do
      n=${p%%:*} v=${p#*:}
      printf '  ((name "%s")\n   (location\n     (url "https://archive.akkuscm.org/archive/pkg/x/%s_%s_repack.tar.xz"))\n   (content\n     (sha256\n       "00")))\n' "$n" "$n" "$v"
    done
    echo ')'; } > "$out"
}

# tree NAME: a tree where everything agrees, at $scratch/NAME.
tree() {
  t=$scratch/$1
  mkdir -p "$t/vendor/a" "$t/vendor/b/vendor/c"
  printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n## [0.7.0] - 2026-10-16\n\n## [0.6.0] - 2026-10-12\n' \
    > "$t/CHANGELOG.md"
  manifest "$t/Akku.manifest" the-server 0.7.0 pkg-a:^1.2.0 pkg-c:^0.3.4
  manifest "$t/vendor/a/Akku.manifest" pkg-a 1.2.0
  manifest "$t/vendor/b/vendor/c/Akku.manifest" pkg-c 0.3.4
  lock "$t/Akku.lock" dev-c:2.0.0 pkg-a:1.2.0 pkg-c:0.3.4
}

maps="pkg-a=vendor/a pkg-c=vendor/b/vendor/c"

# run NAME [MAPPING...]: the check in tree NAME; MAPPING defaults to $maps.
run() {
  t=$scratch/$1; shift
  [ "$#" -gt 0 ] || set -- $maps
  (cd "$t" && "$CHEZ" -q --script "$script" "$@") > "$scratch/out" 2>&1
}

# expect_fail ROW NAME PATTERN... : the check in NAME fails and its output
# holds every PATTERN.
expect_fail() {
  row=$1 name=$2; shift 2
  if run "$name"; then
    fail "$row (it passed)"; cat "$scratch/out" >&2; return
  fi
  for p in "$@"; do
    grep -q -- "$p" "$scratch/out" || { fail "$row (no '$p')"; cat "$scratch/out" >&2; return; }
  done
  pass "$row"
}

# 1. Everything agrees: passes, and names what it held.
tree agree
if run agree && grep -q 'the-server 0.7.0 is CHANGELOG.md.s latest release' "$scratch/out" \
   && grep -q 'pkg-a \^1.2.0: vendor/a is 1.2.0, and Akku.lock locks 1.2.0' "$scratch/out" \
   && grep -q 'pkg-c \^0.3.4: vendor/b/vendor/c is 0.3.4' "$scratch/out"; then
  pass "a tree that agrees passes, and names each dependency"
else
  fail "a tree that agrees passes, and names each dependency"; cat "$scratch/out" >&2
fi

# 2. The package's version is not the latest release.
tree version
manifest "$scratch/version/Akku.manifest" the-server 0.8.0 pkg-a:^1.2.0 pkg-c:^0.3.4
expect_fail "a version that is not the latest release fails, naming both" version 0.8.0 0.7.0

# 3. A CHANGELOG with no release yet.
tree norelease
printf '# Changelog\n\n## [Unreleased]\n' > "$scratch/norelease/CHANGELOG.md"
expect_fail "a CHANGELOG.md with no release fails" norelease 'no release'

# 4. A floor below the vendored version, locked at the floor, so only the
#    vendored copy disagrees.
tree floor
manifest "$scratch/floor/Akku.manifest" the-server 0.7.0 pkg-a:^1.1.0 pkg-c:^0.3.4
lock "$scratch/floor/Akku.lock" dev-c:2.0.0 pkg-a:1.1.0 pkg-c:0.3.4
expect_fail "a floor that is not the vendored version fails, naming both" floor \
  'pkg-a \^1.1.0, but vendor/a is 1.2.0' 'floor is the vendored version'

# 5. The vendored copy is another package.
tree other
manifest "$scratch/other/vendor/a/Akku.manifest" pkg-z 1.2.0
expect_fail "a vendored copy of another package fails, naming it" other vendor/a pkg-z

# 6. The vendored copy has no manifest (a submodule never cloned).
tree absent
rm "$scratch/absent/vendor/b/vendor/c/Akku.manifest"
expect_fail "a vendored copy with no Akku.manifest fails, naming it" absent vendor/b/vendor/c 'make submodules'

# 7. A range that is not a caret range.
tree exact
manifest "$scratch/exact/Akku.manifest" the-server 0.7.0 pkg-a:1.2.0 pkg-c:^0.3.4
expect_fail "a range that is not ^VERSION fails" exact 'pkg-a the range 1.2.0' 'must be \^VERSION'

# 8. A dependency with no vendored copy named.
tree unmapped
if run unmapped pkg-a=vendor/a; then
  fail "a dependency with no vendored copy fails (it passed)"; cat "$scratch/out" >&2
elif grep -q 'pkg-c' "$scratch/out"; then
  pass "a dependency with no vendored copy fails, naming it"
else
  fail "a dependency with no vendored copy fails, naming it"; cat "$scratch/out" >&2
fi

# 9. A vendored copy on the library path that depends does not name.
tree undeclared
manifest "$scratch/undeclared/Akku.manifest" the-server 0.7.0 pkg-a:^1.2.0
expect_fail "a vendored copy missing from depends fails, naming it" undeclared pkg-c depends

# 10. Akku.lock does not lock a dependency.
tree unlocked
lock "$scratch/unlocked/Akku.lock" dev-c:2.0.0 pkg-a:1.2.0
expect_fail "a dependency Akku.lock does not lock fails, naming it" unlocked pkg-c "does not lock"

# 11. Akku.lock locks a dependency at another version.
tree newer
lock "$scratch/newer/Akku.lock" dev-c:2.0.0 pkg-a:1.3.0 pkg-c:0.3.4
expect_fail "a dependency locked at another version fails, naming both" newer pkg-a 1.3.0 1.2.0

# 12. A lock entry whose name starts another's: pkg-a-extra is not pkg-a.
tree prefix
lock "$scratch/prefix/Akku.lock" dev-c:2.0.0 pkg-a-extra:1.2.0 pkg-c:0.3.4
expect_fail "a lock entry for another package is not the dependency's" prefix 'does not lock pkg-a'

# 13. A dependency named twice.
tree twice
manifest "$scratch/twice/Akku.manifest" the-server 0.7.0 pkg-a:^1.2.0 pkg-c:^0.3.4 pkg-a:^1.2.0
expect_fail "a dependency named twice in depends fails, naming it" twice 'names pkg-a twice'

# 14. No vendored copies given: nothing to hold depends to.
tree nomaps
manifest "$scratch/nomaps/Akku.manifest" the-server 0.7.0
if (cd "$scratch/nomaps" && "$CHEZ" -q --script "$script") > "$scratch/out" 2>&1; then
  fail "with no NAME=DIR given the check fails (it passed)"; cat "$scratch/out" >&2
elif grep -q 'no NAME=DIR' "$scratch/out"; then
  pass "with no NAME=DIR given the check fails, and says so"
else
  fail "with no NAME=DIR given the check fails, and says so"; cat "$scratch/out" >&2
fi

if [ "$fails" -eq 0 ]; then
  echo "check-akku-manifest: all checks passed"
else
  echo "check-akku-manifest: $fails check(s) failed" >&2
  exit 1
fi
