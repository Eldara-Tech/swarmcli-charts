#!/usr/bin/env bash
#
# e2e smoke check for the loki chart. scripts/e2e-test.sh runs this after the release
# converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# A converged task proves the process started, which for Loki proves almost nothing: a
# misconfigured store, a schema Loki refuses to write to or a compactor that cannot open
# its working directory all show up on the FIRST WRITE, not at boot. So every fixture does
# the round trip that is the whole point of the chart — POST a line to /loki/api/v1/push,
# then read it back out of /loki/api/v1/query_range — and the shipper fixture additionally
# waits for a line nobody pushed by hand: one Alloy collected from a real container.
#
# How Loki is reached depends on the fixture, which is also what is under test:
#   published-ish  -> the host, through the routing mesh on 127.0.0.1:3100
#   none           -> a throwaway curl container on the `monitoring` overlay, as a
#                     neighbouring stack would (service DNS, no published port anywhere)
#   edge           -> through the traefik chart, where an unauthenticated request must be
#                     REFUSED by the basic-auth middleware before an authenticated one works
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${LOKI_E2E_CURL_IMAGE:-curlimages/curl:latest}"
net=""
base=""
extra=()

case "$case" in
  default|shipper|retention-off)
    # exposure.mode: none — reached exactly as a neighbouring stack reaches it, by service
    # DNS on the shared overlay. That the name resolves at all is a chart property.
    net=monitoring
    base="http://loki:3100"
    ;;
  edge)
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
    net="${EDGE_NETWORK}"
    base="http://${EDGE_TARGET}"
    extra=(-H "Host: loki.e2e.test" -u "e2e:e2e-secret")
    ;;
  *)
    # The published fixtures. NOT probed through the published port: a swarm ingress port
    # is reachable on the node, and on a Docker-in-VM host (colima, Docker Desktop) the
    # node is the VM — so a host curl passes on a Linux runner and times out on a
    # developer's laptop, which is the worst shape a check can have. The port publish
    # itself is asserted separately below, from the daemon; the round trip runs in the
    # Loki container's own network namespace, which behaves identically everywhere.
    net=""
    base="http://127.0.0.1:3100"
    ;;
esac

loki_cid() {
  docker ps -q -f "label=com.docker.swarm.service.name=${release}_loki" | sed -n 1p
}

# One call shape for every fixture: a throwaway curl container, either on a network Loki is
# on or inside its network namespace. Re-resolving the container each call matters — a task
# that is replaced under us would otherwise leave every later probe talking to a dead
# namespace. The array expansion is written the long way so an empty `extra` does not trip
# `set -u` on bash 3.2.
api() {
  local netarg="$net"
  if [ -z "$netarg" ]; then
    local cid
    cid="$(loki_cid)"
    [ -n "$cid" ] || return 1
    netarg="container:$cid"
  fi
  docker run --rm --network "$netarg" "$CURL_IMAGE" -sS --max-time 15 ${extra[@]+"${extra[@]}"} "$@"
}

diagnose() {
  echo "  --- diagnostics ---"
  docker service ps "${release}_loki" --no-trunc 2>/dev/null | sed -n '1,6p' | sed 's/^/    /' || true
  docker service logs --tail 30 "${release}_loki" 2>&1 | sed 's/^/    /' || true
}

# --- the edge fixture proves the middleware BEFORE anything else: a request that reaches
# Loki unauthenticated would make every assertion below meaningless. -------------------
if [ "$case" = "edge" ]; then
  edge_assert_routed loki.e2e.test /ready 401 || { diagnose; exit 1; }
fi

# --- the published fixtures publish a port: ask the daemon what it accepted, since the
# round trip below deliberately does not travel through it. -----------------------------
case "$case" in
  default|shipper|retention-off|edge) ;;
  *)
    if ! docker service inspect "${release}_loki" \
        --format '{{range .Endpoint.Ports}}{{.PublishMode}}:{{.PublishedPort}}->{{.TargetPort}} {{end}}' 2>/dev/null \
        | grep -F 'ingress:3100->3100' >/dev/null; then
      echo "  FAIL: ${release}_loki does not publish 3100 on the routing mesh"
      docker service inspect "${release}_loki" --format '{{json .Endpoint.Ports}}' 2>&1 | sed 's/^/    /'
      exit 1
    fi
    echo "  ${release}_loki: port 3100 published (ingress)"
    ;;
esac

# --- readiness. /ready is 503 until Loki has joined its own ring and opened the store. --
ready=0
for _ in $(seq 1 40); do
  code="$(api -o /dev/null -w '%{http_code}' "$base/ready" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    ready=1
    break
  fi
  sleep 3
done
if [ "$ready" -ne 1 ]; then
  echo "  FAIL: ${release}_loki never became ready at $base/ready (last code: ${code:-<none>})"
  diagnose
  exit 1
fi
echo "  ${release}_loki: /ready OK"

# --- write. A push Loki accepts is a 204; anything else (400 schema, 500 store) is the
# failure this check exists to catch. --------------------------------------------------
now="$(date +%s)"
marker="loki-chart-e2e-${case}-${now}"
body="{\"streams\":[{\"stream\":{\"job\":\"e2e\",\"case\":\"${case}\"},\"values\":[[\"${now}000000000\",\"${marker}\"]]}]}"
code="$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -X POST --data-binary "$body" "$base/loki/api/v1/push" 2>/dev/null || true)"
if [ "$code" != "204" ]; then
  echo "  FAIL: push to $base/loki/api/v1/push returned ${code:-<none>}, want 204"
  diagnose
  exit 1
fi

# --- read it back. The window is deliberately wide: the fixture's clock and the swarm's
# need not agree to the second. --------------------------------------------------------
query_for() {
  api -G "$base/loki/api/v1/query_range" \
    --data-urlencode "query=$1" \
    --data-urlencode "start=$((now - 3600))000000000" \
    --data-urlencode "end=$((now + 3600))000000000" \
    --data-urlencode "limit=100" 2>/dev/null || true
}

found=0
for _ in $(seq 1 10); do
  if query_for '{job="e2e"}' | grep -F "$marker" >/dev/null; then
    found=1
    break
  fi
  sleep 3
done
if [ "$found" -ne 1 ]; then
  echo "  FAIL: the pushed line never came back out of query_range"
  diagnose
  exit 1
fi
echo "  ${release}_loki: push -> query_range round trip OK"

# --- shipper fixture: a line NOBODY pushed. Alloy discovers containers every 15s and this
# is a cold start, so allow ~2 minutes. The stream asserted on is Loki's own service,
# which is logging steadily, and the label proves the Swarm relabelling worked — a
# shipper that forwarded with no service label would pass a bare "any lines?" check. ----
if [ "$case" = "shipper" ]; then
  shipped=0
  for _ in $(seq 1 40); do
    if query_for "{service=\"${release}_loki\"}" | grep -F '"values"' >/dev/null; then
      shipped=1
      break
    fi
    sleep 3
  done
  if [ "$shipped" -ne 1 ]; then
    echo "  FAIL: no container logs arrived from the Alloy shipper for service ${release}_loki"
    docker service ps "${release}_alloy" --no-trunc 2>/dev/null | sed -n '1,6p' | sed 's/^/    /' || true
    docker service logs --tail 40 "${release}_alloy" 2>&1 | sed 's/^/    /' || true
    diagnose
    exit 1
  fi
  echo "  ${release}_alloy: container logs arrived labelled service=${release}_loki"
fi
