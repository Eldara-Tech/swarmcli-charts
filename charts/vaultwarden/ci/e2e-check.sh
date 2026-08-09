#!/usr/bin/env bash
#
# Optional e2e smoke check for the vaultwarden chart. scripts/e2e-test.sh runs this after
# the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# It probes the running server rather than assuming an exposure mode: it locates the task
# container for service "<release>_vaultwarden" (a local e2e swarm is single-node) and runs
# the image's own /healthcheck.sh inside it, which curls /alive on ROCKET_PORT. Then, for
# the fixtures that assemble something at runtime, it asserts what actually reached PID 1.
#
# Reading /proc/1/environ is the point of the secret/database assertions, not an
# implementation detail: the chart exports DATABASE_URL/ADMIN_TOKEN/SMTP_PASSWORD from an
# `sh -c` wrapper that reads /run/secrets/* with a compose-escaped `$$(cat …)`. If that
# escape is ever eaten, the shell expands `$$` to its own pid and the app silently runs
# holding the literal value "1(cat /run/secrets/…)". `docker exec` gets the image+service
# environment, NOT the wrapper's exports, so PID 1's environ is the only place the real
# value is visible.
set -euo pipefail

release="$1"
case="${3:-}"
DBPW='test'   # must match ci/e2e-setup.sh

vw_cid() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_vaultwarden" | head -1; }

# PID 1's environment, one NUL-separated entry per line.
pid1_env() { docker exec "$1" sh -c "tr '\\0' '\\n' < /proc/1/environ" 2>/dev/null; }

# Assert PID 1 carries exactly this VAR=value. Never echoes the value (dummy here, but the
# same check on a real deployment would leak a credential into the log).
assert_env() { # $1 cid  $2 VAR=value  $3 human description
  if pid1_env "$1" | grep -qxF "$2"; then
    echo "  ${3}: exported to PID 1 as expected"
    return 0
  fi
  echo "  FAIL: ${3} is not what the chart's export wrapper should have produced"
  echo "        (present vars: $(pid1_env "$1" | cut -d= -f1 | sort | tr '\n' ' '))"
  return 1
}

# Wait for the app to actually serve. Task "Running" != serving, and an unhealthy task may
# be replaced under us, so re-resolve the container each attempt. Retry for up to ~2.5 min.
ok=0
for _ in $(seq 1 30); do
  cid="$(vw_cid)"
  if [ -n "$cid" ] && docker exec "$cid" /healthcheck.sh >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  echo "  FAIL: ${release}_vaultwarden never became healthy (/healthcheck.sh)"
  docker service ps "${release}_vaultwarden" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi
cid="$(vw_cid)"
echo "  ${release}_vaultwarden: serving (/healthcheck.sh OK)"

# --- external-database fixtures: the app converged, so it connected — assert it connected
# to the CONFIGURED backend via a well-formed URL, not to the SQLite fallback. ----------
if [ "$case" = "postgres" ]; then
  assert_env "$cid" \
    "DATABASE_URL=postgresql://vaultwarden:${DBPW}@vw-postgres:5432/vaultwarden?sslmode=disable" \
    "DATABASE_URL (postgres)" || exit 1
fi
if [ "$case" = "mysql" ]; then
  assert_env "$cid" \
    "DATABASE_URL=mysql://vaultwarden:${DBPW}@vw-mariadb:3306/vaultwarden" \
    "DATABASE_URL (mysql)" || exit 1
fi

# --- secrets fixture: both secret-backed exports carry their secret's real content. -----
if [ "$case" = "secrets" ]; then
  assert_env "$cid" "ADMIN_TOKEN=e2e-admin-token"  "ADMIN_TOKEN"   || exit 1
  assert_env "$cid" "SMTP_PASSWORD=${DBPW}"        "SMTP_PASSWORD" || exit 1
fi

# --- bind-mount fixture: confirm /data is a mount (persistence actually took effect),
# not the container's ephemeral layer. -------------------------------------------------
if [ "$case" = "bind-mount" ]; then
  if docker exec "$cid" sh -c 'grep -q " /data " /proc/mounts'; then
    echo "  bind-mount: /data is persisted (mounted)"
  else
    echo "  FAIL: /data is not mounted — persistence did not take effect"
    exit 1
  fi
fi

# --- edge fixture: prove a request routes THROUGH the stood-up traefik edge. The probe
# above proved the app serves; now assert it is reachable via the edge with a matching
# Host header, and that an unknown host 404s. ------------------------------------------
if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed vaultwarden.e2e.test /alive 200 || exit 1
  edge_assert_unrouted no-such-host.invalid || exit 1
fi

exit 0
