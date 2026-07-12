#!/usr/bin/env bash
#
# e2e teardown for the superset chart: removes everything ci/e2e-setup.sh created, EXCEPT the
# shared overlays that other charts' fixtures also use (traefik-public, redis-net).
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# scripts/e2e-test.sh runs this after the case (and before it, to clean up a crashed run), so
# it must be idempotent and must never fail.
set -euo pipefail

dir="$2"
case="$3"

if [ "$case" = "edge" ]; then
  # shellcheck source=/dev/null
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down || true
fi

docker service rm postgres >/dev/null 2>&1 || true
docker service rm mysql    >/dev/null 2>&1 || true
docker service rm redis    >/dev/null 2>&1 || true

for s in superset_secret_key superset_db_password superset_redis_password superset_admin_password; do
  docker secret rm "$s" >/dev/null 2>&1 || true
done

# The overlay can linger "in use" for a moment after the services detach; retry a few times.
# Only superset-db-net is ours to remove — redis-net and traefik-public are shared.
for _ in $(seq 1 10); do
  docker network rm superset-db-net >/dev/null 2>&1 && break
  sleep 1
done

exit 0
