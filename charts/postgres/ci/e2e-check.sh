#!/usr/bin/env bash
#
# Optional e2e smoke check for the postgres chart. scripts/e2e-test.sh runs this after the
# release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case name
# Exit 0 = healthy, non-zero = failure.
#
# It is run once per fixture (default / ephemeral / bind-mount / published-port / custom-user /
# legacy-major), so it probes the running container instead of assuming a user, a major or a
# storage backend: it locates the postgres task container for service "<release>_postgres" (a
# local e2e swarm is single-node) and `docker exec`s in.
#
# PREREQUISITES (scripts/e2e-test.sh sets these up via ci/e2e-setup.sh):
#   docker node update --label-add postgres-data=true <node>
#   printf test | docker secret create postgres_password -
# The bind-mount fixture additionally needs its host dir to pre-exist on the node.
set -euo pipefail

release="$1"
case="$3"

cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_postgres" | sed -n 1p)"
[ -n "$cid" ] || { echo "  ${release}_postgres container not found"; exit 1; }

# Query over TCP with the password read from the MOUNTED SECRET — deliberately not the
# container's local-socket trust auth, which would pass even if POSTGRES_PASSWORD_FILE were
# misspelled or the secret never mounted. This is the same scram path keycloak/superset take, so
# it proves the chart's only nontrivial auth machinery end to end. The container's own
# POSTGRES_USER/POSTGRES_DB keep the check generic (custom-user renames both); the secret name is
# discovered rather than assumed (the chart mounts exactly one). ON_ERROR_STOP makes psql exit
# non-zero on a SQL error, and the SQL is idempotent because a bind-mounted datadir can survive a
# crashed run.
secret="$(docker exec "$cid" sh -c 'ls /run/secrets/ 2>/dev/null | head -1')"
[ -n "$secret" ] || { echo "  ${release}_postgres: no secret mounted at /run/secrets"; exit 1; }

docker exec "$cid" sh -c "
  PGPASSWORD=\"\$(cat /run/secrets/$secret)\" \
  psql -h 127.0.0.1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1 -tAc \"
    CREATE TABLE IF NOT EXISTS e2e_smoke (id int PRIMARY KEY, v text);
    INSERT INTO e2e_smoke VALUES (1, 'ok') ON CONFLICT (id) DO UPDATE SET v = EXCLUDED.v;
    SELECT v FROM e2e_smoke WHERE id = 1;\"" \
  | grep '^ok$' >/dev/null

# Persistence. The data mount is the PARENT dir /var/lib/postgresql (PGDATA lives one level
# below it), so assert on the mount's TYPE and NAME — not on its mere presence: the image
# declares VOLUME /var/lib/postgresql, so Swarm attaches an ANONYMOUS volume there even when
# persistence is off. That anonymous volume dies with the task (a recreated task gets a fresh
# one), so the fixture is still ephemeral — but it means a /proc/mounts probe would assert
# nothing.
mtype="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Type}}{{end}}{{end}}' "$cid")"
mid="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Name}}{{.Source}}{{end}}{{end}}' "$cid")"

if [ "$case" = "ephemeral" ]; then
  case "$mid" in
    *postgres-data*) echo "  ${release}_postgres: ephemeral fixture mounted a persistent data volume ($mtype $mid)"; exit 1 ;;
  esac
  echo "  ${release}_postgres: connectivity + secret auth + write round-trip OK (ephemeral)"
  exit 0
fi

case "$mtype:$mid" in
  bind:/opt/postgres-data|volume:*postgres-data*) ;;
  *) echo "  ${release}_postgres: expected a named or bind data mount at /var/lib/postgresql, got '$mtype' '$mid'"; exit 1 ;;
esac
echo "  ${release}_postgres: connectivity + secret auth + write round-trip + persistent data mount OK"
