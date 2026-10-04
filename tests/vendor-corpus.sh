#!/bin/sh
# vendor-corpus.sh NAME ROOT -- vendor a corpus from ROOT, a git checkout at
# the commit wanted, into test/vendor/NAME (decision 0007): upstream's bytes,
# verbatim, with a PROVENANCE that records where they came from and a sha256
# per file. `make corpus-refresh` runs it, and the first vendor ran it too, so
# a refresh cannot drift from how the first copy was made. Nothing of ROOT is
# committed. libhtp keeps the Makefile's own recipe (M1.3).
set -eu
LC_ALL=C
export LC_ALL

name="${1:?usage: vendor-corpus.sh NAME ROOT}"
root="${2:?usage: vendor-corpus.sh NAME ROOT}"

case "$name" in
  http-desync-guardian)
    what="AWS http-desync-guardian test-case corpus"
    url=https://github.com/aws/http-desync-guardian ref=main
    var=GUARDIAN_ROOT license="Apache-2.0 (LICENSE and NOTICE beside this file)"
    suite=tests/test-robustness-lane.sps
    files="LICENSE NOTICE tests/README.md tests/*.yaml" ;;
  *)
    echo "vendor-corpus.sh: no corpus named '$name'" >&2
    exit 2 ;;
esac

test -d "$root/.git" || { echo "vendor-corpus.sh: $root is not a git checkout" >&2; exit 2; }
commit=$(git -C "$root" rev-parse HEAD)
dst="test/vendor/$name"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

rm -rf "${dst:?}"
mkdir -p "$dst"
# The globs expand inside the checkout, in C order.
listed=$(cd "$root" && ls -1d $files)
for f in $listed; do
  mkdir -p "$dst/$(dirname "$f")"
  cp "$root/$f" "$dst/$f"
done
printf '%s\n' \
  '# Vendored corpus: exact upstream bytes, verified by sha256 (decision 0007).' \
  '# Never normalize line endings, or the checksums break on a fresh checkout.' \
  '* -text' > "$dst/.gitattributes"
count=$(printf '%s\n' $listed | wc -l | tr -d ' ')
{
  echo "# PROVENANCE -- the vendored $what (decision 0007)."
  echo "#"
  echo "# Upstream's bytes, verbatim and never hand-edited: a case we believe is"
  echo "# wrong becomes an expectation and a decision record, never a change to these"
  echo "# bytes. Every file is checksummed below and verified by $suite"
  echo "# on every run, so drift or corruption is a status-3 failure, not a discovery."
  echo "# Rewritten only by 'make corpus-refresh $var=<checkout>'."
  echo "#"
  echo "# $name is $license. This is test data; it is"
  echo "# not part of the distributed library."
  echo "upstream-url: $url"
  echo "upstream-ref: $ref"
  echo "upstream-commit: $commit"
  echo "retrieved: $(date -u +%Y-%m-%d)"
  echo "file-count: $count"
  echo ""
  for f in $listed; do echo "sha256 $(sha "$dst/$f") $f"; done
} > "$dst/PROVENANCE"
echo "vendor-corpus.sh: vendored $count files of $name at $commit into $dst"
