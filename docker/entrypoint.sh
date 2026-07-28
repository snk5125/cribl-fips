#!/usr/bin/env bash
# Entrypoint for the FIPS-mode Cribl Stream aggregator image.
# Idempotent: safe across restarts and with /opt/cribl volumes mounted.
#
# Roles via CRIBL_DIST_MODE (native Cribl env var, passed through):
#   single (default) — standalone; Cribl REFUSES FIPS in this mode (>=4.7)
#   master           — distributed leader; FIPS requires RBAC, which requires
#                      an Enterprise/trial license (CRIBL_LICENSE)
#   worker           — distributed worker; also set CRIBL_DIST_MASTER_URL
set -euo pipefail

CRIBL_HOME="${CRIBL_HOME:-/opt/cribl}"
mode="${CRIBL_DIST_MODE:-single}"
licenses_yml="$CRIBL_HOME/local/cribl/licenses.yml"

if [ "${CRIBL_FIPS:-1}" = "1" ]; then
  # Fail closed with a clear remedy: Cribl >=4.7 hard-refuses FIPS in
  # single-instance mode ("FIPS is not available in mode=single").
  if [ "$mode" = "single" ]; then
    cat >&2 <<'EOF'
ERROR: Cribl Stream (>= 4.7) refuses FIPS mode in a single-instance node,
and requires RBAC — an Enterprise/trial license entitlement.

Either run a FIPS-capable distributed node:
    -e CRIBL_DIST_MODE=master -e CRIBL_LICENSE=<enterprise-license-key>
  (workers: -e CRIBL_DIST_MODE=worker -e CRIBL_DIST_MASTER_URL=...)

or explicitly opt out of FIPS for a standalone dev instance:
    -e CRIBL_FIPS=0
EOF
    exit 1
  fi
  # State may be a fresh volume mount — regenerate the Node OpenSSL config
  # that points at the system FIPS provider (same steps as the build).
  if [ ! -f "$CRIBL_HOME/state/nodejs.cnf" ]; then
    "$CRIBL_HOME/bin/cribl" generateFipsConf -d /etc/pki/tls
    sed -i 's/fipsmodule\.cnf/fips_local.cnf/' "$CRIBL_HOME/state/nodejs.cnf"
  fi
  echo "== FIPS mode requested; OpenSSL providers:"
  openssl list -providers || true
  if [ "$mode" = "master" ] && [ -z "${CRIBL_LICENSE:-}" ] && [ ! -f "$licenses_yml" ]; then
    echo "WARN: no license found (CRIBL_LICENSE unset, no $licenses_yml)." >&2
    echo "WARN: Cribl will refuse FIPS on a leader without an RBAC-entitled (Enterprise) license." >&2
  fi
else
  # Genuinely non-FIPS run (the negative validation check depends on this):
  # drop the image-wide FIPS OpenSSL config along with the Cribl flag.
  unset OPENSSL_CONF CRIBL_FIPS
  echo "== FIPS mode disabled (CRIBL_FIPS != 1)"
fi

# Apply a license before first start (required for FIPS: RBAC entitlement).
if [ -n "${CRIBL_LICENSE:-}" ] && [ ! -f "$licenses_yml" ]; then
  echo "== writing license to local/cribl/licenses.yml"
  mkdir -p "$(dirname "$licenses_yml")"
  printf 'licenses:\n  - %s\n' "$CRIBL_LICENSE" > "$licenses_yml"
fi

# --- deployment config overlays, least- to most-specific -------------------
# 1. baked defaults (image)  2. remote fetch (git or https tarball)
# 3. /opt/cribl-seed mount   — later layers win. Fetch failures abort boot
# (fail closed: never run with half-applied config).
#
#   CRIBL_CONFIG_GIT_URL   git remote holding the config tree (https or ssh;
#                          git-core + openssh-clients are in the image)
#   CRIBL_CONFIG_GIT_REF   optional branch/tag for the clone
#   CRIBL_CONFIG_URL       .tgz over https — presigned S3 URLs work
#   CRIBL_CONFIG_SHA256    optional integrity pin for the tarball
#   CRIBL_CONFIG_PATH      subdir inside the repo/tarball that holds the
#                          local/cribl tree (default: root)
if [ -n "${CRIBL_CONFIG_GIT_URL:-}" ] && [ -n "${CRIBL_CONFIG_URL:-}" ]; then
  echo "ERROR: set only one of CRIBL_CONFIG_GIT_URL / CRIBL_CONFIG_URL" >&2
  exit 1
fi
fetch_dir=""
if [ -n "${CRIBL_CONFIG_GIT_URL:-}" ]; then
  echo "== fetching config from git: $CRIBL_CONFIG_GIT_URL (${CRIBL_CONFIG_GIT_REF:-default branch})"
  fetch_dir="$(mktemp -d)"
  git clone --quiet --depth 1 \
    ${CRIBL_CONFIG_GIT_REF:+--branch "$CRIBL_CONFIG_GIT_REF"} \
    "$CRIBL_CONFIG_GIT_URL" "$fetch_dir/src"
elif [ -n "${CRIBL_CONFIG_URL:-}" ]; then
  echo "== fetching config tarball: $CRIBL_CONFIG_URL"
  fetch_dir="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$fetch_dir/config.tgz" "$CRIBL_CONFIG_URL"
  if [ -n "${CRIBL_CONFIG_SHA256:-}" ]; then
    echo "$CRIBL_CONFIG_SHA256  $fetch_dir/config.tgz" | sha256sum -c --quiet \
      || { echo "ERROR: CRIBL_CONFIG_URL tarball failed sha256 pin" >&2; exit 1; }
  fi
  mkdir -p "$fetch_dir/src"
  tar -xzf "$fetch_dir/config.tgz" -C "$fetch_dir/src"
fi
if [ -n "$fetch_dir" ]; then
  src="$fetch_dir/src/${CRIBL_CONFIG_PATH:-.}"
  if [ ! -d "$src" ]; then
    echo "ERROR: CRIBL_CONFIG_PATH '$CRIBL_CONFIG_PATH' not found in fetched config" >&2
    exit 1
  fi
  echo "== overlaying fetched config onto local/cribl/"
  mkdir -p "$CRIBL_HOME/local/cribl"
  cp -r "$src/." "$CRIBL_HOME/local/cribl/"
  rm -rf "$fetch_dir"
  # keep the fetched .git out of cribl's own config-versioning repo
  rm -rf "$CRIBL_HOME/local/cribl/.git"
fi

# Overlay deployment config (real outputs/routes) over the baked defaults.
if [ -d /opt/cribl-seed ] && [ -n "$(ls -A /opt/cribl-seed 2>/dev/null)" ]; then
  echo "== seeding config from /opt/cribl-seed/"
  mkdir -p "$CRIBL_HOME/local/cribl"
  cp -r /opt/cribl-seed/. "$CRIBL_HOME/local/cribl/"
fi

# Admin password from env. Cribl 4.18.2 does NOT consume CRIBL_ADMIN_PASSWORD
# natively (verified: default admin/admin still active) — so: complexity-check
# it up front (FIPS enforces >= 8 chars / >= 3 character classes; fail fast
# with a readable message), then a background bootstrap applies it via the
# users API once the server is up. Idempotent: if admin/admin no longer works
# (password already set, persisted state), the bootstrap quietly gives up.
if [ -n "${CRIBL_ADMIN_PASSWORD:-}" ]; then
  p="$CRIBL_ADMIN_PASSWORD"
  # Cribl's actual rules (verified against the 4.18.2 users API): uppercase
  # does NOT count as the first character, digits do NOT count as the final
  # character.
  classes=0
  case "$p" in *[a-z]*) classes=$((classes+1));; esac
  case "${p#?}" in *[A-Z]*) classes=$((classes+1));; esac
  case "${p%?}" in *[0-9]*) classes=$((classes+1));; esac
  case "$p" in *[!a-zA-Z0-9]*) classes=$((classes+1));; esac
  if [ "${#p}" -lt 8 ] || [ "$classes" -lt 3 ]; then
    echo "ERROR: CRIBL_ADMIN_PASSWORD does not meet Cribl password complexity:" >&2
    echo "  >= 8 chars and >= 3 of: lowercase, uppercase (not counting the" >&2
    echo "  first character), digit (not counting the last character), symbol" >&2
    exit 1
  fi
  (
    esc=$(printf '%s' "$p" | sed 's/\\/\\\\/g; s/"/\\"/g')
    for _ in $(seq 1 60); do
      sleep 5
      tok=$(curl -fsS -XPOST http://localhost:9000/api/v1/auth/login \
              -H 'Content-Type: application/json' \
              -d '{"username":"admin","password":"admin"}' 2>/dev/null \
            | sed -E 's/.*"token":"([^"]+)".*/\1/') || continue
      [ -n "$tok" ] || continue
      if printf '{"id":"admin","username":"admin","first":"admin","last":"admin","email":"admin","roles":["admin"],"password":"%s"}' "$esc" \
         | curl -fsS -XPATCH http://localhost:9000/api/v1/system/users/admin \
             -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
             -d @- >/dev/null 2>&1; then
        echo "== admin password set from CRIBL_ADMIN_PASSWORD"
        exit 0
      fi
    done
  ) &
fi

exec "$CRIBL_HOME/bin/cribl" server
