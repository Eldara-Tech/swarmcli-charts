#!/usr/bin/env bash
#
# e2e setup for the ollama chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates. Ollama has
# no auth, so there is no secret to create. ci/e2e-teardown.sh removes everything created here.
#
# Idempotent: safe to re-run after a crashed run (every step tolerates "already exists").
set -euo pipefail

dir="$2"
case="$3"

# Pin: label this (single-node) swarm's node so the persistence.nodeLabel constraint
# schedules. Harmless for the ephemeral/edge fixtures (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-add ollama-data=true "$node" >/dev/null

# Shared ingress overlay the traefik/none/edge exposure modes attach to (autoCreate:false in
# requirements.yaml — the operator/traefik chart owns it; here we stand in for them).
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

# --- bind-mount fixture only: pre-create the host bind-mount dir (path matches
# ci/bind-mount-values.yaml), world-writable so the container can provision it -----------
if [ "$case" = "bind-mount" ]; then
  mkdir -p /tmp/ollama-e2e/data
  chmod -R 0777 /tmp/ollama-e2e
fi

# --- edge fixture only: stand up the traefik chart as a REAL edge on traefik-public, so
# ci/e2e-check.sh can prove a request routes THROUGH it to Ollama (shared helper). Removed
# again by ci/e2e-teardown.sh. ---------------------------------------------------------
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
