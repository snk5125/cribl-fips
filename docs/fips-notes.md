# FIPS notes — observed behavior (Cribl 4.18.2, image build 2026-07-21)

Everything below was verified live against this image (UBI9-minimal base,
Cribl `4.18.2-fd1f0d2f`), not paraphrased from docs.

## What works

- `cribl generateFipsConf -d /etc/pki/tls` runs headless at build time and
  emits `$CRIBL_HOME/state/nodejs.cnf` that already references
  `/etc/pki/tls/fips_local.cnf` (the `fipsmodule.cnf` → `fips_local.cnf` sed
  from Cribl's RHEL 9 knowledge-base article is a no-op on 4.18.2; we keep it
  as a guard for older outputs).
- Under that config the OpenSSL FIPS provider loads and activates:
  `Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider`, version
  **3.0.7-cda111b5812c30d4** (Red Hat's CMVP-validated module, shipped
  separately from the base's OpenSSL 3.5.5 libcrypto). This satisfies
  Cribl's >= 3.0.5 provider floor for Cribl >= 4.8.2.
- `CRIBL_DIST_MODE` is honored natively as an env var (no `mode-master`
  command needed); `CRIBL_FIPS=1` + the two OpenSSL env vars reach Cribl's
  FipsMgr as intended.

## The RBAC / license gate (the headline finding)

Cribl >= 4.7 **hard-refuses FIPS mode without RBAC**, and RBAC is a paid
license entitlement — both verified live:

- Single instance (`mode=single`):
  `FipsMgr: "FIPS not allowed in single mode process"` →
  `Error: FIPS is not available in mode=single` → server exits.
- Distributed leader (`mode=master`), free license:
  `FipsMgr: "FIPS not allowed RBAC check failed on leader"` →
  `Error: FIPS is only available when Role-based Access Control (RBAC) is
  enabled.` → server exits.
- The free license reports `limits: { rbac: 0, ... }` via
  `/api/v1/system/licenses` — RBAC (and therefore FIPS) cannot be enabled
  on it by any configuration.

**Consequence:** a FIPS-enabled Cribl Stream deployment requires (a) an
Enterprise or trial license with the RBAC entitlement and (b) distributed
mode (leader + workers). The image therefore:

- fails closed by default (FIPS on, single mode → clear remediation message),
- accepts `CRIBL_LICENSE` (written to `local/cribl/licenses.yml` before first
  start) and `CRIBL_DIST_MODE=master|worker`,
- ships a `fips` compose profile (leader + worker) gated on `CRIBL_LICENSE`.

`ci/validate.sh` asserts the two refusals plus the OpenSSL provider wiring on
every run; the full "running with FIPS enabled" positive assert runs only
when `CRIBL_LICENSE` is set (e.g. a CI secret). **The licensed positive path
has not yet been exercised — it needs a real RBAC-entitled license.**

## Password rules (verified against the users API)

Cribl's complexity rules are stricter than the docs summary: >= 8 chars and
>= 3 classes, where **uppercase does not count as the first character** and
**digits do not count as the final character** (`Validate!1` fails — V is
first, 1 is last — while `Va1idate!Pw` passes). The entrypoint mirrors these
rules and applies `CRIBL_ADMIN_PASSWORD` via the users API after boot
(Cribl 4.18.2 does not consume that env var natively; default first-boot
credentials are `admin/admin` with a forced change).

## Compliance caveats

- **Host kernel:** Red Hat's formal FIPS 140-3 posture requires the host to
  run with `fips=1` (kernel crypto self-tests, system-wide policy). This
  image activates the validated provider regardless of host state, but for a
  real compliance boundary run it on a FIPS-mode host (RHEL 9 or equivalent).
- **Provider certificate lineage:** the active module identifies itself as
  Red Hat's RHEL 9 FIPS provider (3.0.7 stream), the one covered by Red
  Hat's CMVP certificates. Record the exact certificate number for your
  package version at audit time (`rpm -q openssl-libs` in the container).
- **MD5 / CRC-32** expressions fail **silently** in FIPS mode — audit
  pipelines before deploying (the baked passthrough pipeline is clean).
- **AWS SDK v2**-based sources/destinations skip checksums in FIPS mode.
- The baked config tree applies to single/standalone mode. In distributed
  mode (the only FIPS-capable topology), worker-group config is managed by
  the leader (UI/GitOps), not by this image's baked tree.

## Base image

`registry.access.redhat.com/ubi9/ubi-minimal:9.5` pinned at digest
`sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44`.
`curl-minimal`, `openssl-libs` (with `/usr/lib64/ossl-modules/fips.so`) are in
the base; the build adds `openssl tar gzip shadow-utils findutils git`.
