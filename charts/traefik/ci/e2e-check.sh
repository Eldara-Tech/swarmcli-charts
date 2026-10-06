#!/usr/bin/env bash
#
# Optional e2e smoke check for the traefik chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# For most fixtures we cannot assert real TLS routing on a bare swarm (ACME/tlschallenge
# needs a public DNS A-record and reachable :443, the dashboard needs an FQDN), so the
# check only asserts Traefik itself scheduled and is Running (service "<release>_traefik").
# The `routing` fixture goes further: ci/e2e-setup.sh stands up a labelled and an
# unlabelled whoami backend, and this check asserts the labelled one routes through the
# edge (200) while the unlabelled one is never discovered (404) — issue #63.
#
# PREREQUISITE: the chart pins Traefik to the node holding the cert volume via
#   node.labels.traefik-certs == true
# so that label must be set on the test node or the task never schedules:
#   docker node update --label-add traefik-certs=true <node>
set -euo pipefail

release="$1"
service="${release}_traefik"

up=0
for _ in $(seq 1 30); do
  state="$(docker service ps "$service" \
    --filter desired-state=running \
    --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
  case "$state" in
    Running*) echo "  $service is Running"; up=1; break ;;
    Failed*|Rejected*) echo "  $service task failed: $state"; exit 1 ;;
  esac
  sleep 2
done

if [ "$up" != 1 ]; then
  echo "  $service did not reach Running (last: ${state:-<none>})"
  echo "  hint: is the traefik-certs=true node label set?"
  exit 1
fi

# Discovery is opt-in: the `metrics` fixture's service must carry the scrape label, and
# no other fixture's may.
scrape="$(docker service inspect "$service" --format '{{index .Spec.Labels "prometheus.io/scrape"}}')"
if [ "${3:-}" = "metrics" ]; then
  [ "$scrape" = "true" ] || { echo "  $service lacks prometheus.io/scrape=true in the metrics fixture"; exit 1; }
else
  [ -z "$scrape" ] || { echo "  $service carries prometheus.io/scrape=$scrape although metrics are off"; exit 1; }
fi

# --- routing fixture: prove Traefik actually ROUTES through the edge, and that the
# constraint-label gate works — the labelled backend is reached (200) while the copy
# missing ONLY that label is never discovered (404). The backends are stood up by
# ci/e2e-setup.sh (issue #63). ----------------------------------------------------------
case="${3:-}"
if [ "$case" = "routing" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  EDGE_TARGET="$service"   # the harness's traefik release is the edge here
  edge_assert_routed   whoami-ok.e2e.test  / 200 || exit 1
  edge_assert_unrouted whoami-bad.e2e.test       || exit 1
fi

# --- metrics fixture: the dashboard's basic auth works from the users SECRET (401
# without credentials, 200 with them), and Prometheus — standing in a container on the
# monitoring overlay — scrapes /metrics from the dedicated entrypoint and sees the
# requests just made counted on the https entrypoint. The metrics port must not be
# published. ----------------------------------------------------------------------------
if [ "$case" = "metrics" ]; then
  CURL_IMAGE="${TRAEFIK_E2E_CURL_IMAGE:-curlimages/curl:latest}"
  dash() {
    docker run --rm --network traefik-public "$CURL_IMAGE" -sk -o /dev/null -w '%{http_code}' \
      --max-time 10 --connect-to "traefik.e2e.test:443:${service}:443" "$@" \
      https://traefik.e2e.test/dashboard/ 2>/dev/null || true
  }
  anon=""; authed=""
  for _ in $(seq 1 30); do
    anon="$(dash)"; authed="$(dash -u e2e:e2e-pass)"
    [ "$anon" = 401 ] && [ "$authed" = 200 ] && break
    sleep 2
  done
  [ "$anon" = 401 ] || { echo "  dashboard without credentials returned '$anon', expected 401"; exit 1; }
  [ "$authed" = 200 ] || { echo "  dashboard with the secret's credentials returned '$authed', expected 200"; exit 1; }
  echo "  dashboard: 401 without credentials, 200 with the users from the secret"

  m=""
  for _ in $(seq 1 15); do
    m="$(docker run --rm --network monitoring "$CURL_IMAGE" -sSf --max-time 10 "http://${service}:8082/metrics" 2>&1 || true)"
    grep -E '^traefik_entrypoint_requests_total\{.*entrypoint="https".*\} [1-9]' <<<"$m" >/dev/null && break
    sleep 2
  done
  if ! grep -E '^traefik_entrypoint_requests_total\{.*entrypoint="https".*\} [1-9]' <<<"$m" >/dev/null; then
    echo "  no traefik_entrypoint_requests_total for the https entrypoint on monitoring. Scrape:"
    grep -E '^traefik_|^curl' <<<"$m" | sed -n '1,10p' | sed 's/^/    /'
    exit 1
  fi
  series="$(grep -c '^traefik_' <<<"$m" || true)"
  echo "  /metrics on monitoring: $series traefik_* samples, https entrypoint requests counted"

  pub="$(docker service inspect "$service" --format '{{range .Endpoint.Ports}}{{.TargetPort}} {{end}}')"
  for p in $pub; do
    [ "$p" != 8082 ] || { echo "  the metrics port 8082 is published"; exit 1; }
  done
fi

exit 0
