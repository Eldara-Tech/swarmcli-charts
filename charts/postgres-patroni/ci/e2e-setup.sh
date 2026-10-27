#!/usr/bin/env bash
#
# e2e setup for the postgres-patroni chart. scripts/e2e-test.sh runs this BEFORE
# `swarmcli charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the
# three operator-supplied secrets and the per-peer persistence node-label pins. The
# shared postgres-patroni-net overlay is autoCreate:true, so swarmcli creates it at
# install, not this hook. ci/e2e-teardown.sh removes everything created here.
#
# CI's swarm is a SINGLE node, but the chart pins peer N and etcd member N to
# node.labels.postgres-patroni-<N>. Rather than skip the pinned shape (which is the one
# operators run), this labels the one node with EVERY label, so the default fixture
# schedules all peers and members there. That is not high availability, but it is a
# real cluster: a real etcd quorum, real streaming replicas and a real failover.
#
# For bind-mount, it also prepares the host directories that fixture names, empty: the
# peers' owned by the image's postgres uid (26), so Patroni can create the data directory
# beneath them, and the etcd members' by root, which etcd runs as.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

case="$3"

for s in superuser replication restapi; do
  docker secret inspect "postgres_patroni_${s}_password" >/dev/null 2>&1 \
    || printf 'test' | docker secret create "postgres_patroni_${s}_password" - >/dev/null
done

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  for i in 1 2 3 4 5; do
    docker node update --label-add "postgres-patroni-$i=true" "$node" >/dev/null
  done
fi

if [ "$case" = bind-mount ]; then
  docker run --rm -v /opt:/opt alpine sh -c '
    rm -rf /opt/postgres-patroni
    for i in 1 2 3; do
      mkdir -p /opt/postgres-patroni/peer-$i /opt/postgres-patroni/etcd-$i
      chown 26:26 /opt/postgres-patroni/peer-$i
      chmod 0700 /opt/postgres-patroni/peer-$i /opt/postgres-patroni/etcd-$i
    done' >/dev/null
fi
