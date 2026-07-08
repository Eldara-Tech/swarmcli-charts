#!/usr/bin/env bash
#
# Optional e2e smoke check for the keycloak chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# Keycloak's readiness probe lives on the management port (9000), which is not
# published or Traefik-routed, so we `docker exec` into the running task container
# and hit /health/ready over the loopback using the same bash /dev/tcp request the
# container healthcheck uses (the image ships no curl). A 200 status line means
# Keycloak booted, connected to its database, and finished migrations. We RETRY the
# probe (~2.5 min): a release converges (task "Running") before Keycloak is serving —
# especially the start-dev fixture, which disables the container healthcheck, so the
# task reaches Running the instant it starts, well before the HTTP port is up.
#
# PREREQUISITES (a full Keycloak e2e needs a real database the chart can reach):
#   docker network create -d overlay --attachable traefik-public
#   docker network create -d overlay --attachable keycloak-db-net
#   printf test | docker secret create keycloak_db_password -
#   printf test | docker secret create keycloak_admin_password -
#   a database service named per database.host on keycloak-db-net, with the
#   database.database schema + database.username/keycloak_db_password granted.
set -euo pipefail

release="$1"

# One /health/ready probe. Re-resolves the container each call (a crash-looping or
# health-replaced task changes container id). Silent; returns 0 only on a 200 status.
probe() {
  local cid
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_keycloak" | head -1)"
  [ -n "$cid" ] || return 1
  docker exec "$cid" /bin/bash -c '
    exec 3<>/dev/tcp/127.0.0.1/9000 || exit 1
    printf "GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
    read -r status <&3
    [[ "$status" == *" 200 "* ]]' 2>/dev/null
}

for _ in $(seq 1 30); do
  if probe; then
    echo "  ${release}_keycloak: /health/ready returned 200 OK"
    exit 0
  fi
  sleep 5
done

echo "  FAIL: ${release}_keycloak /health/ready never returned 200 within ~2.5m"
docker service ps "${release}_keycloak" --no-trunc 2>/dev/null | sed 's/^/    /' || true
exit 1
