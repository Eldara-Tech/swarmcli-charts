#!/usr/bin/env bash
#
# Shared e2e "edge" capability (issue #63): stand up the in-repo traefik chart as a real
# Swarm edge proxy and assert that HTTP requests actually route THROUGH it to a backend —
# proving the traefik label/discovery contract at RUNTIME, not just as rendered strings
# (the "renders fine, silently 404s/502s at the edge" footgun documented in CLAUDE.md).
#
# It is SOURCED (not executed) by the per-chart ci/e2e-*.sh hooks, so it only defines
# functions and NEVER calls `exit` (that would kill the caller). Every function echoes a
# diagnostic and `return`s non-zero on failure; callers running under `set -e` use
# `edge_… || { …; exit 1; }` where a failure must fail the case.
#
#   openclaw / keycloak `edge` fixture (the routed app is the chart-under-test):
#     setup     -> edge_up                                   (install traefik as the edge)
#     check     -> edge_assert_routed <host> <path> [code]   (a real request reaches the app)
#                  edge_assert_unrouted <host>               (an unknown host 404s — selective)
#     teardown  -> edge_down
#
#   traefik `routing` fixture (traefik IS the chart-under-test the harness installs):
#     setup     -> edge_whoami_up <name> <host> true         (correctly-labelled backend)
#                  edge_whoami_up <name> <host> false        (identical but MISSING the
#                                                             constraint label — the footgun)
#     check     -> EDGE_TARGET=<release>_traefik
#                  edge_assert_routed   <ok-host>  / 200     (labelled backend is routed)
#                  edge_assert_unrouted <bad-host>           (unlabelled backend is never
#                                                             discovered — a faithful 404)
#     teardown  -> edge_whoami_down <name> …
#
# Curls run from a throwaway `--rm` container attached to traefik-public and hit the
# traefik service VIP with an explicit Host header — a bare local swarm has no DNS, and
# the Host header is exactly what drives Traefik's router rules. Plain HTTP only (routed
# apps set ingress.tls:false): real ACME/TLS can't be exercised in CI (no public DNS /
# cert issuance), so this verifies HTTP routing + label discovery, not cert resolution.

# Repo root (this file lives in scripts/e2e-edge/), so paths resolve regardless of CWD.
E2E_EDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

EDGE_RELEASE="${EDGE_RELEASE:-e2e-edge}"            # release name of the stood-up edge
EDGE_TARGET="${EDGE_TARGET:-${EDGE_RELEASE}_traefik}"  # traefik service to curl (overlay VIP)
EDGE_NETWORK="${EDGE_NETWORK:-traefik-public}"      # overlay the edge + backends share
EDGE_CONSTRAINT="${EDGE_CONSTRAINT:-traefik-public}"   # swarm-provider constraint label value
EDGE_WHOAMI_IMAGE="${EDGE_WHOAMI_IMAGE:-ghcr.io/traefik/whoami}"  # tiny routed backend
EDGE_CURL_IMAGE="${EDGE_CURL_IMAGE:-curlimages/curl:latest}"

# Resolve the renderer: the harness (make e2e / e2e.yml) exports SWARMCLI; fall back to
# the built binary, then PATH.
_edge_swarmcli() {
  local s="${SWARMCLI:-}"
  if [ -n "$s" ] && { [ -x "$s" ] || command -v "$s" >/dev/null 2>&1; }; then
    printf '%s' "$s"
  elif [ -x "$E2E_EDGE_ROOT/.swarmcli-bin/swarmcli" ]; then
    printf '%s' "$E2E_EDGE_ROOT/.swarmcli-bin/swarmcli"
  else
    printf 'swarmcli'
  fi
}

# The local swarm node (single-node in e2e), same resolution the traefik chart's own hook
# uses for its cert-volume pin.
_edge_node() {
  local n
  n="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
  [ -n "$n" ] || n="$(docker node ls -q 2>/dev/null | sed -n 1p)"
  printf '%s' "$n"
}

# Curl the edge (traefik VIP) over the overlay with a Host header; prints the HTTP status
# code (000 if the connection never completed). $1 = Host header, $2 = request path.
_edge_curl() {
  docker run --rm --network "$EDGE_NETWORK" "$EDGE_CURL_IMAGE" \
    -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: $1" "http://${EDGE_TARGET}:80$2" 2>/dev/null || true
}

# Stand up the traefik chart as the edge and wait until it is Running AND serving on :80.
edge_up() {
  local sc node out state code
  sc="$(_edge_swarmcli)"

  # Idempotent: clear any edge a crashed run left behind before re-installing. This MUST
  # come before labelling the node below — edge_down removes the traefik-certs label, so
  # labelling first would strip the very label the install needs and the task would stay
  # Pending ("scheduling constraints not satisfied").
  edge_down >/dev/null 2>&1 || true

  # Traefik's default placement pins it to the node holding the ACME cert volume via
  # node.labels.traefik-certs == true, so that label must exist or the task never
  # schedules (the same pin the traefik chart's own ci/e2e-setup.sh sets).
  node="$(_edge_node)"
  [ -n "$node" ] && docker node update --label-add traefik-certs=true "$node" >/dev/null

  # Install the in-repo traefik chart as the edge. Dashboard off drops the otherwise
  # required dashboard.host; a dummy ACME email keeps the resolver well-formed (no cert is
  # ever requested — routed apps use plain HTTP — so ACME stays dormant). Default :80/:443
  # host ports are kept (already proven on CI runners by the traefik chart's own e2e).
  echo "   edge: installing traefik chart as release '$EDGE_RELEASE'"
  if ! out="$("$sc" charts install "$EDGE_RELEASE" "$E2E_EDGE_ROOT/charts/traefik" \
      --set traefik.dashboard.enabled=false \
      --set traefik.acme.email=admin@example.com 2>&1)"; then
    echo "   FAIL: edge traefik install was rejected"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
  fi
  EDGE_TARGET="${EDGE_RELEASE}_traefik"

  for _ in $(seq 1 40); do
    state="$(docker service ps "${EDGE_RELEASE}_traefik" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in
      Running*)
        # Any non-000 code means the entrypoint is serving (a 404 for this unknown host
        # is a perfectly healthy "up and routing" response).
        code="$(_edge_curl edge-ping.invalid /)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then
          echo "   edge: traefik is Running and serving on :80 (probe HTTP $code)"
          return 0
        fi ;;
      Failed*|Rejected*)
        echo "   FAIL: edge traefik task failed: $state"; return 1 ;;
    esac
    sleep 3
  done
  echo "   FAIL: edge traefik did not come up on :80 (last state: ${state:-<none>})"
  docker service ps "${EDGE_RELEASE}_traefik" --no-trunc 2>/dev/null | sed 's/^/      /' || true
  return 1
}

# Remove the stood-up edge and its cert-volume node label. Leaves the shared overlay.
edge_down() {
  local sc node
  sc="$(_edge_swarmcli)"
  "$sc" charts uninstall "$EDGE_RELEASE" --purge-volumes >/dev/null 2>&1 || true
  node="$(_edge_node)"
  [ -n "$node" ] && docker node update --label-rm traefik-certs "$node" >/dev/null 2>&1 || true
  return 0
}

# Assert a request for <host><path> is routed through the edge and returns <code> (default
# 200). Retries ~90s: the backend may still be warming up and Traefik discovery has a lag.
edge_assert_routed() {
  local host="$1" path="$2" want="${3:-200}" code
  for _ in $(seq 1 30); do
    code="$(_edge_curl "$host" "$path")"
    if [ "$code" = "$want" ]; then
      echo "   edge: Host($host)$path routed through the edge -> HTTP $code"
      return 0
    fi
    sleep 3
  done
  echo "   FAIL: Host($host)$path never returned $want through the edge (last: ${code:-<none>})"
  return 1
}

# Assert <host> is NOT routed (no matching/discovered router) — the edge returns 404.
# Single-shot: an undiscovered host is 404 immediately (no warm-up to wait on). Call it
# AFTER a positive edge_assert_routed so Traefik has completed a discovery cycle.
edge_assert_unrouted() {
  local host="$1" path="${2:-/}" code
  code="$(_edge_curl "$host" "$path")"
  if [ "$code" = "404" ]; then
    echo "   edge: Host($host) is undiscovered at the edge -> HTTP 404 (as expected)"
    return 0
  fi
  echo "   FAIL: Host($host) expected 404 at the edge but got ${code:-<none>}"
  return 1
}

# Stand up a throwaway whoami backend on the edge overlay, carrying the routed-service
# label contract. $1 = service name, $2 = router Host, $3 = "true" to include the
# constraint label / "false" to omit it (the ONLY delta that decides discovery — the #63
# footgun: without it, exposedByDefault=false + the provider constraint hide the service).
edge_whoami_up() {
  local name="$1" host="$2" want_constraint="$3" rule="Host(\`$2\`)" state
  local labels=(
    --label "traefik.enable=true"
    --label "traefik.swarm.network=$EDGE_NETWORK"
    --label "traefik.http.routers.$name.rule=$rule"
    --label "traefik.http.routers.$name.entrypoints=http"
    --label "traefik.http.services.$name.loadbalancer.server.port=80"
  )
  [ "$want_constraint" = "true" ] && labels+=( --label "traefik.constraint-label=$EDGE_CONSTRAINT" )

  # Ensure the shared overlay exists before attaching: this may run in a setup hook BEFORE
  # the chart-under-test install that would auto-create it. Idempotent — swarmcli reuses an
  # already-present traefik-public at install time. (Matches the openclaw/keycloak setups.)
  docker network create --driver overlay --attachable "$EDGE_NETWORK" >/dev/null 2>&1 || true

  docker service rm "$name" >/dev/null 2>&1 || true
  docker service create --name "$name" --network "$EDGE_NETWORK" \
    "${labels[@]}" "$EDGE_WHOAMI_IMAGE" >/dev/null

  for _ in $(seq 1 40); do
    state="$(docker service ps "$name" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in
      Running*) echo "   edge: backend '$name' Running (constraint-label: $want_constraint)"; return 0 ;;
      Failed*|Rejected*) echo "   FAIL: backend '$name' task failed: $state"; return 1 ;;
    esac
    sleep 3
  done
  echo "   FAIL: backend '$name' did not reach Running (last: ${state:-<none>})"
  return 1
}

# Remove a throwaway whoami backend created by edge_whoami_up.
edge_whoami_down() {
  docker service rm "$1" >/dev/null 2>&1 || true
  return 0
}
