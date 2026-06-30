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
# Keycloak booted, connected to its database, and finished migrations.
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
cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_keycloak" | head -1)"
[ -n "$cid" ] || { echo "  ${release}_keycloak container not found"; exit 1; }

docker exec "$cid" /bin/bash -c '
  exec 3<>/dev/tcp/127.0.0.1/9000 || exit 1
  printf "GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
  read -r status <&3
  [[ "$status" == *" 200 "* ]]'

echo "  ${release}_keycloak: /health/ready returned 200 OK"
