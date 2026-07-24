#!/usr/bin/env bash
# Build the cribl-fips image with OCI labels.
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

# Base image: amd64 uses the digest pin committed in the Containerfile
# (maintained by .github/workflows/base.yml); arm64 dev builds self-build an
# equivalent local base since the published pin is amd64-only. BASE_IMAGE env
# overrides either.
base_args=()
if [ -n "${BASE_IMAGE:-}" ]; then
  base_args=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
elif [ "$ARCH" = "arm64" ]; then
  BASE_IMAGE_REPO="cribl-fips/ubi9-patched-local" ARCH=arm64 ./ci/build-base.sh local
  base_args=(--build-arg "BASE_IMAGE=cribl-fips/ubi9-patched-local:local")
fi

revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
docker build -f Containerfile \
  --platform "linux/$ARCH" \
  --build-arg CRIBL_ARCH="$cribl_arch" \
  ${base_args[@]+"${base_args[@]}"} \
  --label "org.opencontainers.image.title=cribl-fips" \
  --label "org.opencontainers.image.description=FIPS-mode Cribl Stream aggregator (UBI9 + validated OpenSSL FIPS provider)" \
  --label "org.opencontainers.image.version=$version" \
  --label "org.opencontainers.image.revision=$revision" \
  --label "org.opencontainers.image.source=https://github.com/snk5125/cribl-fips" \
  --label "io.grimoire.component=cribl-fips" \
  --label "io.grimoire.cribl.version=4.18.2" \
  -t "$IMAGE:$version" -t "$IMAGE:latest" .

echo "build: $IMAGE:$version ($ARCH)"
