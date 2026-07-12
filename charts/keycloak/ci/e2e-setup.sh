#!/usr/bin/env bash
#
# e2e setup for the keycloak chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# Keycloak attaches its DB overlay UNCONDITIONALLY (even mode: start-dev) and its
# /health/ready probe only returns 200 once it has connected to a real database and
# finished migrations, so EVERY CI fixture needs a reachable backend. This hook:
#   * creates the two operator secrets (dummy values);
#   * creates the DB overlay + traefik-public (both autoCreate:false — swarmcli won't);
#   * stands up a throwaway backend on the DB overlay, named to match the fixture's
#     database.host — `mariadb` for most fixtures, `postgres` for the PostgreSQL ones —
#     with the `keycloak` schema + `keycloak` user auto-created from the image's own env
#     bootstrap, and waits until it accepts connections.
# The backend is EPHEMERAL and UNPINNED — it deliberately does NOT use the mariadb/postgres
# charts' data node labels, so it never collides with those charts' own e2e.
# ci/e2e-teardown.sh removes everything created here (leaving shared overlays).
#
# INVARIANT: the backend's app-user password must equal the keycloak_db_password secret value
# ($DBPW), and its user/schema must equal database.username/database.database (keycloak) — else
# migrations fail on auth. The hook owns both sides, so it sets one $DBPW and uses it for both.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

case="$3"
DBPW='test'

docker secret inspect keycloak_db_password >/dev/null 2>&1 \
  || printf '%s' "$DBPW" | docker secret create keycloak_db_password - >/dev/null
docker secret inspect keycloak_admin_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create keycloak_admin_password - >/dev/null

# DB overlay name tracks the fixture: db-net-override points database.network at the
# mariadb chart's own mariadb-net instead of the default keycloak-db-net.
dbnet=keycloak-db-net
[ "$case" = "db-net-override" ] && dbnet=mariadb-net
docker network create --driver overlay --attachable "$dbnet"       >/dev/null 2>&1 || true
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

# Co-located backend, resolvable on the DB overlay as the fixture's database.host: the
# PostgreSQL fixtures (ci/postgres-values.yaml, ci/jdbc-url-values.yaml) dial `postgres`, every
# other fixture `mariadb`. Both images create the keycloak schema + user from these env vars on
# first boot. (Same shape as charts/superset/ci/e2e-setup.sh, which picks its metadata DB the
# same way.)
case "$case" in
  postgres | jdbc-url) db_name=postgres ;;
  *)                   db_name=mariadb ;;
esac

docker service rm "$db_name" >/dev/null 2>&1 || true
if [ "$db_name" = postgres ]; then
  docker service create --name postgres --network "$dbnet" \
    --env POSTGRES_DB=keycloak \
    --env POSTGRES_USER=keycloak \
    --env POSTGRES_PASSWORD="$DBPW" \
    postgres:18 >/dev/null
  # pg_isready against 127.0.0.1 (TCP), not the unix socket: during first init the entrypoint
  # runs a temporary server that listens on the socket ONLY, so a socket probe would report
  # ready while initdb is still running — exactly the race this loop exists to prevent.
  db_probe() { docker exec "$1" pg_isready -h 127.0.0.1 -U keycloak -d keycloak >/dev/null 2>&1; }
else
  docker service create --name mariadb --network "$dbnet" \
    --env MARIADB_ROOT_PASSWORD="$DBPW" \
    --env MARIADB_DATABASE=keycloak \
    --env MARIADB_USER=keycloak \
    --env MARIADB_PASSWORD="$DBPW" \
    mariadb:11.8 >/dev/null
  # The image's healthcheck.sh --connect uses its own localhost socket — no creds needed.
  db_probe() { docker exec "$1" healthcheck.sh --connect >/dev/null 2>&1; }
fi

# Wait for the task to run (image pull), then until it actually accepts connections, so
# Keycloak does not race the DB during its own boot/migration.
for _ in $(seq 1 40); do
  state="$(docker service ps "$db_name" --filter desired-state=running \
    --format '{{.CurrentState}}' 2>/dev/null | head -1)"
  case "$state" in Running*) break ;; esac
  sleep 3
done
for _ in $(seq 1 40); do
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${db_name}" | head -1)"
  if [ -n "$cid" ] && db_probe "$cid"; then
    break
  fi
  sleep 3
done

# --- edge fixture only: stand up the traefik chart as a REAL edge on traefik-public so
# ci/e2e-check.sh can prove a request routes THROUGH it to Keycloak (shared helper, issue
# #63). The DB/secrets/overlays above are provisioned for every fixture. -----------------
if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
