#!/usr/bin/env bash
#
# Optional e2e smoke check for the mariadb chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# It is run once per fixture (default / no-appuser / ephemeral / published-port / metrics),
# so it probes the running container instead of assuming the app user or
# persistence: it locates the mariadb task container for service "<release>_mariadb"
# (a local e2e swarm is single-node) and `docker exec`s in, reading the root
# password from the mounted secret (never on a command line — passed via MYSQL_PWD).
# Persistence is detected by the data volume being a real mount.
#
# PREREQUISITES (scripts/e2e-test.sh sets these up):
#   docker node update --label-add mariadb-data=true <node>
#   printf test | docker secret create mariadb_root_password -
#   printf test | docker secret create mariadb_password -
#   printf test | docker secret create mariadb_exporter_password -
# The bind-mount fixture additionally needs its host dir to pre-exist on the node
# (bind mounts are not auto-created with the right owner):
#   install -d -o 999 -g 999 /opt/mariadb-data
set -euo pipefail

release="$1"
cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_mariadb" | sed -n 1p)"
[ -n "$cid" ] || { echo "  ${release}_mariadb container not found"; exit 1; }

# Run a query as root, reading the password from the mounted secret via MYSQL_PWD
# (keeps it off the command line). Connectivity + a CREATE/INSERT/SELECT round-trip.
docker exec "$cid" sh -c \
  'MYSQL_PWD="$(cat /run/secrets/mariadb_root_password)" mariadb -uroot -N -e "
     CREATE DATABASE IF NOT EXISTS e2e_smoke;
     CREATE TABLE IF NOT EXISTS e2e_smoke.t (id INT PRIMARY KEY, v VARCHAR(16));
     REPLACE INTO e2e_smoke.t VALUES (1, \"ok\");
     SELECT v FROM e2e_smoke.t WHERE id = 1;"' \
  | grep '^ok$' >/dev/null

# With the metrics fixture: the exporter answers on the metrics overlay — where
# Prometheus would scrape it — logged in as the user the one-shot created (`--wait`
# only returns once that one-shot completed), and every default collector succeeds.
# A missing grant shows up only as a collector failing, never as mysql_up 0, which is
# why the collectors are checked one by one.
metrics_ok=""
exp="${release}_mariadb-exporter"
if docker service inspect "$exp" >/dev/null 2>&1; then
  m=""
  for _ in $(seq 1 15); do
    m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://$exp:9104/metrics" 2>&1 || true)"
    grep -qx 'mysql_up 1' <<<"$m" && break
    sleep 2
  done
  if ! grep -qx 'mysql_up 1' <<<"$m"; then
    echo "  $exp: mysql_up is not 1 on the metrics overlay. Scrape and exporter log:"
    grep -E '^mysql_up|^curl' <<<"$m" | sed 's/^/    /'
    docker service logs --tail 5 "$exp" 2>&1 | sed 's/^/    /'
    exit 1
  fi
  failed="$(grep -E '^mysql_exporter_collector_success\{.*\} 0$' <<<"$m" || true)"
  [ -z "$failed" ] || { echo "  $exp: collectors failing (a missing grant):"; echo "$failed" | sed 's/^/    /'; exit 1; }
  # The exporter's login is its own least-privilege user, not root.
  grants="$(docker exec "$cid" sh -c \
    'MYSQL_PWD="$(cat /run/secrets/mariadb_root_password)" mariadb -uroot -N -e "SHOW GRANTS FOR exporter@\"%\""')"
  grep -F 'GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO' <<<"$grants" >/dev/null \
    || { echo "  exporter grants are not the least-privilege set: $grants"; exit 1; }
  metrics_ok=", exporter scraped on monitoring (mysql_up 1, all collectors OK)"
fi

# Persistence: a named volume shows up as a distinct mount at the data dir; an
# ephemeral instance keeps the data dir on the container rootfs (no mount entry).
if docker exec "$cid" sh -c 'grep -q " /var/lib/mysql " /proc/mounts'; then
  echo "  ${release}_mariadb: connectivity + create/insert/select + persistent volume${metrics_ok} OK"
else
  echo "  ${release}_mariadb: connectivity + create/insert/select${metrics_ok} OK (ephemeral)"
fi
