#!/usr/bin/env bash
#
# e2e teardown for the vaultwarden chart. scripts/e2e-test.sh runs this AFTER the release
# is uninstalled (best-effort; errors ignored):
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created — the four secrets, the persistence node
# label, the bind-mount host dir, and the DB backend plus the overlay this hook OWNS — and
# LEAVES the shared traefik-public overlay (other releases use it).
set -uo pipefail

dir="$2"
case="$3"

# edge fixture: tear down the traefik edge (leaves the shared traefik-public overlay).
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

for s in vaultwarden_postgres_password vaultwarden_mysql_password \
         vaultwarden_admin_token vaultwarden_smtp_password; do
  docker secret rm "$s" >/dev/null 2>&1 || true
done

# Backend + its overlay, only for the fixture that created them (an unconditional sweep
# would spend the retry budget below on every other fixture for nothing).
if [ "$case" = "postgres" ] || [ "$case" = "mysql" ]; then
  if [ "$case" = "postgres" ]; then db_name=vw-postgres; dbnet=postgres-net
  else                              db_name=vw-mariadb;  dbnet=mariadb-net
  fi
  docker service rm "$db_name" >/dev/null 2>&1 || true
  # The overlay can linger "in use" for a moment after the service detaches; retry a few.
  for _ in $(seq 1 10); do
    docker network rm "$dbnet" >/dev/null 2>&1 && break
    sleep 1
  done
fi

# Drop the persistence pin label.
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-rm vaultwarden-data "$node" >/dev/null 2>&1 || true

# bind-mount fixture: remove the host dir (root-owned, so from a throwaway root container).
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /srv:/host-srv alpine \
    sh -c 'rm -rf /host-srv/vaultwarden' >/dev/null 2>&1 || true
fi

exit 0
