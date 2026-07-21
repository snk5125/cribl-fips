#!/usr/bin/env bash
# Boot-and-assert validator for the FIPS Cribl Stream aggregator image.
# (Boot + health-probe + log-scrape pattern from config-parser/ci/validate-cribl.sh —
# no offline Cribl validator exists.)
#
# Cribl >= 4.7 refuses FIPS without RBAC (an Enterprise-license entitlement,
# verified live: the free license reports rbac:0), so validation is split:
#
#   Always (no license needed):
#     1. fail-closed: default run (single + FIPS) exits with our remediation
#        message; leader + FIPS without a license is refused by Cribl's
#        FipsMgr RBAC check — proving the FIPS wiring reaches Cribl.
#     2. OpenSSL: image-level fips provider active, version >= 3.0.5.
#     3. functional: CRIBL_FIPS=0 single instance is healthy, uid 1000,
#        config accepted (schema grep), NDJSON ingest works, admin password
#        bootstrap applies, and NO "running with FIPS enabled" appears
#        (keeps the positive FIPS assert non-vacuous).
#   With CRIBL_LICENSE set (RBAC-entitled Enterprise/trial license):
#     4. full positive: leader boots FIPS-enabled — health OK and
#        "running with FIPS enabled" in cribl.log.
#
# Usage: validate.sh <image:tag>
set -euo pipefail

image="${1:?usage: validate.sh <image:tag>}"
BOOT_WAIT="${BOOT_WAIT:-150}"
rc=0

c1="aggfips-val-fc-$$"    # fail-closed single
c2="aggfips-val-rbac-$$"  # fail-closed leader (RBAC refusal)
c3="aggfips-val-fn-$$"    # functional non-FIPS
c4="aggfips-val-fips-$$"  # licensed positive
cleanup() { docker rm -f "$c1" "$c2" "$c3" "$c4" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; rc=1; }

wait_health() { # wait_health <container> <max-seconds>
  local c="$1" max="$2" t=0
  while true; do
    docker exec "$c" curl -fsS http://localhost:9000/api/v1/health >/dev/null 2>&1 && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || return 1
    t=$((t + 3)); [ "$t" -ge "$max" ] && return 1
    sleep 3
  done
}

wait_exit() { # wait_exit <container> <max-seconds>
  local c="$1" max="$2" t=0
  while [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; do
    t=$((t + 2)); [ "$t" -ge "$max" ] && return 1
    sleep 2
  done
  return 0
}

echo "== 1a. fail-closed: default run (single + FIPS) must refuse with remediation"
docker rm -f "$c1" >/dev/null 2>&1 || true
docker run -d --name "$c1" "$image" >/dev/null
if ! wait_exit "$c1" 60; then
  fail "single+FIPS run did not exit (expected fail-closed refusal)"
else
  # capture logs first: `docker logs | grep -q` + pipefail = SIGPIPE race
  logs="$(docker logs "$c1" 2>&1)"
  if ! grep -q "refuses FIPS mode in a single-instance" <<<"$logs"; then
    fail "single+FIPS refusal message missing — logs:"
    tail -10 <<<"$logs" >&2
  else
    echo "   OK: refused with remediation message"
  fi
fi

echo "== 1b. fail-closed: leader + FIPS without license hits Cribl's RBAC gate"
docker rm -f "$c2" >/dev/null 2>&1 || true
docker run -d --name "$c2" -e CRIBL_DIST_MODE=master "$image" >/dev/null
if ! wait_exit "$c2" 90; then
  fail "leader+FIPS (no license) did not exit (expected RBAC refusal)"
else
  logs="$(docker logs "$c2" 2>&1)"
  if ! grep -q "Role-based Access Control (RBAC) is enabled" <<<"$logs"; then
    fail "expected FipsMgr RBAC refusal not found — logs:"
    tail -10 <<<"$logs" >&2
  else
    echo "   OK: Cribl FipsMgr enforced RBAC requirement (FIPS wiring reaches Cribl)"
  fi
fi

echo "== 3. functional: CRIBL_FIPS=0 single instance"
docker rm -f "$c3" >/dev/null 2>&1 || true
docker run -d --name "$c3" -e CRIBL_FIPS=0 -e CRIBL_ADMIN_PASSWORD='Va1idate!Pw' "$image" >/dev/null
if ! wait_health "$c3" "$BOOT_WAIT"; then
  fail "health probe (non-FIPS single) — last 40 log lines:"
  docker logs "$c3" 2>&1 | tail -40 >&2
else
  # --- 2. OpenSSL provider (exec env carries the image's OPENSSL_CONF) ---
  pv="$(docker exec "$c3" sh -c \
        "openssl list -providers 2>/dev/null | grep -A2 '^  fips' | awk '/version:/ {print \$2}'" || true)"
  if [ -z "$pv" ]; then
    fail "openssl fips provider not active at image level"
  elif [ "$(printf '3.0.5\n%s\n' "${pv%%-*}" | sort -V | head -1)" != "3.0.5" ]; then
    fail "fips provider version $pv < 3.0.5 (Cribl minimum)"
  else
    echo "   OK: fips provider $pv"
  fi
  docker exec "$c3" sh -c 'test -f /opt/cribl/state/nodejs.cnf && grep -q fips_local.cnf /opt/cribl/state/nodejs.cnf' \
    || fail "state/nodejs.cnf missing or not referencing fips_local.cnf"
  # --- non-root ---
  [ "$(docker exec "$c3" id -u)" = "1000" ] || fail "container not running as uid 1000"
  # --- config schema rejections (signature grep from validate-cribl.sh) ---
  if docker exec "$c3" sh -c \
      'grep -hE "should (be|have)|rulesets need creating|invalid config" /opt/cribl/log/cribl.log /opt/cribl/log/worker/*/cribl.log 2>/dev/null' \
      | grep -q .; then
    fail "config schema rejections:"
    docker exec "$c3" sh -c \
      'grep -hE "should (be|have)|rulesets need creating|invalid config" /opt/cribl/log/cribl.log /opt/cribl/log/worker/*/cribl.log 2>/dev/null | head -10' >&2
  fi
  # --- ingest smoke: http_raw accepts NDJSON (inputs live on worker
  #     processes, which start after the API is healthy — poll) ---
  ingest_ok=0
  for _ in $(seq 1 20); do
    if docker exec "$c3" curl -fsS -XPOST http://localhost:8080 -d '{"smoke":"test"}' >/dev/null 2>&1; then
      ingest_ok=1; break
    fi
    sleep 3
  done
  [ "$ingest_ok" = "1" ] || fail "http_raw ingest smoke test on :8080"
  # --- negative FIPS: must NOT log FIPS-enabled ---
  if docker exec "$c3" sh -c \
      'grep -hi "running with FIPS enabled" /opt/cribl/log/cribl.log 2>/dev/null' | grep -q .; then
    fail "CRIBL_FIPS=0 run logs 'running with FIPS enabled' — FIPS assert would be vacuous"
  fi
  # --- admin password bootstrap (entrypoint background job; allow it time) ---
  pw_ok=0
  for _ in $(seq 1 24); do
    if docker exec "$c3" curl -fsS -XPOST http://localhost:9000/api/v1/auth/login \
         -H 'Content-Type: application/json' \
         -d '{"username":"admin","password":"Va1idate!Pw"}' >/dev/null 2>&1; then
      pw_ok=1; break
    fi
    sleep 5
  done
  if [ "$pw_ok" = "1" ]; then
    echo "   OK: CRIBL_ADMIN_PASSWORD applied"
  else
    fail "admin password bootstrap did not apply CRIBL_ADMIN_PASSWORD"
  fi
fi
docker rm -f "$c3" >/dev/null 2>&1 || true

if [ -n "${CRIBL_LICENSE:-}" ]; then
  echo "== 4. licensed positive: leader + FIPS must run FIPS-enabled"
  docker rm -f "$c4" >/dev/null 2>&1 || true
  docker run -d --name "$c4" -e CRIBL_DIST_MODE=master -e CRIBL_LICENSE="$CRIBL_LICENSE" "$image" >/dev/null
  if ! wait_health "$c4" "$BOOT_WAIT"; then
    fail "health probe (licensed FIPS leader) — last 40 log lines:"
    docker logs "$c4" 2>&1 | tail -40 >&2
  elif ! docker exec "$c4" sh -c \
      'grep -hi "running with FIPS enabled" /opt/cribl/log/cribl.log 2>/dev/null' | grep -q .; then
    fail "licensed FIPS leader healthy but no 'running with FIPS enabled' in cribl.log:"
    docker exec "$c4" sh -c 'grep -hi "fips\|rbac\|license" /opt/cribl/log/cribl.log | head -15' >&2 || true
  else
    echo "   OK: running with FIPS enabled"
  fi
  docker rm -f "$c4" >/dev/null 2>&1 || true
else
  echo "== 4. SKIPPED: full FIPS-enabled boot needs CRIBL_LICENSE (RBAC-entitled"
  echo "   Enterprise/trial license). Set it to run the positive assert."
fi

if [ "$rc" -eq 0 ]; then echo "OK: $image passed validation"; fi
exit "$rc"
