#!/usr/bin/env bash
#
# Optional e2e smoke check for the mariadb chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# It is run once per fixture (default / no-appuser / ephemeral / published-port),
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

# Persistence: a named volume shows up as a distinct mount at the data dir; an
# ephemeral instance keeps the data dir on the container rootfs (no mount entry).
if docker exec "$cid" sh -c 'grep -q " /var/lib/mysql " /proc/mounts'; then
  echo "  ${release}_mariadb: connectivity + create/insert/select + persistent volume OK"
else
  echo "  ${release}_mariadb: connectivity + create/insert/select OK (ephemeral)"
fi
