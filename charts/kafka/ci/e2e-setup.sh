#!/usr/bin/env bash
#
# e2e setup for the kafka chart. scripts/e2e-test.sh runs this BEFORE
# `swarmcli charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the
# operator-supplied secrets and the per-peer persistence node-label pins. The kafka-net
# and monitoring overlays are autoCreate:true, so swarmcli creates them at install, not
# this hook. ci/e2e-teardown.sh removes everything created here.
#
# The internal password holds every character the start script has to escape on its
# way into the JAAS string and the properties file (" \ $ and a space), and the app
# password the / and + of a base64 one, so a broken escape fails the cluster here rather
# than in an operator's install.
#
# CI's swarm is a SINGLE node, but the chart pins peer N to node.labels.kafka-<N>.
# Rather than skip the pinned shape (which is the one operators run), this labels the one
# node with EVERY peer's label, so the pinned fixtures schedule every peer there. That is
# not high availability; it is the pinned render, converging, with a real quorum of
# separate peers.
#
# The traefik fixture also needs the edge: the in-repo traefik chart, stood up by the
# shared helper.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates
# "already exists").
set -euo pipefail

mk() { docker secret inspect "$1" >/dev/null 2>&1 || printf '%s' "$2" | docker secret create "$1" - >/dev/null; }
mk kafka_internal_password 'in"ter\nal $pw x'
mk kafka_app_password 'app/pass+word=='
mk kafka_exporter_password 'exporter-pw'

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  for i in 1 2 3 4 5; do
    docker node update --label-add "kafka-$i=true" "$node" >/dev/null
  done
fi

if [ "$3" = traefik ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
