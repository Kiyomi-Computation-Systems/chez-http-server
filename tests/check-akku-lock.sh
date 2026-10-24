#!/bin/sh
# tests/check-akku-lock.sh: what scripts/check-akku-lock promises, checked
# with a fake akku, so it needs no akku and no network. The fake writes the
# lock its row names; a manifest naming the package "probe" is the script's
# check that akku works at all. `make check-site-deps` runs it.
set -u
cd "$(dirname "$0")/.."
script=$PWD/scripts/check-akku-lock

scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-akku-lock-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# The fake akku. `lock` in a directory whose manifest names "probe" obeys
# FAKE_PROBE (ok, fail, nolock); any other manifest's lock is FAKE_LOCK's
# file, a failure when FAKE_LOCK is "fail", or, when it is "unknown", the
# failure of an akku whose index predates two of the manifest's packages.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/akku" <<'EOF'
#!/bin/sh
[ "$1" = lock ] || exit 2
if grep -q '"probe"' Akku.manifest; then
  case ${FAKE_PROBE:-ok} in
    ok) printf '(import (akku format lockfile))\n(projects)\n' > Akku.lock ;;
    nolock) ;;
    *) echo "fake akku: backtrace" >&2; exit 1 ;;
  esac
  exit 0
fi
[ "${FAKE_LOCK:-fail}" = fail ] && { echo "fake akku: no solution" >&2; exit 1; }
if [ "$FAKE_LOCK" = unknown ]; then
  printf '[warning] Unknown package: "chez-libuv"\n[warning] Unknown package: "chez-uri"\n' >&2
  echo '&message: "No acceptable solution - dependency hell"' >&2
  exit 1
fi
cp "$FAKE_LOCK" Akku.lock
EOF
chmod +x "$scratch/bin/akku"

echo '(akku-package ("chez-http-server" "0.7.0"))' > "$scratch/Akku.manifest"

# lock FILE NAME URL SHA [NAME URL SHA]...: a lock in `akku lock`'s layout.
lock() {
  out=$1; shift
  { echo '#!r6rs ; -*- mode: scheme; coding: utf-8 -*-'
    echo '(import (akku format lockfile))'
    echo '(projects'
    while [ "$#" -ge 3 ]; do
      printf ' ((name "%s")\n  (location\n   (url "%s"))\n  (content\n   (sha256 "%s")))\n' "$1" "$2" "$3"
      shift 3
    done
    echo ')'; } > "$out"
}

url=https://archive.akkuscm.org/archive/pkg/c/chez-cmark-gfm_2.0.0_repack.tar.xz
sha=bb647e07c03f103600ceb29d5545787bf0ba54563b1bbd98f3be7ac778305159
other=0b647e07c03f103600ceb29d5545787bf0ba54563b1bbd98f3be7ac778305159
lock "$scratch/committed.lock" chez-cmark-gfm "$url" "$sha"

# run FAKE_PROBE FAKE_LOCK [AKKU]: the script on the committed lock.
run() {
  FAKE_PROBE=$1 FAKE_LOCK=$2 AKKU=${3:-$scratch/bin/akku} \
  AKKU_MANIFEST=$scratch/Akku.manifest AKKU_LOCK=$scratch/committed.lock \
    sh "$script" > "$scratch/out" 2>&1
}

# 1. No akku: skipped, by name, with status 0.
if run ok fail "$scratch/bin/no-such-akku" && grep -q 'skipped: no .*no-such-akku' "$scratch/out"; then
  pass "with no akku the check is skipped, and says so"
else
  fail "with no akku the check is skipped, and says so"; cat "$scratch/out" >&2
fi

# 2. An akku that cannot lock a manifest with no dependencies is broken:
#    skipped, not failed, even though it would fail the real lock too.
if run fail fail && grep -q 'skipped: .*cannot lock a manifest with no dependencies' "$scratch/out"; then
  pass "an akku that fails the probe is skipped, and says so"
else
  fail "an akku that fails the probe is skipped, and says so"; cat "$scratch/out" >&2
fi

# 3. A probe that succeeds but writes no lock is a broken akku too.
if run nolock fail && grep -q 'skipped: .*cannot lock a manifest with no dependencies' "$scratch/out"; then
  pass "an akku whose probe writes no lock is skipped"
else
  fail "an akku whose probe writes no lock is skipped"; cat "$scratch/out" >&2
fi

# 4. The same lock: passes, and names how many projects agree.
if run ok "$scratch/committed.lock" && grep -q 'is akku lock.s output for .* (1 project' "$scratch/out"; then
  pass "a lock akku makes again byte for byte passes"
else
  fail "a lock akku makes again byte for byte passes"; cat "$scratch/out" >&2
fi

# 5. The same projects in another layout (every string after its key, one
#    line a project): passes.
printf '(import (akku format lockfile))\n(projects ((name "chez-cmark-gfm") (location (url "%s")) (content (sha256 "%s"))))\n' \
  "$url" "$sha" > "$scratch/oneline.lock"
if run ok "$scratch/oneline.lock" && grep -q 'is akku lock.s output' "$scratch/out"; then
  pass "a lock that differs only in layout passes"
else
  fail "a lock that differs only in layout passes"; cat "$scratch/out" >&2
fi

# 6. Another sha256: fails, and shows it.
lock "$scratch/sha.lock" chez-cmark-gfm "$url" "$other"
if ! run ok "$scratch/sha.lock" && grep -q 'FAIL' "$scratch/out" && grep -q "$other" "$scratch/out"; then
  pass "a lock with another sha256 fails, and shows it"
else
  fail "a lock with another sha256 fails, and shows it"; cat "$scratch/out" >&2
fi

# 7. Another URL: fails.
lock "$scratch/url.lock" chez-cmark-gfm "$url.old" "$sha"
if ! run ok "$scratch/url.lock" && grep -q "$url.old" "$scratch/out"; then
  pass "a lock with another url fails, and shows it"
else
  fail "a lock with another url fails, and shows it"; cat "$scratch/out" >&2
fi

# 8. A project more: fails.
lock "$scratch/more.lock" chez-cmark-gfm "$url" "$sha" zz-more "$url" "$sha"
if ! run ok "$scratch/more.lock" && grep -q 'zz-more' "$scratch/out"; then
  pass "a lock with a project more fails, and names it"
else
  fail "a lock with a project more fails, and names it"; cat "$scratch/out" >&2
fi

# 9. A project fewer: fails. The committed lock holds two this time.
lock "$scratch/two.lock" chez-cmark-gfm "$url" "$sha" zz-gone "$url" "$sha"
if ! FAKE_PROBE=ok FAKE_LOCK=$scratch/committed.lock AKKU=$scratch/bin/akku \
     AKKU_MANIFEST=$scratch/Akku.manifest AKKU_LOCK=$scratch/two.lock \
     sh "$script" > "$scratch/out" 2>&1 \
   && grep -q 'zz-gone' "$scratch/out"; then
  pass "a lock with a project fewer fails, and names it"
else
  fail "a lock with a project fewer fails, and names it"; cat "$scratch/out" >&2
fi

# 10. The same projects in another order: passes.
lock "$scratch/swapped.lock" zz-gone "$url" "$sha" chez-cmark-gfm "$url" "$sha"
if FAKE_PROBE=ok FAKE_LOCK=$scratch/swapped.lock AKKU=$scratch/bin/akku \
     AKKU_MANIFEST=$scratch/Akku.manifest AKKU_LOCK=$scratch/two.lock \
     sh "$script" > "$scratch/out" 2>&1 \
   && grep -q '(2 project' "$scratch/out"; then
  pass "a lock that differs only in the order of its projects passes"
else
  fail "a lock that differs only in the order of its projects passes"; cat "$scratch/out" >&2
fi

# 11. A working akku that cannot lock the manifest: fails, not skipped, and
# does not blame the index when akku named no package it does not know.
if ! run ok fail && grep -q 'FAIL: .*could not lock' "$scratch/out" \
   && ! grep -q 'akku update' "$scratch/out"; then
  pass "a working akku that cannot lock the manifest fails"
else
  fail "a working akku that cannot lock the manifest fails"; cat "$scratch/out" >&2
fi

# 12. An akku whose index does not know a package: fails, naming each one
# and the command that refreshes the index.
if ! run ok unknown && grep -q 'FAIL: .*chez-libuv chez-uri.*akku update' "$scratch/out"; then
  pass "an index that does not know a package fails, naming it and akku update"
else
  fail "an index that does not know a package fails, naming it and akku update"; cat "$scratch/out" >&2
fi

if [ "$fails" -eq 0 ]; then
  echo "check-akku-lock: all checks passed"
else
  echo "check-akku-lock: $fails check(s) failed" >&2
  exit 1
fi
