#!/usr/bin/env bash
#
# e2e teardown for the superset chart: removes the services and secrets ci/e2e-setup.sh created.
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# scripts/e2e-test.sh runs this after the case (and before it, to clean up a crashed run), so
# it must be idempotent and must never fail.
#
# It deliberately leaves the OVERLAYS behind — traefik-public and redis-net are shared with other
# charts' fixtures, and superset-db-net is left for a subtler reason: removing an overlay and
# re-creating it under the same name moments later (the next fixture's setup) races Swarm's
# eventually-consistent network removal, and a `docker service create` can then resolve the name
# to the ID that has just been dropped from the cluster store:
#   Error response from daemon: network <id> not found
# The overlays are cheap, idempotent to create, and harmless to keep for the run's lifetime.
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

exit 0
