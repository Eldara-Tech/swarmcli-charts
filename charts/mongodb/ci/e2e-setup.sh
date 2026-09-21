#!/usr/bin/env bash
#
# e2e setup for the mongodb chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts install`,
# once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the three operator
# secrets and the persistence node-label pin. For the bind-mount fixture it also empties the host
# data dir. The shared mongodb-net overlay is autoCreate:true, so swarmcli creates it at install —
# not this hook. ci/e2e-teardown.sh removes everything created here. (See
# charts/postgres/ci/e2e-setup.sh for the shared shape.)
#
# The passwords end in a newline ON PURPOSE: `echo pw | docker secret create` is how many operators
# create secrets, and both the app-user init script and the replica-set probe must strip it the way
# the image does for the root password. ci/e2e-check.sh authenticates with the bare values, so a
# strip that was lost fails there.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

case="$3"

secret() {
  docker secret inspect "$1" >/dev/null 2>&1 || printf '%s\n' "$2" | docker secret create "$1" - >/dev/null
}
secret mongodb_root_password test-root
secret mongodb_password test-app
# A keyFile is 6-1024 base64 characters; mongod ignores whitespace in it.
secret mongodb_keyfile e2eKeyFileForTheSingleMemberReplicaSet

# Pin: label this (single-node) swarm's node so node.labels.mongodb-data == true schedules.
# Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add mongodb-data=true "$node" >/dev/null

# bind-mount fixture (ci/bind-mount-values.yaml bind-mounts /opt/mongodb-data at /data/db). Empty
# the dir for a clean first init; the image entrypoint chowns it to the mongodb uid itself. It runs
# via a throwaway root container so it works whether or not the runner has sudo (dockerd always
# runs as root). Best-effort.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt/mongodb-data:/data alpine \
    sh -c 'rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null' >/dev/null 2>&1 || true
fi
