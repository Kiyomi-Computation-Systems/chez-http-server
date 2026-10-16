#!/bin/sh
# tests/fetch-oha.sh OUT — fetch oha, the load smoke's client, into OUT: the
# release binary of the version pinned below, for this machine, from oha's
# GitHub release, kept only if its sha256 is the one pinned beside it.  A
# binary already at OUT with that sha256 is kept.
#
# Pinned for macOS and Linux, amd64 and arm64, the platforms oha's release
# and the clients suite share; elsewhere OHA names an oha for the suite.
# Each sum matches the sha256 GitHub records for its asset.  It needs curl,
# and sha256sum or shasum (tests/sha256.sh).
set -eu

[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
out=$1
here=$(cd "$(dirname "$0")" && pwd)

version=v1.16.0
case "$(uname -s) $(uname -m)" in
  "Darwin arm64")
    asset=oha-macos-arm64 sum=7dea53ecb8342a7a067e1976fd0aef44ac33d9cc6b1e65c53637ffb932da63c4 ;;
  "Darwin x86_64")
    asset=oha-macos-amd64 sum=5ecbfc5233e3f1d30384e142a9a8dd7ebf9d3298ab22476fabac44a8f2117e08 ;;
  "Linux x86_64")
    asset=oha-linux-amd64 sum=620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716 ;;
  "Linux aarch64" | "Linux arm64")
    asset=oha-linux-arm64 sum=99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39 ;;
  *)
    echo "oha: no oha $version is pinned for $(uname -s) $(uname -m); set OHA to an oha" >&2
    exit 2 ;;
esac

sha() { sh "$here/sha256.sh" "$1"; }

if [ -f "$out" ] && [ -x "$out" ] && [ "$(sha "$out" 2>/dev/null)" = "$sum" ]; then
  echo "oha: $out is $asset $version"
  exit 0
fi

# A sum tool, before anything is fetched: tests/sha256.sh names the one missing.
sha "$0" > /dev/null

# A file of this fetch's own beside OUT, so a fetch running at the same time
# never writes into it, and the move into OUT is one rename.
dir=$(dirname "$out")
mkdir -p "$dir"
part=$(mktemp "$dir/.oha.XXXXXX")
trap 'rm -f "$part"' EXIT
curl -fsSL --retry 3 -o "$part" "https://github.com/hatoo/oha/releases/download/$version/$asset"
got=$(sha "$part")
if [ "$got" != "$sum" ]; then
  echo "oha: $asset $version has sha256 $got, not the pinned $sum; refused" >&2
  exit 2
fi
chmod +x "$part"
mv -f "$part" "$out"
echo "oha: fetched $out, $asset $version"
