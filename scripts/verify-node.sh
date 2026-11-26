#!/usr/bin/env bash
# Verify a Node.js release's SHASUMS256.txt against the Node release keys
# (keys/nodejs-release-keys.kbx, from github.com/nodejs/release-keys
# gpg-only-active-keys) and print the sha256 of its source tarball.
#
# Usage: scripts/verify-node.sh <version>     e.g. 24.22.3
set -euo pipefail
. "$(dirname "$0")/lib.sh"

version="$1"
dir="$WORK/node-verify/$version"
mkdir -p "$dir"
base="https://nodejs.org/dist/v$version"
curl -fsSL --retry 3 "$base/SHASUMS256.txt" -o "$dir/SHASUMS256.txt"
curl -fsSL --retry 3 "$base/SHASUMS256.txt.sig" -o "$dir/SHASUMS256.txt.sig"
if ! gpgv --keyring "$ROOT/keys/nodejs-release-keys.kbx" "$dir/SHASUMS256.txt.sig" "$dir/SHASUMS256.txt" 2> "$dir/gpgv.log"; then
  cat "$dir/gpgv.log" >&2
  die "Node $version: SHASUMS256.txt signature does not verify against keys/nodejs-release-keys.kbx"
fi
grep -q 'Good signature' "$dir/gpgv.log" || die "Node $version: gpgv reported no good signature"
sha="$(awk -v f="node-v$version.tar.xz" '$2==f{print $1}' "$dir/SHASUMS256.txt")"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "Node $version: node-v$version.tar.xz missing from SHASUMS256.txt"
echo "$sha"
