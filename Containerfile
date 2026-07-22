# FIPS-mode Cribl Stream aggregator (single instance).
# Base: ubi9-patched (Containerfile.base) — UBI9-minimal + latest el9 CVE
# backports + package set, built/scanned/published on its own cadence by
# .github/workflows/base.yml, which also maintains this digest pin. It ships
# OpenSSL 3 with Red Hat's CMVP-validated FIPS provider
# (/usr/lib64/ossl-modules/fips.so), satisfying Cribl's requirement of a
# FIPS provider >= 3.0.5 (Cribl >= 4.8.2).
# Cribl is installed from the official tarball, sha256-pinned by
# ci/fetch-cribl.sh; ci/build.sh supplies CRIBL_ARCH (x64|arm64) and, for
# arm64 dev builds, overrides BASE_IMAGE with a locally-built base (the
# published pin is amd64).
ARG BASE_IMAGE=ghcr.io/snk5125/cribl-fips/ubi9-patched:2026-07-22@sha256:db8c4710d534c5748961e0b74e2e11c708d37f24e8a90257e22acd0c8566a10b

# --- unpack stage: keeps the 85MB vendor tarball blob out of the shipped
# image's layer history (tar itself is in the base — see docs/packages.md) ---
FROM ${BASE_IMAGE} AS unpack
ARG CRIBL_VERSION=4.18.2
ARG CRIBL_BUILD=fd1f0d2f
ARG CRIBL_ARCH=x64
# COPY + tar rather than ADD: ADD --chown does not apply ownership to
# extracted archive contents on the Docker versions in play (verified:
# EACCES on /opt/cribl/log), and the cribl user (1000) must own the tree.
COPY build/vendor/cribl-${CRIBL_VERSION}-${CRIBL_BUILD}-linux-${CRIBL_ARCH}.tgz /tmp/cribl.tgz
RUN tar -xzf /tmp/cribl.tgz -C /opt \
 && chown -R 1000:1000 /opt/cribl

# --- runtime stage ---
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN groupadd -g 1000 cribl \
 && useradd -u 1000 -g cribl -d /opt/cribl -M -s /sbin/nologin cribl

COPY --from=unpack --chown=1000:1000 /opt/cribl /opt/cribl

COPY --chown=cribl:cribl config/local/cribl/ /opt/cribl/local/cribl/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER cribl

# --- FIPS wiring (build-time; entrypoint regenerates if state is a fresh
# volume). generateFipsConf writes state/nodejs.cnf pointing Node's OpenSSL at
# the system FIPS provider. The sed is a no-op on 4.18.2 (it already emits
# fips_local.cnf) but kept per Cribl's RHEL 9 guidance for older outputs.
# Build gates: MODULESDIR is where we expect it, the fips provider actually
# loads under this config, and its version meets Cribl's >= 3.0.5 floor.
RUN /opt/cribl/bin/cribl generateFipsConf -d /etc/pki/tls \
 && sed -i 's/fipsmodule\.cnf/fips_local.cnf/' /opt/cribl/state/nodejs.cnf \
 && [ "$(openssl version -a | awk -F'"' '/MODULESDIR/{print $2}')" = "/usr/lib64/ossl-modules" ] \
 && OPENSSL_CONF=/opt/cribl/state/nodejs.cnf OPENSSL_MODULES=/usr/lib64/ossl-modules \
    openssl list -providers > /tmp/providers.txt \
 && grep -qi '^  fips' /tmp/providers.txt \
 && pv="$(awk '/^  fips/{f=1} f && /version:/{print $2; exit}' /tmp/providers.txt)" \
 && echo "fips provider version: $pv" \
 && [ "$(printf '3.0.5\n%s\n' "${pv%%-*}" | sort -V | head -1)" = "3.0.5" ] \
 && rm /tmp/providers.txt

ENV CRIBL_HOME=/opt/cribl \
    OPENSSL_MODULES=/usr/lib64/ossl-modules \
    OPENSSL_CONF=/opt/cribl/state/nodejs.cnf \
    CRIBL_FIPS=1

# 4200: leader<->worker comms (distributed mode, required for FIPS)
EXPOSE 9000 8080 4318 4200
HEALTHCHECK --interval=10s --timeout=5s --retries=12 --start-period=90s \
  CMD curl -fsS http://localhost:9000/api/v1/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
