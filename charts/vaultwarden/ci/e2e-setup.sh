#!/usr/bin/env bash
#
# e2e setup for the vaultwarden chart. scripts/e2e-test.sh runs this BEFORE `swarmcli
# charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates:
#   * the four dummy secrets (created for EVERY fixture — a fixture that does not
#     reference one leaves it inert, and unconditional creation keeps this simple);
#   * the persistence node label the data pin needs;
#   * traefik-public (autoCreate:false in requirements.yaml — the operator/traefik
#     chart owns it; here we stand in for them);
#   * for the postgres/mysql fixtures, the DB overlay plus a throwaway backend named
#     to match that fixture's database.*.host, with the vaultwarden schema + user
#     bootstrapped from the image's own env, waited on until it accepts connections.
# ci/e2e-teardown.sh removes everything created here (leaving shared overlays).
#
# INVARIANT: the backend's app-user password must equal the vaultwarden_*_password
# secret's content ($DBPW), and its schema/user must equal database.<type>.name /
# .username (vaultwarden) — otherwise the app cannot authenticate and never converges.
# This hook owns both sides, so it sets one $DBPW and uses it for both.
#
# Idempotent: safe to re-run after a crashed run (every step tolerates "already exists").
set -euo pipefail

dir="$2"
case="$3"
DBPW='test'

# --- dummy secrets ---------------------------------------------------------------
for s in vaultwarden_postgres_password vaultwarden_mysql_password vaultwarden_smtp_password; do
  docker secret inspect "$s" >/dev/null 2>&1 \
    || printf '%s' "$DBPW" | docker secret create "$s" - >/dev/null
done
# The admin token is a distinct value so ci/e2e-check.sh can prove the ADMIN_TOKEN
# export wrapper carried THIS secret's content and not a neighbouring one.
docker secret inspect vaultwarden_admin_token >/dev/null 2>&1 \
  || printf 'e2e-admin-token' | docker secret create vaultwarden_admin_token - >/dev/null

# --- persistence pin -------------------------------------------------------------
# Label this (single-node) swarm's node so the persistence.nodeLabel constraint
# schedules. Harmless for the ephemeral/edge fixtures (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-add vaultwarden-data=true "$node" >/dev/null

# Shared ingress overlay the traefik/none/edge exposure modes attach to.
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

# --- bind-mount fixture only: pre-create the host dir (path matches
# ci/bind-mount-values.yaml). Done from a throwaway root container so it works whether
# or not the runner has sudo (dockerd always runs as root), the same way the postgres
# chart's hook provisions its own bind dir. Best-effort. --------------------------
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /srv/vaultwarden:/data alpine \
    sh -c 'chmod 0777 /data' >/dev/null 2>&1 || true
fi

# --- external-database fixtures: overlay + a co-located backend --------------------
# Named vw-* rather than postgres/mariadb so this never collides with the keycloak or
# superset hooks, which stand up services under those plain names.
if [ "$case" = "postgres" ] || [ "$case" = "mysql" ]; then
  if [ "$case" = "postgres" ]; then
    dbnet=postgres-net
    db_name=vw-postgres
  else
    dbnet=mariadb-net
    db_name=vw-mariadb
  fi
  docker network create --driver overlay --attachable "$dbnet" >/dev/null 2>&1 || true

  docker service rm "$db_name" >/dev/null 2>&1 || true
  if [ "$case" = "postgres" ]; then
    docker service create --name "$db_name" --network "$dbnet" \
      --env POSTGRES_DB=vaultwarden \
      --env POSTGRES_USER=vaultwarden \
      --env POSTGRES_PASSWORD="$DBPW" \
      postgres:18 >/dev/null
    # pg_isready against 127.0.0.1 (TCP), not the unix socket: during first init the
    # entrypoint runs a temporary server that listens on the socket ONLY, so a socket
    # probe would report ready while initdb is still running.
    db_probe() { docker exec "$1" pg_isready -h 127.0.0.1 -U vaultwarden -d vaultwarden >/dev/null 2>&1; }
  else
    docker service create --name "$db_name" --network "$dbnet" \
      --env MARIADB_ROOT_PASSWORD="$DBPW" \
      --env MARIADB_DATABASE=vaultwarden \
      --env MARIADB_USER=vaultwarden \
      --env MARIADB_PASSWORD="$DBPW" \
      mariadb:11.8 >/dev/null
    # The image's healthcheck.sh --connect uses its own localhost socket — no creds needed.
    db_probe() { docker exec "$1" healthcheck.sh --connect >/dev/null 2>&1; }
  fi

  # Wait for the task to run (image pull), then until it actually accepts connections,
  # so Vaultwarden does not race the DB during its own boot/migration.
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
fi

# --- edge fixture only: stand up the traefik chart as a REAL edge on traefik-public,
# so ci/e2e-check.sh can prove a request routes THROUGH it (shared helper). -----------
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
