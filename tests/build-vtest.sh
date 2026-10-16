#!/bin/sh
# tests/build-vtest.sh DIR COMMIT BUILD OUT — build vtest2, the black-box
# lane's client, from the submodule DIR at COMMIT, in BUILD,
# into OUT, with OUT.pin naming the commit it was built from.  A binary whose
# stamp names COMMIT already is kept.
#
# The commit's files come from DIR's git store (`git archive`), so no build
# product lands in the submodule and an edit in it is never built.  A tree
# copied without its .git (the Linux run in Docker) has no store: then DIR's
# files are built as they stand, and the script says so.  It needs a C
# compiler, pcre2 (its flags from pkg-config, where Homebrew's are found) and
# zlib, and python3 and awk, which generate two of vtest2's headers.
set -eu

[ $# -eq 4 ] || { echo "usage: $0 DIR COMMIT BUILD OUT" >&2; exit 2; }
dir=$1 commit=$2 build=$3 out=$4

if [ -x "$out" ] && [ "$(cat "$out.pin" 2>/dev/null)" = "$commit" ]; then
  echo "vtest: $out is built at $commit"
  exit 0
fi
[ -f "$dir/Makefile" ] || { echo "vtest: $dir holds no vtest2 checkout; run make submodules" >&2; exit 2; }

rm -rf "${build:?}"
mkdir -p "$build"
if git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
  git -C "$dir" archive "$commit" > "$build.tar"
  tar -x -f "$build.tar" -C "$build"
  rm -f "$build.tar"
else
  echo "vtest: $dir has no git store holding $commit; building its files as they stand" >&2
  cp -R "$dir/." "$build"
  rm -rf "${build:?}/.git"
fi

pcre_cflags=$(pkg-config --cflags libpcre2-8 2>/dev/null || true)
pcre_libs=$(pkg-config --libs-only-L libpcre2-8 2>/dev/null || true)
make -C "$build" vtest \
  INCS="-I. -Isrc -Ilib $pcre_cflags -pthread" \
  LIBS="$pcre_libs -lm -lpcre2-8 -lz -ldl"
mkdir -p "$(dirname "$out")"
cp "$build/vtest" "$out"
echo "$commit" > "$out.pin"
echo "vtest: built $out at $commit"
