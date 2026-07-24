# cribl-fips

FIPS-mode **Cribl Stream** aggregator container image: Red Hat UBI9-minimal
(CMVP-validated OpenSSL FIPS provider) + the official Cribl 4.18.2 tarball
(sha256-pinned), with Cribl's FIPS mode wired in and asserted at validation
time. Cribl publishes no FIPS image — [FIPS mode](https://docs.cribl.io/stream/fips-mode/)
requires a FIPS-validated OpenSSL provider in the environment plus explicit
Cribl configuration; this image bakes both.

> **The one thing to know:** Cribl >= 4.7 refuses FIPS mode without RBAC,
> which is an Enterprise/trial license entitlement, and requires distributed
> mode (verified live — see [docs/fips-notes.md](docs/fips-notes.md)). The
> image fails closed by default with a remediation message. Actually running
> FIPS-enabled needs `CRIBL_DIST_MODE=master` + `CRIBL_LICENSE=<key>`.

## Quick start

```bash
make build         # fetch pinned tarball + docker build (host arch)
make validate      # boot + FIPS assertions (fail-closed, provider, functional)
make scan          # trivy vuln scan; gate on fixable HIGH/CRITICAL
make run           # dev profile: single instance, FIPS OFF -> localhost:9000

# FIPS-enabled stack (leader + worker; needs an RBAC-entitled license):
CRIBL_LICENSE=<key> docker compose --profile fips up -d
```

Ports: `9000` UI/API, `8080` http_raw NDJSON in, `4318` OTLP/HTTP in,
`4200` leader/worker comms.

Pull (built by CI on main/tags):

```bash
docker pull ghcr.io/snk5125/cribl-fips:latest
```

## Runtime matrix

| Env | Result (verified) |
| --- | --- |
| *(defaults: FIPS on, single)* | fails closed: remediation message, exit 1 |
| `CRIBL_DIST_MODE=master` (no license) | Cribl FipsMgr refuses: RBAC required |
| `CRIBL_DIST_MODE=master` + `CRIBL_LICENSE` | FIPS-enabled leader (needs RBAC-entitled license) |
| `CRIBL_FIPS=0` | non-FIPS standalone dev instance, fully functional |

Other env: `CRIBL_DIST_MODE=worker` + `CRIBL_DIST_MASTER_URL` (join a
leader); `CRIBL_ADMIN_PASSWORD` (applied via the users API after boot;
complexity-checked up front — >= 8 chars, >= 3 classes, uppercase not
counting the first character, digits not counting the last).

## Patched-base pipeline

The app image builds `FROM` a pre-patched base, `ubi9-patched`
([Containerfile.base](Containerfile.base)): UBI9-minimal + Red Hat's latest
el9 CVE backports + the package set. The [base workflow](.github/workflows/base.yml)
rebuilds it weekly (and on dispatch): build → trivy scan gate → publish
`ubi9-patched:<date>` → bump the digest pin in the Containerfile → rebuild,
validate, scan, and push the app against it — so CVE patching runs on Red
Hat's cadence, not yours. arm64 dev builds self-build an equivalent local
base (`make base`); the published pin is amd64.

## How FIPS is wired

- The base ships Red Hat's separately-packaged FIPS provider
  `/usr/lib64/ossl-modules/fips.so` — active version
  `3.0.7-cda111b5812c30d4`, the CMVP-validated RHEL 9 module, above Cribl's
  >= 3.0.5 floor.
- At build: `cribl generateFipsConf -d /etc/pki/tls` writes
  `$CRIBL_HOME/state/nodejs.cnf` pointing Node's OpenSSL at the fips
  provider; build gates assert the provider loads and meets the version
  floor. The entrypoint regenerates the file if `state/` is a fresh volume.
- At runtime: `CRIBL_FIPS=1`, `OPENSSL_CONF=/opt/cribl/state/nodejs.cnf`,
  `OPENSSL_MODULES=/usr/lib64/ossl-modules` (baked ENV; the entrypoint drops
  them for genuinely non-FIPS `CRIBL_FIPS=0` runs).

Verify on a running FIPS deployment:

```bash
docker exec <container> sh -c \
  'grep -i "running with FIPS enabled" /opt/cribl/log/cribl.log && openssl list -providers'
```

## Configuration

The baked config tree (`config/local/cribl/`) keeps the image dependency-free:
`http_in` (:8080, NDJSON breaker `Cribl`) and `otlp_in` (:4318) route through
a passthrough pipeline to a `devnull` output. Overlay real outputs/routes by
mounting a tree at `/opt/cribl-seed/` (entrypoint copies it onto
`/opt/cribl/local/cribl/` at boot). Note: in distributed mode — the only
FIPS-capable topology — worker-group config is managed by the leader, not by
the baked tree.

## Limitations & compliance caveats

Details and evidence in [docs/fips-notes.md](docs/fips-notes.md). Headlines:

- **Host kernel**: formal FIPS 140-3 posture requires the *host* to run with
  `fips=1`; the image activates the validated provider regardless, but the
  host is part of any real compliance boundary.
- **MD5 / CRC-32** expressions fail silently in FIPS mode (including
  `C.Mask.md5()` — a DLP pipeline masking with MD5 passes raw values
  through); AWS SDK v2-based sources/destinations skip checksums. Full
  feature-impact list: [docs/fips-feature-impact.md](docs/fips-feature-impact.md).
- The licensed FIPS-positive path (`running with FIPS enabled`) is asserted
  by `ci/validate.sh` only when `CRIBL_LICENSE` is set — it has not been
  exercised without one (the free license reports `rbac: 0`).
- **Vulnerability reporting split**: GitHub Code Scanning alerts show
  *fixable* findings only (every alert is actionable); the full inventory
  including unfixed CVEs awaiting Red Hat backports is the `trivy.json`
  artifact on every run. Accepted-risk suppressions are PR-reviewed OpenVEX
  statements in [vex/](vex/README.md), never UI dismissals.

## Layout

```
Containerfile          ubi9-patched base + cribl tarball + FIPS wiring & gates
Containerfile.base     UBI9-minimal + el9 CVE backports (weekly, digest-pinned)
docker/entrypoint.sh   fail-closed FIPS policy, license/seed/password bootstrap
config/local/cribl/    baked default config (dependency-free boot)
ci/                    fetch-cribl / build / lint / validate / scan / push
.github/workflows/     GitHub CI (thin, calls ci/*.sh)
.gitlab-ci.yml         GitLab CI (same scripts)
docs/fips-notes.md     live-verified findings: RBAC gate, password rules, caveats
docs/fips-feature-impact.md  what Cribl loses in FIPS mode (silent failures first)
docs/packages.md       per-package justification table (present AND absent)
```
