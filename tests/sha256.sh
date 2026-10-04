#!/bin/sh
# tests/sha256.sh FILE — FILE's sha256, in hex, on standard output: from
# sha256sum (GNU coreutils) or `shasum -a 256` (Perl's, on macOS).  With
# neither on PATH it says so and exits 2, so no caller reads an empty sum as
# a sum that does not match.  The one sha256 of the corpus vendoring
# (tests/vendor-corpus.sh, the Makefile's corpus-refresh) and of oha's fetch
# (tests/fetch-oha.sh).
set -eu

[ $# -eq 1 ] || { echo "usage: $0 FILE" >&2; exit 2; }

if command -v sha256sum >/dev/null 2>&1; then
  line=$(sha256sum "$1")
elif command -v shasum >/dev/null 2>&1; then
  line=$(shasum -a 256 "$1")
else
  echo "sha256: neither sha256sum nor shasum is on PATH" >&2
  exit 2
fi
echo "${line%% *}"
