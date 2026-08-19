#!/usr/bin/env bash
#
# e2e setup for the superset chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
#
# Superset owns no overlay and no metadata database, and swarmcli creates neither (every EXTERNAL
# network it needs is autoCreate:false, and secrets are never auto-created), so every fixture
# needs this hook. It provisions:
#   * the four operator secrets (dummy values);
#   * the overlays superset-db-net / redis-net / traefik-public;
#   * a throwaway metadata database on superset-db-net — postgres named `postgres` (major 18,
#     or 15 for the no-celery fixture; see below), or mysql:8 named `mysql` for the mysql
#     fixture (matching each fixture's database.host) — with the `superset` schema + user
#     created from the image's own env bootstrap;
#   * a throwaway redis:7 named `redis` on redis-net, password-protected to match
#     redis.auth.enabled — EXCEPT for the embedded-redis fixture (see below);
#   * for the edge fixture, the traefik chart as a real edge (shared helper, issue #63).
#
# REDIS IS THE ONE BACKEND THAT IS NOT ALWAYS EXTERNAL. redis.mode: embedded makes the chart run
# its own, so the embedded-redis fixture gets NO redis service from this hook — if embedded mode
# rendered no Redis, or a broken one, superset would simply never converge. That is the point of
# the fixture. The superset_redis_password secret IS still created: embedded mode keeps auth on
# and mounts that same secret into the Redis it runs.
#
# The redis-net OVERLAY is still created, for the other fixtures — and it is irrelevant to this
# one: embedded mode's overlay is chart-managed, so Swarm namespaces it as <release>_redis-net.
# Which also means e2e canNOT prove that embedded mode stopped depending on the external
# redis-net (teardown deliberately leaves overlays behind, so a sibling fixture's redis-net is
# usually lying around, and a regression that rendered the overlay external would still install).
# ci/render-check.sh asserts that directly instead — see its redis.mode block.
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
#
# WHICH postgres major, and why BOTH. The README tells operators to use the postgres chart with
# its own default (18) and NOT to pin, so that is the path the primary fixtures must prove — an
# untested recommendation is worse than none. Superset's 5.0.0 docs stopped at PostgreSQL 15,
# but that was documentation lag, not a ceiling: the 6.x docs dropped the numbered table
# entirely, upstream's own compose runs postgres:17, and nothing in Superset enforces a version
# (the metadata store is plain SQL; compatibility is whatever SQLAlchemy + psycopg2 support). The
# conservative in-matrix pin is still documented, so it needs coverage too — `no-celery` runs it
# on 15. It is already in the CI subset and is indifferent to the DB major, so both majors are
# proven at zero extra wall-clock.
#
# WHY a raw `docker service create` and not `swarmcli charts install ../postgres` (issue #71):
# deliberate, not inertia — the same call keycloak's hook makes for MariaDB. The postgres chart
# already runs EVERY fixture in its own e2e job, including `legacy-major`, which pins this exact
# tag; installing it here would duplicate that signal while making superset's 15-minute job fail
# on postgres-chart regressions, with worse attribution. Superset sees the same TCP endpoint
# either way — unlike Traefik, whose label/discovery contract is invisible until a real request
# routes through it, which is why THAT one is worth standing up for real (scripts/e2e-edge).
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
  pg_tag=18                                   # the postgres chart's default — what the README recommends
  [ "$case" = "no-celery" ] && pg_tag=15      # …and the conservative in-matrix pin it documents
  echo "   db: postgres:$pg_tag"              # which major this case proves (the README cites it)
  docker service rm postgres >/dev/null 2>&1 || true
  docker service create --name postgres --network superset-db-net \
    --env POSTGRES_DB=superset \
    --env POSTGRES_USER=superset \
    --env POSTGRES_PASSWORD="$PW" \
    "postgres:$pg_tag" >/dev/null
  db_probe() { docker exec "$1" pg_isready -U superset -d superset >/dev/null 2>&1; }
  db_name=postgres
fi

wait_svcs=("$db_name")
docker service rm redis >/dev/null 2>&1 || true
if [ "$case" = "embedded-redis" ]; then
  echo "   redis: none — the chart runs its own (redis.mode: embedded)"
else
  docker service create --name redis --network redis-net \
    redis:7 redis-server --requirepass "$PW" >/dev/null
  wait_svcs+=(redis)
fi

# Wait for the task to run (image pull), then until the server actually accepts connections, so
# superset-init does not burn its restart budget racing a database that is still starting.
for svc in "${wait_svcs[@]}"; do
  for _ in $(seq 1 40); do
    state="$(docker service ps "$svc" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in Running*) break ;; esac
    sleep 3
  done
done
for _ in $(seq 1 40); do
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${db_name}" | sed -n 1p)"
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
