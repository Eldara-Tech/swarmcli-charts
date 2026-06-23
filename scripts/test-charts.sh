#!/usr/bin/env bash
#
# Render every chart against its ci/*-values.yaml fixtures and validate the
# output. This is the single source of truth shared by `make test` and the
# charts.yml workflow — green locally means green in CI.
#
# Per chart, per fixture:
#   1. swarmcli charts template   -> must render (exit 0, valid Swarm stack)
#   2. no-'<no value>' guard      -> catch silent missing-key typos (swarmcli
#                                    does not render in strict mode)
#   3. docker compose config      -> structural validity beyond swarmcli's check
#   4. scripts/security-scan.sh   -> flag unacknowledged risky primitives
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/test-charts.sh [chart ...]
#   Defaults to all charts under charts/*. Rendered output is written to
#   .rendered/<chart>__<case>.yaml for inspection and CI artifact upload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWARMCLI="${SWARMCLI:-swarmcli}"
RELEASE="${RELEASE:-ci}"
OUT="$ROOT/.rendered"

charts=("$@")
if [ "${#charts[@]}" -eq 0 ]; then
  for d in charts/*/; do charts+=("$(basename "$d")"); done
fi

rm -rf "$OUT"
mkdir -p "$OUT"
fail=0

for chart in "${charts[@]}"; do
  dir="charts/$chart"
  if [ ! -d "$dir" ]; then
    echo "ERROR: $dir not found"
    fail=1
    continue
  fi

  fixtures=()
  while IFS= read -r f; do fixtures+=("$f"); done \
    < <(find "$dir/ci" -maxdepth 1 -name '*-values.yaml' 2>/dev/null | sort)
  if [ "${#fixtures[@]}" -eq 0 ]; then
    echo "ERROR: $chart has no ci/*-values.yaml fixture (add at least ci/default-values.yaml)"
    fail=1
    continue
  fi

  for vf in "${fixtures[@]}"; do
    case="$(basename "$vf" -values.yaml)"
    out="$OUT/${chart}__${case}.yaml"
    err="$out.err"
    echo "── $chart [$case]"

    if ! "$SWARMCLI" charts template "$RELEASE" "./$dir" -f "$vf" >"$out" 2>"$err"; then
      echo "   RENDER FAILED"
      sed 's/^/      /' "$err"
      fail=1
      continue
    fi
    if grep -nF '<no value>' "$out"; then
      echo "   FAIL: '<no value>' in output — likely a missing-key typo in the template"
      fail=1
      continue
    fi
    if ! docker compose -f "$out" config -q >"$err" 2>&1; then
      echo "   FAIL: docker compose rejected the rendered stack"
      sed 's/^/      /' "$err"
      fail=1
      continue
    fi
    if ! scripts/security-scan.sh "$out" "$dir"; then
      fail=1
      continue
    fi
    echo "   OK"
  done
done

rm -f "$OUT"/*.err 2>/dev/null || true
if [ "$fail" -eq 0 ]; then
  echo "All charts passed."
else
  echo "FAILURES detected."
  exit 1
fi
