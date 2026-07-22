# Package justifications

Every package in the runtime image exists for a documented reason — and so
does every package deliberately left out. Modeled on DISA container-hardening
practice (and Cribl's Iron Bank justifications file, which several vendor-side
entries below trust). Keep this file in sync with `Containerfile.base`.

## Explicitly installed (Containerfile.base)

| Package | Justification |
| --- | --- |
| `openssl` | CLI used by the build gates and `ci/validate.sh` to assert the FIPS provider loads, its version, and MODULESDIR; `openssl-libs` hosts the runtime crypto for everything in the image. |
| `shadow-utils` | `groupadd`/`useradd` create the unprivileged `cribl` user (uid/gid 1000) at build time. |
| `findutils` | Cribl's runtime scripts use `find`. |
| `git-core` | Cribl Stream config versioning on the leader (local repository). `git-core` rather than `git` drops the perl-Git stack; installed with `--setopt=install_weak_deps=0`. |
| `tar`, `gzip` | Cribl pack management downloads and extracts pack bundles at runtime — per Cribl's own vendor guidance (Iron Bank justifications). Carries tar's currently-unfixed CVEs in the full inventory; accepted as a functional requirement. `gzip` is additionally a hard dep of `cracklib` (pam chain). |

## Inherited from the base / hard dependencies (notable)

| Package | Justification |
| --- | --- |
| `openssl-fips-provider-so` | Red Hat's frozen, CMVP-validated OpenSSL FIPS module (`fips.so`) — the cryptographic heart of the image. Exact build pinned and certificate-traced; see [fips-notes.md](fips-notes.md), "Provider certificate lineage". |
| `openssh-clients` | Hard `Requires:` of `git-core` in el9 (verified — not a weak dep). Unused by the default config; only exercised if a deployment configures git-over-SSH remotes (GitOps). |
| `curl-minimal` / `libcurl-minimal` | In the UBI9-minimal base. Used by the image HEALTHCHECK and the entrypoint's admin-password bootstrap against the local API. |
| `bash` | In the base. The entrypoint is a bash script. |
| `ca-certificates` | In the base. Cribl makes outbound TLS connections to user-configured destinations (S3, OTLP, syslog-TLS, ...); certificate validation needs the system CA bundle. |
| `libstdc++` | Runtime dependency of the Node.js binary bundled inside the Cribl tarball. |
| `libcap` | Transitive base dependency. No capabilities are granted to the image; all default listen ports are above 1024. |
| `glib2`, `libacl`, `cracklib`, ... | Representative transitive base dependencies. Not used directly; patched weekly by the base refresh pipeline — which is why this image needed none of the "no fix available" CVE exceptions the Iron Bank equivalent documents. |

## Deliberately absent

| Package | Why not |
| --- | --- |
| `git` (full) + perl-Git stack | Config versioning needs only the `git` binary from `git-core`; the perl stack roughly doubled the git-related CVE surface. |
| `iproute` | Operator diagnostics only. Debugging belongs in an ephemeral sidecar/debug container, not the shipped runtime surface. |
| `jq` | Our entrypoint parses nothing that needs it (the Iron Bank entrypoint's jq usage doesn't apply here). |
| `procps-ng`, editors, etc. | Nothing in the image or entrypoint requires them; UBI9-minimal's default omission is preserved. |

## Change discipline

Adding a package = adding CVE surface an assessor will ask about. Any change
to the install line in `Containerfile.base` must update this table in the
same commit, with the runtime reason (not "convenient for debugging") stated.
