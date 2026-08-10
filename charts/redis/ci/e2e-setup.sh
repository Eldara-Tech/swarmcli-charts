#!/usr/bin/env bash
#
# e2e setup for the redis chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the
# operator-supplied auth secret and the persistence node-label pin. For the bind-mount
# fixture it also pre-creates the host data dir owned by the container's redis uid.
# The shared redis-net overlay is autoCreate:true, so swarmcli creates it at install —
# not this hook. ci/e2e-teardown.sh removes everything created here.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

case="$3"

# Dummy auth secret (redis requirepass). Its value is irrelevant to the smoke check,
# which reads it back from the mounted file — it just has to exist.
docker secret inspect redis_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create redis_password - >/dev/null

# Pin: label this (single-node) swarm's node so the persistence.nodeLabel constraint
# (node.labels.redis-data == true) schedules. Harmless for the ephemeral fixture (no pin).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add redis-data=true "$node" >/dev/null

# bind-mount fixture only: pre-create /opt/redis-data owned by the container's redis uid
# (999), matching ci/bind-mount-values.yaml. Best-effort — dockerd would auto-create the
# bind source and the entrypoint chowns /data, but pre-creating with the right owner is
# what the chart README documents. /opt is root-owned on the runner, so use sudo -n.
if [ "$case" = "bind-mount" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    install -d -o 999 -g 999 /opt/redis-data 2>/dev/null || true
  else
    sudo -n install -d -o 999 -g 999 /opt/redis-data 2>/dev/null \
      || mkdir -p /opt/redis-data 2>/dev/null || true
  fi
fi
