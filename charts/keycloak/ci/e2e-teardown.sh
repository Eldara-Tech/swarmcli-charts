#!/usr/bin/env bash
#
# e2e teardown for the keycloak chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes the co-located MariaDB backend service, the two secrets, and the DB overlay
# this hook OWNS (keycloak-db-net). It LEAVES the shared traefik-public overlay and, for
# the db-net-override fixture, the shared mariadb-net (owned by the mariadb chart/operator).
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"

# Remove the traefik edge the edge fixture stood up (issue #63); leaves traefik-public.
if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

docker service rm mariadb >/dev/null 2>&1 || true
docker secret rm keycloak_db_password    >/dev/null 2>&1 || true
docker secret rm keycloak_admin_password >/dev/null 2>&1 || true

if [ "$case" != "db-net-override" ]; then
  # The overlay can linger "in use" for a moment after the service detaches; retry a few.
  for _ in $(seq 1 10); do
    docker network rm keycloak-db-net >/dev/null 2>&1 && break
    sleep 1
  done
fi

exit 0
