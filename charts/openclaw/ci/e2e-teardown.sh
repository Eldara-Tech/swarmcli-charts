#!/usr/bin/env bash
#
# e2e teardown for the openclaw chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes everything ci/e2e-setup.sh created (the gateway-token secret, the node label,
# and — for the backend fixture — the mock Ollama service, its config, and the ai-internal
# overlay). The shared traefik-public overlay is intentionally LEFT in place (other charts'
# releases share it and it is harmless), matching scripts/e2e-test.sh's own note.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"

# Remove the traefik edge the edge fixture stood up (issue #63); leaves traefik-public.
if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

if [ "$case" = "backend" ]; then
  docker service rm mock-ollama >/dev/null 2>&1 || true
  docker config rm mock-ollama-js >/dev/null 2>&1 || true
  # The overlay can linger "in use" for a moment after the services detach; retry a few.
  for _ in $(seq 1 10); do
    docker network rm ai-internal >/dev/null 2>&1 && break
    sleep 1
  done
fi

if [ "$case" = "host-path" ]; then
  rm -rf /tmp/openclaw-e2e >/dev/null 2>&1 || true
fi

docker secret rm openclaw_gateway_token >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-rm openclaw-data "$node" >/dev/null 2>&1 || true

exit 0
