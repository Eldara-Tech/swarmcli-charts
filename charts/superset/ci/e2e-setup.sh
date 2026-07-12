#!/usr/bin/env bash
#
# e2e setup for the superset chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
#
# Superset is a pure consumer: it owns no overlay, no database and no Redis, and swarmcli
# creates none of them (every network it needs is autoCreate:false, and secrets are never
# auto-created), so EVERY fixture needs this hook. It provisions:
#   * the four operator secrets (dummy values);
#   * the overlays superset-db-net / redis-net / traefik-public;
#   * a throwaway metadata database on superset-db-net — postgres:15 named `postgres`, or
#     mysql:8 named `mysql` for the mysql fixture (matching each fixture's database.host) —
#     with the `superset` schema + user created from the image's own env bootstrap;
#   * a throwaway redis:7 named `redis` on redis-net, password-protected to match
#     redis.auth.enabled;
#   * for the edge fixture, the traefik chart as a real edge (shared helper, issue #63).
#
# The backends are EPHEMERAL and UNPINNED — they deliberately do not use the redis/mariadb
# charts' node labels, so they never collide with those charts' own e2e runs.
# ci/e2e-teardown.sh removes everything created here (leaving the shared overlays).
#
# INVARIANT: the database/redis passwords here must equal the secret values the chart reads,
# and the DB user/schema must match database.username/database.database. This hook owns both
# sides, so it sets one $PW and uses it everywhere.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

dir="$2"
case="$3"
PW='test'

for s in superset_secret_key superset_db_password superset_redis_password superset_admin_password; do
  docker secret inspect "$s" >/dev/null 2>&1 || printf '%s' "$PW" | docker secret create "$s" - >/dev/null
done

for n in superset-db-net redis-net traefik-public; do
  docker network create --driver overlay --attachable "$n" >/dev/null 2>&1 || true
done

# Metadata database. The mysql fixture points database.host at `mysql`; every other fixture
# uses postgres. Both images create the schema + user from these env vars on first boot.
if [ "$case" = "mysql" ]; then
  docker service rm mysql >/dev/null 2>&1 || true
  docker service create --name mysql --network superset-db-net \
    --env MYSQL_ROOT_PASSWORD="$PW" \
    --env MYSQL_DATABASE=superset \
    --env MYSQL_USER=superset \
    --env MYSQL_PASSWORD="$PW" \
    mysql:8 >/dev/null
  db_probe() { docker exec "$1" mysqladmin ping --silent >/dev/null 2>&1; }
  db_name=mysql
else
  docker service rm postgres >/dev/null 2>&1 || true
  docker service create --name postgres --network superset-db-net \
    --env POSTGRES_DB=superset \
    --env POSTGRES_USER=superset \
    --env POSTGRES_PASSWORD="$PW" \
    postgres:15 >/dev/null
  db_probe() { docker exec "$1" pg_isready -U superset -d superset >/dev/null 2>&1; }
  db_name=postgres
fi

docker service rm redis >/dev/null 2>&1 || true
docker service create --name redis --network redis-net \
  redis:7 redis-server --requirepass "$PW" >/dev/null

# Wait for the task to run (image pull), then until the server actually accepts connections, so
# superset-init does not burn its restart budget racing a database that is still starting.
for svc in "$db_name" redis; do
  for _ in $(seq 1 40); do
    state="$(docker service ps "$svc" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | head -1)"
    case "$state" in Running*) break ;; esac
    sleep 3
  done
done
for _ in $(seq 1 40); do
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${db_name}" | head -1)"
  if [ -n "$cid" ] && db_probe "$cid"; then
    break
  fi
  sleep 3
done

# --- edge fixture only: stand up the traefik chart as a REAL edge on traefik-public so
# ci/e2e-check.sh can prove a request routes THROUGH it to Superset (shared helper, issue #63).
if [ "$case" = "edge" ]; then
  # shellcheck source=/dev/null
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
