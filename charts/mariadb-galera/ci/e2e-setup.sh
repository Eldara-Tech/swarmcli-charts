#!/usr/bin/env bash
#
# e2e setup for the mariadb-galera chart. scripts/e2e-test.sh runs this BEFORE
# `swarmcli charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates:
# the two operator-supplied secrets and the per-peer persistence node-label pins.
# The shared mariadb-galera-net overlay is autoCreate:true, so swarmcli creates it
# at install — not this hook. ci/e2e-teardown.sh removes everything created here.
#
# CI's swarm is a SINGLE node, but the chart pins peer N to node.labels.
# mariadb-galera-<N>. Rather than skip the pinned shape (which is the one operators
# run), this labels the one node with EVERY peer's label, so the default fixture
# schedules all peers there. That is not high availability — it is the pinned
# render, converging, with a real state transfer between real peers, which is what
# the smoke check needs in order to prove SST auth works at all.
#
# Labels 1..5 so the five-peers fixture also schedules if it is ever added to the
# CI subset. published-port is deliberately NOT in that subset: every peer
# publishes 3306 in host mode, and three peers cannot bind one node's port 3306.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates
# "already exists").
set -euo pipefail

docker secret inspect mariadb_galera_root_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create mariadb_galera_root_password - >/dev/null
docker secret inspect mariadb_galera_password >/dev/null 2>&1 \
  || printf 'test' | docker secret create mariadb_galera_password - >/dev/null

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  for i in 1 2 3 4 5; do
    docker node update --label-add "mariadb-galera-$i=true" "$node" >/dev/null
  done
fi
