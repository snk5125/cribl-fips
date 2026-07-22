# FIPS-mode Cribl Stream aggregator (single instance).
# Base: UBI9-minimal — ships OpenSSL 3 with Red Hat's CMVP-validated FIPS
# provider (/usr/lib64/ossl-modules/fips.so), satisfying Cribl's requirement
# of a FIPS provider >= 3.0.5 (Cribl >= 4.8.2).
# Cribl is installed from the official tarball, sha256-pinned by
# ci/fetch-cribl.sh; ci/build.sh supplies CRIBL_ARCH (x64|arm64).
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44

ARG CRIBL_VERSION=4.18.2
ARG CRIBL_BUILD=fd1f0d2f
ARG CRIBL_ARCH=x64

# openssl: CLI for provider asserts; tar/gzip: extract; shadow-utils: user
# mgmt; findutils: cribl scripts; git: Stream config versioning.
# (curl-minimal is already in the base — the HEALTHCHECK relies on it.)
# upgrade first: the digest-pinned base lags Red Hat's CVE backports
# (verified by trivy: libxml2/sqlite-libs HIGHs fixed in newer el9 builds)
RUN microdnf upgrade -y \
 && microdnf install -y openssl tar gzip shadow-utils findutils git \
 && microdnf clean all \
 && command -v curl

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN groupadd -g 1000 cribl \
 && useradd -u 1000 -g cribl -d /opt/cribl -M -s /sbin/nologin cribl

# COPY + tar rather than ADD: ADD --chown does not apply ownership to
# extracted archive contents on the Docker versions in play (verified:
# EACCES on /opt/cribl/log), and the cribl user must own the tree.
COPY build/vendor/cribl-${CRIBL_VERSION}-${CRIBL_BUILD}-linux-${CRIBL_ARCH}.tgz /tmp/cribl.tgz
RUN tar -xzf /tmp/cribl.tgz -C /opt \
 && rm /tmp/cribl.tgz \
 && chown -R cribl:cribl /opt/cribl

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
