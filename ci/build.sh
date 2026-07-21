#!/usr/bin/env bash
# Build the aggregator-fips image with OCI labels.
# Usage: build.sh [version]        (default: sha-<short-sha>)
# Env:   IMAGE (registry/name), ARCH (amd64|arm64, default amd64)
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/snk5125/cribl-fips}"
ARCH="${ARCH:-amd64}"
version="${1:-sha-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"

case "$ARCH" in
  amd64) cribl_arch="x64" ;;
  arm64) cribl_arch="arm64" ;;
  *) echo "build: unknown ARCH '$ARCH' (want amd64|arm64)" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

./ci/fetch-cribl.sh "$ARCH"

revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
docker build -f Containerfile \
  --platform "linux/$ARCH" \
  --build-arg CRIBL_ARCH="$cribl_arch" \
  --label "org.opencontainers.image.title=aggregator-fips" \
  --label "org.opencontainers.image.description=FIPS-mode Cribl Stream aggregator (UBI9 + validated OpenSSL FIPS provider)" \
  --label "org.opencontainers.image.version=$version" \
  --label "org.opencontainers.image.revision=$revision" \
  --label "org.opencontainers.image.source=https://github.com/snk5125/cribl-fips" \
  --label "io.grimoire.component=aggregator-fips" \
  --label "io.grimoire.cribl.version=4.18.2" \
  -t "$IMAGE:$version" -t "$IMAGE:latest" .

echo "build: $IMAGE:$version ($ARCH)"
