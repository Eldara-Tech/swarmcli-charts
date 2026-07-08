#!/usr/bin/env bash
#
# e2e setup for the mariadb chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the two
# operator-supplied secrets and the persistence node-label pin. For the bind-mount
# fixture it also pre-creates the host data dir owned by the container's mysql uid (999).
# The shared mariadb-net overlay is autoCreate:true, so swarmcli creates it at install —
# not this hook. ci/e2e-teardown.sh removes everything created here. (See
# charts/redis/ci/e2e-setup.sh for the shared shape.)
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

case="$3"

docker secret inspect mariadb_root_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create mariadb_root_password - >/dev/null
docker secret inspect mariadb_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create mariadb_password - >/dev/null

# Pin: label this (single-node) swarm's node so node.labels.mariadb-data == true schedules.
# Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-add mariadb-data=true "$node" >/dev/null

# bind-mount fixture only (ci/bind-mount-values.yaml mounts /opt/mariadb-data at
# /var/lib/mysql). mariadb:11.8 runs its server as the mysql user (uid 999) and — unlike a
# named volume, which inherits the image's mysql-owned datadir — does NOT chown a
# bind-mounted host dir, so mysql cannot initialise it unless it is writable by uid 999.
# The CI runner may be non-root without sudo, so provision the host dir via a throwaway
# root container (dockerd always runs as root): the -v auto-creates it and chmod 0777
# makes it writable regardless of its owner. Best-effort.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt/mariadb-data:/data alpine chmod 0777 /data >/dev/null 2>&1 || true
fi
