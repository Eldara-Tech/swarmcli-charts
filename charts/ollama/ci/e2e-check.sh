#!/usr/bin/env bash
#
# Optional e2e smoke check for the ollama chart. scripts/e2e-test.sh runs this after the
# release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# It probes the running server rather than assuming an exposure mode: it locates the task
# container for service "<release>_ollama" (a local e2e swarm is single-node) and runs
# `ollama list` inside it — which talks to the local API and exits 0 once the server is
# serving (an empty model list is fine; we do NOT pull a model — too large/slow for CI).
# The node label / traefik-public / bind dir are provisioned by ci/e2e-setup.sh.
set -euo pipefail

release="$1"
case="${3:-}"

ollama_cid() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_ollama" | head -1; }

# Wait for the API to actually serve. Task "Running" != serving (the image may take a moment
# to start the server), and an unhealthy task may be replaced under us, so re-resolve the
# container each attempt. Retry for up to ~2.5 min.
ok=0
for _ in $(seq 1 30); do
  cid="$(ollama_cid)"
  if [ -n "$cid" ] && docker exec "$cid" ollama list >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  echo "  FAIL: ${release}_ollama API never became ready"
  docker service ps "${release}_ollama" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi
cid="$(ollama_cid)"
echo "  ${release}_ollama: API serving (ollama list OK)"

# --- bind-mount fixture: confirm the model store is a mount at /root/.ollama (persistence
# actually took effect), not the container's ephemeral layer. --------------------------
if [ "$case" = "bind-mount" ]; then
  if docker exec "$cid" sh -c 'grep -q " /root/.ollama " /proc/mounts'; then
    echo "  bind-mount: /root/.ollama is persisted (mounted)"
  else
    echo "  FAIL: /root/.ollama is not mounted — persistence did not take effect"
    exit 1
  fi
fi

# --- edge fixture: prove a request routes THROUGH the stood-up traefik edge to Ollama. The
# in-container check above proved the app serves; now assert it is reachable via the edge
# with a matching Host header, and that an unknown host 404s. ---------------------------
if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed ollama.e2e.test /api/version 200 || exit 1
  edge_assert_unrouted no-such-host.invalid || exit 1
fi

exit 0
