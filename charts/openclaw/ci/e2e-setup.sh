#!/usr/bin/env bash
#
# e2e setup for the openclaw chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates (so the
# requirements pre-flight would otherwise reject the install), and — for the `backend`
# fixture — stands up a mock Ollama backend on the ai-internal overlay so ci/e2e-check.sh
# can prove the gateway reaches it. ci/e2e-teardown.sh removes everything created here.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

dir="$2"
case="$3"

# The always-required, operator-supplied gateway token secret (dummy value for e2e).
docker secret inspect openclaw_gateway_token >/dev/null 2>&1 \
  || printf 'test' | docker secret create openclaw_gateway_token - >/dev/null

# Pin: label this (single-node) swarm's node so the persistence.nodeLabel constraint
# schedules. Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add openclaw-data=true "$node" >/dev/null

# Shared ingress overlay the traefik/none exposure modes attach to (autoCreate:false in
# requirements.yaml — the operator/traefik chart owns it; here we stand in for them).
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

# --- host-path fixture only: pre-create the bind-mount dirs, writable by the container's
# non-root node user (paths match ci/host-path-values.yaml) --------------------------
if [ "$case" = "host-path" ]; then
  mkdir -p /tmp/openclaw-e2e/data /tmp/openclaw-e2e/auth
  chmod -R 0777 /tmp/openclaw-e2e
fi

# --- backend fixture only: a co-located mock Ollama on its own overlay ---------------
if [ "$case" = "backend" ]; then
  docker network create --driver overlay --attachable ai-internal >/dev/null 2>&1 || true

  # Ship the mock server as a swarm config (no image build needed) and run it on a stock
  # node image, attached to ai-internal so the gateway can reach it as `mock-ollama`.
  docker service rm mock-ollama >/dev/null 2>&1 || true
  docker config rm mock-ollama-js >/dev/null 2>&1 || true
  docker config create mock-ollama-js "$dir/ci/mock-ollama.js" >/dev/null
  docker service create --name mock-ollama --network ai-internal \
    --config source=mock-ollama-js,target=/mock.js \
    node:22-alpine node /mock.js >/dev/null

  # Wait for the mock task to actually run before the chart installs (image pull).
  for _ in $(seq 1 40); do
    state="$(docker service ps mock-ollama --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in Running*) break ;; esac
    sleep 3
  done
fi

# --- edge fixture only: stand up the traefik chart as a REAL edge on traefik-public, so
# ci/e2e-check.sh can prove a request routes THROUGH it to the gateway (shared helper,
# issue #63). Removed again by ci/e2e-teardown.sh. -------------------------------------
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
