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

# bind-mount fixture (ci/bind-mount-values.yaml mounts /opt/mariadb-data at
# /var/lib/mysql). This fixture is EXCLUDED from the CI subset (see .github/workflows/
# e2e.yml): MariaDB's healthcheck cannot authenticate on a host bind-mounted datadir in
# the Swarm CI environment even with a clean, mysql-owned datadir — it works on a named
# volume. The provisioning below stays for local `make e2e`: empty the dir for a clean
# first-init and own it as the mysql uid/gid (999), matching a fresh named volume. It
# runs via a throwaway root container so it works whether or not the runner has sudo
# (dockerd always runs as root). Best-effort.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt/mariadb-data:/data alpine \
    sh -c 'rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null; chown 999:999 /data; chmod 0755 /data' >/dev/null 2>&1 || true
fi
