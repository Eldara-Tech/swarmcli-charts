#!/usr/bin/env bash
#
# Deploy every chart against its ci/*-values.yaml fixtures to a LIVE local
# Docker Swarm, assert the services converge, run an optional per-chart smoke
# check, then always tear the release back down. This is the real end-to-end
# loop that complements the data-only scripts/test-charts.sh (== CI).
#
# It needs a running Swarm and pulls/starts real containers, so it is heavier than
# test-charts.sh. The e2e.yml workflow runs it on a throwaway single-node swarm
# (E2E_SWARM_INIT=1) for the charts that ship CI-provisionable setup; the full local
# `make e2e` sweep across every chart stays local. See docs/e2e-testing.md.
#
# Per chart, per fixture:
#   0. setup     -> run charts/<chart>/ci/e2e-setup.sh if present (optional) — provision
#                   external prerequisites swarmcli won't (secrets, node labels, a backend)
#   1. install   -> swarmcli charts install <release> <chart> (deploy the stack)
#   2. converge  -> poll until every desired task ACTUALLY reaches Running
#   3. smoke     -> run charts/<chart>/ci/e2e-check.sh if present (optional)
#   4. teardown  -> swarmcli uninstall --purge-volumes + ci/e2e-teardown.sh (always)
#
# We intentionally do NOT use swarmcli's `--wait`: its convergence check counts
# tasks whose *desired* state is Running, which Swarm satisfies the instant a
# service is created — so `--wait` returns while tasks are still Pending/pulling.
# Step 2 polls the *actual* task state (`docker stack ps`) instead.
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/e2e-test.sh [chart ...]
#   Defaults to all charts under charts/*.
#   Env: E2E_TIMEOUT     convergence budget per release, simple duration like
#                        3m / 90s / 1h (default 3m)
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

# Convert a simple Go-style duration (3m / 90s / 1h / bare seconds) to seconds.
dur_to_secs() {
  case "$1" in
    *h) printf '%s' "$(( ${1%h} * 3600 ))" ;;
    *m) printf '%s' "$(( ${1%m} * 60 ))" ;;
    *s) printf '%s' "$(( ${1%s} ))" ;;
    *)  printf '%s' "$(( $1 ))" ;;
  esac
}

# Tear a fixture down: remove the release stack, then run the chart's optional
# ci/e2e-teardown.sh to clean up whatever ci/e2e-setup.sh provisioned OUTSIDE the
# stack (external secrets, node labels, a backend service/overlay). Best-effort so a
# partial setup still gets cleaned. Stack first, so the hook can then free its network.
teardown_case() {  # $1 release  $2 chart-dir  $3 case
  "$SWARMCLI" charts uninstall "$1" --purge-volumes >/dev/null 2>&1 || true
  if [ -x "$2/ci/e2e-teardown.sh" ]; then
    "$2/ci/e2e-teardown.sh" "$1" "$2" "$3" >/dev/null 2>&1 || true
  fi
}

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

    # Pre-clean any leftover from a previous crashed run (stack + external setup).
    teardown_case "$release" "$dir" "$case"

    # Optional per-chart setup: provision external prerequisites this fixture needs
    # that swarmcli does NOT create (external secrets, node labels, a co-located
    # backend service/overlay) — swarmcli's requirements pre-flight fails the install
    # otherwise. Runs before install; a non-zero exit fails the case.
    if [ -x "$dir/ci/e2e-setup.sh" ]; then
      echo "   setup: ci/e2e-setup.sh"
      if ! "$dir/ci/e2e-setup.sh" "$release" "$dir" "$case"; then
        echo "   FAIL: setup hook"
        teardown_case "$release" "$dir" "$case"
        fail=1
        continue
      fi
    fi

    # Deploy (no --wait — see header). A non-zero exit means docker stack deploy
    # itself was rejected (bad manifest, failed pre-flight, …).
    if ! out="$("$SWARMCLI" charts install "$release" "./$dir" -f "$vf" 2>&1)"; then
      echo "   FAIL: install was rejected"
      printf '%s\n' "$out" | sed 's/^/      /'
      teardown_case "$release" "$dir" "$case"
      fail=1
      continue
    fi

    ok=0

    # Poll until every task whose desired state is Running ACTUALLY reads
    # Running (image pulls take time), or the budget runs out.
    deadline=$(( $(date +%s) + $(dur_to_secs "$TIMEOUT") ))
    while :; do
      states="$(docker stack ps "$release" --filter desired-state=running \
        --format '{{.CurrentState}}' 2>/dev/null || true)"
      if [ -n "$states" ] && ! printf '%s\n' "$states" | grep -vq '^Running'; then
        ok=1
        break
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        break
      fi
      sleep 3
    done
    if [ "$ok" -ne 1 ]; then
      echo "   FAIL: services did not all reach Running within $TIMEOUT"
      docker stack ps "$release" --no-trunc 2>/dev/null | sed 's/^/      /' || true
    fi

    # Optional per-chart smoke check (gets the case name so it can assert
    # fixture-specific behaviour, e.g. the backend fixture's backend reachability).
    if [ "$ok" -eq 1 ] && [ -x "$dir/ci/e2e-check.sh" ]; then
      echo "   smoke: ci/e2e-check.sh"
      if ! "$dir/ci/e2e-check.sh" "$release" "$dir" "$case"; then
        echo "   FAIL: smoke check"
        ok=0
      fi
    fi

    # Always tear the release down (stack + external setup) before recording the verdict.
    teardown_case "$release" "$dir" "$case"

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
