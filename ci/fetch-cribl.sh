#!/usr/bin/env bash
# Resolve the pinned Cribl Stream tarball into build/vendor/.
# Order: sibling config-parser vendor cache (local dev) -> Cribl CDN (CI).
# Always sha256-verified against the pin; a mismatch is a hard failure.
# Usage: fetch-cribl.sh [amd64|arm64]   (default: amd64, the CI/prod arch)
set -euo pipefail

CRIBL_VERSION="${CRIBL_VERSION:-4.18.2}"
CRIBL_BUILD="${CRIBL_BUILD:-fd1f0d2f}"
# Per-arch pins for the same version+build. x64 pin matches the sibling
# config-parser vendor cache; arm64 pinned from the official CDN (TLS).
SHA256_AMD64="e9b37388fbdcfb2217ec9c9569e42d22133b3449c3b2cf8f64da72b9cf23255f"
SHA256_ARM64="e2b126bb819c9a286f84535f0d5d6a61df74dec1b4404516962500c194cb5518"

arch="${1:-amd64}"
case "$arch" in
  amd64) cribl_arch="x64"   want="$SHA256_AMD64" ;;
  arm64) cribl_arch="arm64" want="$SHA256_ARM64" ;;
  *) echo "fetch-cribl: unknown arch '$arch' (want amd64|arm64)" >&2; exit 2 ;;
esac

tarball="cribl-${CRIBL_VERSION}-${CRIBL_BUILD}-linux-${cribl_arch}.tgz"
url="https://cdn.cribl.io/dl/${CRIBL_VERSION}/${tarball}"

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/build/vendor/$tarball"
cache="$here/../config-parser/build/vendor-cache/$tarball"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi | awk '{print $1}'
}

verify() { # verify <file> -> 0 if pinned hash matches
  [ "$(sha256_of "$1")" = "$want" ]
}

mkdir -p "$(dirname "$dest")"

if [ -f "$dest" ] && verify "$dest"; then
  echo "fetch-cribl: $tarball already present (sha256 OK)"
  exit 0
fi

if [ -f "$cache" ]; then
  echo "fetch-cribl: copying from sibling vendor cache"
  cp "$cache" "$dest"
else
  echo "fetch-cribl: downloading $url"
  curl -fsSL --retry 3 -o "$dest" "$url"
fi

if ! verify "$dest"; then
  echo "fetch-cribl: SHA256 MISMATCH for $tarball" >&2
  echo "  want: $want" >&2
  echo "  got:  $(sha256_of "$dest")" >&2
  rm -f "$dest"
  exit 1
fi
echo "fetch-cribl: $tarball ready (sha256 OK)"
