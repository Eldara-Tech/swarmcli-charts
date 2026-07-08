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
    --format '{{.CurrentState}}' 2>/dev/null | head -1)"
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

exit 0
