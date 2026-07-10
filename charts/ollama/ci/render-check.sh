#!/usr/bin/env bash
#
# Render-time assertions for the ollama chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test on
# a GPU-less runner — this is the "dedicated GPU test".
#
# The gpu case is the point: Docker SWARM schedules a GPU via a generic-resources
# reservation, NOT the Compose `deploy.resources.reservations.devices` / `driver: nvidia`
# form — that renders fine but is a SILENT no-op under `docker stack deploy` (Ollama would
# quietly run on CPU). This asserts the chart emits the Swarm-native form and never the
# no-op one, so a regression to `devices:` fails here rather than in production.
set -euo pipefail

out="$1"
case="${2:-}"

[ "$case" = "gpu" ] || exit 0   # only the gpu fixture carries a GPU reservation

fail=0

# Must emit the Swarm generic-resources reservation with the requested kind/value.
grep -q 'generic_resources:'                "$out" || { echo "  FAIL(gpu): no generic_resources block";      fail=1; }
grep -q 'discrete_resource_spec:'           "$out" || { echo "  FAIL(gpu): no discrete_resource_spec";       fail=1; }
grep -Eq 'kind:[[:space:]]*"?NVIDIA-GPU"?'  "$out" || { echo "  FAIL(gpu): reservation kind not NVIDIA-GPU"; fail=1; }
grep -Eq 'value:[[:space:]]*[1-9][0-9]*'    "$out" || { echo "  FAIL(gpu): no positive reservation value";   fail=1; }

# Must NOT emit the Compose devices/nvidia form (a no-op under docker stack deploy).
if grep -Eq '^[[:space:]]*devices:|driver:[[:space:]]*"?nvidia"?|capabilities:[[:space:]]*\[?.*gpu' "$out"; then
  echo "  FAIL(gpu): found the no-op devices/nvidia GPU form — Swarm ignores it; use generic_resources"
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "  gpu: Swarm generic_resources reservation present (no no-op devices form)"
