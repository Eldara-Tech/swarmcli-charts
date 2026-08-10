#!/usr/bin/env bash
#
# e2e setup for the postgres chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the operator
# secret and the persistence node-label pin. For the bind-mount fixture it also pre-creates the
# host data dir owned by the container's postgres uid (999). The shared postgres-net overlay is
# autoCreate:true, so swarmcli creates it at install — not this hook. ci/e2e-teardown.sh removes
# everything created here. (See charts/mariadb/ci/e2e-setup.sh for the shared shape.)
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

case="$3"

docker secret inspect postgres_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create postgres_password - >/dev/null

# Pin: label this (single-node) swarm's node so node.labels.postgres-data == true schedules.
# Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add postgres-data=true "$node" >/dev/null

# bind-mount fixture (ci/bind-mount-values.yaml bind-mounts /opt/postgres-data at
# /var/lib/postgresql). Empty the dir for a clean first init and own it as the postgres uid/gid
# (999), matching a fresh named volume — the entrypoint creates PGDATA one level below it, so
# unlike mariadb the mount root itself never has to satisfy initdb's permission checks. It runs
# via a throwaway root container so it works whether or not the runner has sudo (dockerd always
# runs as root). Best-effort.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt/postgres-data:/data alpine \
    sh -c 'rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null; chown 999:999 /data; chmod 0700 /data' >/dev/null 2>&1 || true
fi
