#!/usr/bin/env bash
#
# Optional e2e smoke check for the openclaw chart. scripts/e2e-test.sh runs this after
# the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# It is run once per fixture, so it probes the running gateway container rather than
# assuming a particular exposure mode: it locates the task container for service
# "<release>_gateway" (a local e2e swarm is single-node) and asks node's global fetch to
# hit /healthz from inside the container — the same call the chart's healthcheck uses, so
# it needs neither curl (absent from the image) nor the operator's gateway token.
#
# For the `backend` fixture it additionally proves the model-backend wiring the chart
# README describes, in two stages: (a) the chart's backend.network actually lets the gateway
# reach the co-located backend, and (b) once OpenClaw is pointed at it the CORRECT way
# (config — models.providers.<id>.baseUrl — NOT env), OpenClaw really dials it. This is the
# regression guard for issue #60 (env vars like OLLAMA_HOST do NOT wire the backend).
#
# The mock Ollama backend, the gateway-token secret and the node label are provisioned by
# ci/e2e-setup.sh (and removed by ci/e2e-teardown.sh).
set -euo pipefail

release="$1"
case="${3:-}"

gateway_cid() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_gateway" | head -1; }

# Wait for the gateway HTTP to actually serve. Task "Running" != serving (the image's
# healthcheck has a 120s start period), and an unhealthy task may be replaced under it, so
# re-resolve the container each attempt. Retry for up to ~2.5 min.
ok=0
for _ in $(seq 1 30); do
  cid="$(gateway_cid)"
  if [ -n "$cid" ] && docker exec "$cid" node -e \
      "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      2>/dev/null; then
    ok=1
    break
  fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  echo "  FAIL: ${release}_gateway /healthz never became ready"
  docker service ps "${release}_gateway" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi
cid="$(gateway_cid)"
echo "  ${release}_gateway: /healthz OK"

[ "$case" = "backend" ] || exit 0

# --- backend fixture: prove the gateway reaches the co-located backend ----------------

# (a) Deterministic reachability: backend.network must put the gateway on the ai-internal
#     overlay so it resolves and reaches mock-ollama. This isolates the CHART's wiring from
#     OpenClaw's behaviour; a distinct /probe path so it is never confused with (b)'s calls.
if ! docker exec "$cid" node -e \
    "fetch('http://mock-ollama:11434/probe').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"; then
  echo "  FAIL: gateway cannot reach http://mock-ollama:11434 — backend.network wiring is broken"
  exit 1
fi
echo "  backend: gateway reaches mock-ollama over ai-internal"

# (b) Point OpenClaw at the backend the ONLY supported way — config, not env. Use the exact
#     form the chart's launch wrapper uses: `openclaw config set --batch-json` takes a JSON
#     ARRAY of {path, value} objects (not a nested config object).
cfg='[{"path":"models.providers.ollama.baseUrl","value":"http://mock-ollama:11434"},{"path":"models.providers.ollama.api","value":"ollama"},{"path":"models.providers.ollama.apiKey","value":"test"}]'
if ! out="$(docker exec "$cid" openclaw config set --batch-json "$cfg" 2>&1)"; then
  echo "  FAIL: openclaw config set rejected the ollama provider"
  printf '%s\n' "$out" | sed 's/^/    /'
  exit 1
fi

# (c) Trigger OpenClaw to contact the backend (discovery -> GET /api/tags; a one-shot infer
#     -> /api/chat|/api/generate). Best-effort — the assertion is on what the mock actually
#     received, not these commands' exit codes (their exact flags vary by OpenClaw version).
docker exec "$cid" openclaw models list --provider ollama >/dev/null 2>&1 || true
docker exec "$cid" openclaw models list >/dev/null 2>&1 || true
docker exec "$cid" openclaw infer model run --model ollama/mockllama:latest \
  --prompt 'reply with ok' >/dev/null 2>&1 || true

# (d) Assert the mock recorded an OpenClaw-originated Ollama API call (NOT the /probe above).
for _ in $(seq 1 15); do
  if docker service logs mock-ollama 2>/dev/null \
      | grep -Eq 'MOCK-OLLAMA (GET|POST) /api/(tags|show|chat|generate)'; then
    hit="$(docker service logs mock-ollama 2>/dev/null \
      | grep -E 'MOCK-OLLAMA (GET|POST) /api/' | head -1)"
    echo "  backend: OpenClaw dialed the configured backend (${hit#*MOCK-OLLAMA })"
    exit 0
  fi
  sleep 2
done

echo "  FAIL: OpenClaw did not call the configured backend (mock saw no /api/* request)"
echo "  --- openclaw help (to confirm the discovery/infer subcommands for this version) ---"
docker exec "$cid" openclaw --help 2>&1 | sed 's/^/    /' || true
docker exec "$cid" openclaw models --help 2>&1 | sed 's/^/    /' || true
echo "  --- mock-ollama service logs ---"
docker service logs mock-ollama 2>&1 | tail -20 | sed 's/^/    /' || true
exit 1
