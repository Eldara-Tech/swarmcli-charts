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
#   * stands up a throwaway MariaDB named `mariadb` (matching database.host) on the DB
#     overlay, with the `keycloak` schema + `keycloak` user auto-created from
#     MARIADB_DATABASE/_USER/_PASSWORD, and waits until it accepts connections.
# The backend is EPHEMERAL and UNPINNED — it deliberately does NOT use the mariadb
# chart's `mariadb-data` node label, so it never collides with that chart's own e2e.
# ci/e2e-teardown.sh removes everything created here (leaving shared overlays).
#
# INVARIANT: MARIADB_PASSWORD must equal the keycloak_db_password secret value ($DBPW),
# and MARIADB_USER must equal database.username (keycloak) — else migrations fail on
# auth. The hook owns both, so it sets one $DBPW and uses it for both.
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

# Co-located backend, resolvable as `mariadb` on the DB overlay.
docker service rm mariadb >/dev/null 2>&1 || true
docker service create --name mariadb --network "$dbnet" \
  --env MARIADB_ROOT_PASSWORD="$DBPW" \
  --env MARIADB_DATABASE=keycloak \
  --env MARIADB_USER=keycloak \
  --env MARIADB_PASSWORD="$DBPW" \
  mariadb:11.8 >/dev/null

# Wait for the task to run (image pull), then until it actually accepts connections
# (the image's healthcheck.sh --connect uses its own localhost socket — no creds needed)
# so Keycloak does not race the DB during its own boot/migration.
for _ in $(seq 1 40); do
  state="$(docker service ps mariadb --filter desired-state=running \
    --format '{{.CurrentState}}' 2>/dev/null | head -1)"
  case "$state" in Running*) break ;; esac
  sleep 3
done
for _ in $(seq 1 40); do
  cid="$(docker ps -q -f 'label=com.docker.swarm.service.name=mariadb' | head -1)"
  if [ -n "$cid" ] && docker exec "$cid" healthcheck.sh --connect >/dev/null 2>&1; then
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
