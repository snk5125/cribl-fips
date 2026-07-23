# FIPS mode: what Cribl no longer provides

Operator-facing list of Cribl Stream functionality that is lost, degraded,
or changed when FIPS mode is active (`CRIBL_FIPS=1`, this image's default).
Sources: [Cribl's FIPS mode docs](https://docs.cribl.io/stream/fips-mode/)
(vendor-documented) and this repo's live verification on 4.18.2 (marked
**verified**). Companion docs: [fips-notes.md](fips-notes.md) for how FIPS
is wired and proven, [packages.md](packages.md) for the package surface.

## Cryptographic functions — silent failures

The highest-risk category, because nothing errors:

- **MD5 and CRC-32 are disabled, and expressions using them fail
  *silently*** — events flow on with the expression unevaluated, not
  rejected. Audit every pipeline before deploying.
- **`C.Mask.md5()`** and any Function/Pipeline depending on it stops
  masking. A DLP pipeline that hashes PII with MD5 will pass the raw value
  through without warning — the single most dangerous failure mode here.
  (Migrate to `C.Mask.sha1()`/`sha256()` variants or non-hash masking.)
- The UI hides the affected options from typeahead in FIPS mode, but that
  only protects *new* config built through the UI — imported packs, GitOps
  config, and pre-FIPS pipelines are not rewritten or flagged.
- This image's baked passthrough pipeline is MD5/CRC-32-free (audited);
  anything overlaid via `/opt/cribl-seed/` or leader-managed worker-group
  config is the deployment's responsibility to audit.

## AWS SDK v2 integrations — checksums skipped

AWS SDK v2 uses MD5 for integrity checksums, so in FIPS mode these
sources/destinations perform **no checksum verification** (data still
flows; corruption detection is lost):

| Type | Affected |
| --- | --- |
| Source | Amazon Kinesis Data Streams ("Verify KPL checksums" unavailable) |
| Destination | Amazon CloudWatch Logs, Amazon Kinesis Data Streams, Amazon SQS, Google Cloud Storage, MinIO, Prometheus |
| Notification target | Amazon SNS (no checksums) |

Transport-level TLS integrity still applies; what's lost is the
application-level payload checksum.

## Deployment & topology restrictions (**verified live**)

- **Single-instance mode cannot run FIPS at all** — Cribl >= 4.7 exits with
  `FIPS is not available in mode=single`. Distributed (leader + workers) is
  the only FIPS-capable topology.
- **RBAC is mandatory**, which is an Enterprise/trial license entitlement
  (the free license reports `rbac: 0`). No license with RBAC ⇒ no FIPS.
- **FIPS silently turns itself off if RBAC is later disabled** (vendor-
  documented: "Cribl Stream will automatically disable FIPS mode") — a
  compliance regression with no hard failure. Monitor for the absence of
  "running with FIPS enabled" after any auth/license change; this image's
  `ci/validate.sh` positive assert is the template.

## Authentication changes (**verified live**)

- Password policy tightens for all users: >= 8 characters and >= 3
  character classes, where **uppercase does not count as the first
  character** and **digits do not count as the last character**
  (`Validate!1` fails; `Va1idate!Pw` passes). The entrypoint enforces the
  same rules on `CRIBL_ADMIN_PASSWORD` up front.

## Crypto surface generally

- Only FIPS-approved algorithms are available to the runtime (the Node
  OpenSSL layer runs against the FIPS provider with
  `default_properties = fips=yes`) — anything downstream that requests a
  non-approved algorithm fails at the crypto layer. The MD5/CRC-32 items
  above are the documented Cribl-visible cases; treat unexplained crypto
  errors in sources/destinations with exotic TLS settings as suspects.

## What is NOT lost

Worth stating to prevent over-scoping: ingestion protocols (HTTP, OTLP,
TCP, ...), routing, non-hash Functions, S3 destinations on AWS SDK v3,
SHA-family hashing, and TLS with FIPS-approved ciphers all work normally.
FIPS mode restricts *cryptography*, not the pipeline engine.
