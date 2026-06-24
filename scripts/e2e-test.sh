#!/usr/bin/env bash
#
# Deploy every chart against its ci/*-values.yaml fixtures to a LIVE local
# Docker Swarm, assert the services converge, run an optional per-chart smoke
# check, then always tear the release back down. This is the real end-to-end
# loop that complements the data-only scripts/test-charts.sh (== CI).
#
# Unlike test-charts.sh, this is LOCAL-ONLY and is deliberately NOT run by CI:
# it needs a running Swarm and pulls/starts real containers. See
# docs/e2e-testing.md.
#
# Per chart, per fixture:
#   1. install   -> swarmcli charts install <release> <chart> --wait (must converge)
#   2. converge  -> every desired `docker stack ps` task must be Running
#   3. smoke     -> run charts/<chart>/ci/e2e-check.sh if present (optional)
#   4. teardown  -> swarmcli charts uninstall <release> --purge-volumes (always)
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/e2e-test.sh [chart ...]
#   Defaults to all charts under charts/*.
#   Env: E2E_TIMEOUT     convergence wait per release (default 3m)
#        E2E_SWARM_INIT  set to 1 to `docker swarm init` if no swarm is active
#
# Note: swarmcli auto-creates external attachable overlays (e.g. traefik-public)
# at install time per a chart's requirements.yaml. Uninstall leaves those shared
# networks in place (they are harmless); see docs/e2e-testing.md for cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWARMCLI="${SWARMCLI:-swarmcli}"
TIMEOUT="${E2E_TIMEOUT:-3m}"

# --- preflight: a live swarm manager is required -----------------------------
state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
if [ "$state" != "active" ]; then
  if [ "${E2E_SWARM_INIT:-}" = "1" ]; then
    echo "No active swarm; E2E_SWARM_INIT=1 -> docker swarm init"
    docker swarm init >/dev/null
  else
    echo "ERROR: this host is not a Docker Swarm manager (Swarm: ${state:-unknown})."
    echo "       Run 'docker swarm init' first (a single node is enough), or set"
    echo "       E2E_SWARM_INIT=1 to let this script initialise a throwaway swarm."
    exit 2
  fi
fi

charts=("$@")
if [ "${#charts[@]}" -eq 0 ]; then
  for d in charts/*/; do charts+=("$(basename "$d")"); done
fi

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
    release="$(printf 'e2e-%s-%s' "$chart" "$case" \
      | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    echo "── $chart [$case]  (release: $release)"

    # Pre-clean any leftover from a previous crashed run.
    "$SWARMCLI" charts uninstall "$release" --purge-volumes >/dev/null 2>&1 || true

    if ! "$SWARMCLI" charts install "$release" "./$dir" -f "$vf" \
        --wait --timeout "$TIMEOUT"; then
      echo "   FAIL: install did not converge within $TIMEOUT"
      "$SWARMCLI" charts status "$release" 2>/dev/null | sed 's/^/      /' || true
      "$SWARMCLI" charts uninstall "$release" --purge-volumes >/dev/null 2>&1 || true
      fail=1
      continue
    fi

    ok=1

    # Belt-and-braces convergence assertion beyond --wait: every task whose
    # desired state is running must actually be Running right now.
    states="$(docker stack ps "$release" --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null || true)"
    if [ -z "$states" ] || printf '%s\n' "$states" | grep -vq '^Running'; then
      echo "   FAIL: services did not all reach Running"
      printf '%s\n' "$states" | sed 's/^/      /'
      ok=0
    fi

    # Optional per-chart smoke check.
    if [ "$ok" -eq 1 ] && [ -x "$dir/ci/e2e-check.sh" ]; then
      echo "   smoke: ci/e2e-check.sh"
      if ! "$dir/ci/e2e-check.sh" "$release" "$dir"; then
        echo "   FAIL: smoke check"
        ok=0
      fi
    fi

    # Always tear the release down before recording the verdict.
    "$SWARMCLI" charts uninstall "$release" --purge-volumes >/dev/null 2>&1 || true

    if [ "$ok" -eq 1 ]; then
      echo "   OK"
    else
      fail=1
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  echo "All charts deployed, converged, and tore down cleanly."
else
  echo "E2E FAILURES detected."
  exit 1
fi
