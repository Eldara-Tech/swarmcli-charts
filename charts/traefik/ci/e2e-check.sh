#!/usr/bin/env bash
#
# Optional e2e smoke check for the traefik chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# On a bare local swarm we cannot assert real routing: ACME/tlschallenge needs a
# public DNS A-record and reachable :443, and the dashboard needs an FQDN. So the
# smoke check only asserts that Traefik itself scheduled and is Running. Docker
# stack deploy names the service "<release>_traefik".
#
# PREREQUISITE: the chart pins Traefik to the node holding the cert volume via
#   node.labels.traefik-public.traefik-public-certificates == true
# so that label must be set on the test node or the task never schedules:
#   docker node update --label-add traefik-public.traefik-public-certificates=true <node>
set -euo pipefail

release="$1"
service="${release}_traefik"

for _ in $(seq 1 30); do
  state="$(docker service ps "$service" \
    --filter desired-state=running \
    --format '{{.CurrentState}}' 2>/dev/null | head -1)"
  case "$state" in
    Running*) echo "  $service is Running"; exit 0 ;;
    Failed*|Rejected*) echo "  $service task failed: $state"; exit 1 ;;
  esac
  sleep 2
done

echo "  $service did not reach Running (last: ${state:-<none>})"
echo "  hint: is the traefik-public.traefik-public-certificates=true node label set?"
exit 1
