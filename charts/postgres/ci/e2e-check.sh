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

# Metrics fixture: the exporter answers on the metrics overlay — where Prometheus would scrape it
# — logged in as the role the one-shot created (`--wait` only returns once that one-shot
# completed), with the password from the secret ci/e2e-setup.sh filled with quoting traps, and
# every default collector succeeds with pg_monitor alone. A missing privilege fails only its
# collector, never pg_up, which is why the collectors are checked one by one. Then the role
# itself: not a superuser, capped at 3 connections, a pg_monitor member.
metrics_ok=""
exp="${release}_postgres-exporter"
labels="$(docker service inspect "$exp" --format '{{json .Spec.Labels}}' 2>/dev/null || true)"
if [ "$case" != "metrics" ]; then
  # Metrics are opt-in: an exporter in any other fixture is a default that changed.
  [ -z "$labels" ] || { echo "  $exp exists although the fixture does not enable metrics"; exit 1; }
else
  # Without both discovery labels, Prometheus would never find it, however well it scrapes.
  for l in '"prometheus.io/scrape":"true"' '"prometheus.io/port":"9187"'; do
    grep -F "$l" <<<"$labels" >/dev/null || { echo "  $exp: deploy label $l missing (labels: ${labels:-<no service>})"; exit 1; }
  done
fi
if [ "$case" = "metrics" ]; then
  m=""
  for _ in $(seq 1 15); do
    m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://$exp:9187/metrics" 2>&1 || true)"
    grep -qx 'pg_up 1' <<<"$m" && break
    sleep 2
  done
  if ! grep -qx 'pg_up 1' <<<"$m"; then
    echo "  $exp: pg_up is not 1 on the metrics overlay. Scrape and exporter log:"
    grep -E '^pg_up|^pg_exporter_last_scrape_error|^curl' <<<"$m" | sed 's/^/    /'
    docker service logs --tail 5 "$exp" 2>&1 | sed 's/^/    /'
    docker service logs --tail 5 "${release}_postgres-exporter-user" 2>&1 | sed 's/^/    /'
    exit 1
  fi
  failed="$(grep -E '^pg_scrape_collector_success\{.*\} 0$|^pg_exporter_last_scrape_error 1$' <<<"$m" || true)"
  [ -z "$failed" ] || { echo "  $exp: failing collectors (a missing privilege):"; echo "$failed" | sed 's/^/    /'; exit 1; }
  ncoll="$(grep -cE '^pg_scrape_collector_success\{.*\} 1$' <<<"$m" || true)"
  role="$(docker exec "$cid" sh -c "
    PGPASSWORD=\"\$(cat /run/secrets/$secret)\" \
    psql -h 127.0.0.1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"
      SELECT rolsuper, rolconnlimit, pg_has_role(rolname, 'pg_monitor', 'member')
      FROM pg_roles WHERE rolname = 'exporter'\"")"
  [ "$role" = "f|3|t" ] || { echo "  role exporter is '$role' (rolsuper|rolconnlimit|pg_monitor), expected 'f|3|t'"; exit 1; }
  metrics_ok=", exporter scraped on monitoring (pg_up 1, $ncoll collectors OK, role pg_monitor only)"
fi

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
echo "  ${release}_postgres: connectivity + secret auth + write round-trip + persistent data mount$metrics_ok OK"
