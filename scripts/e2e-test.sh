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
#   1. install   -> swarmcli charts install <release> <chart> --wait (deploy AND converge)
#   2. smoke     -> run charts/<chart>/ci/e2e-check.sh if present (optional)
#   3. teardown  -> swarmcli uninstall --purge-volumes + ci/e2e-teardown.sh (always)
#
# Convergence is swarmcli's `--wait`, not a hand-rolled `docker stack ps` poll.
# This script used to avoid it because `--wait` counted tasks by *desired* state,
# which Swarm satisfies the instant a service is created — so it returned while
# tasks were still Pending/pulling. That was fixed in Eldara-Tech/swarmcli#473,
# and a completed one-shot service stopped hanging it in #443, so the poll was
# reimplementing a working feature and testing nothing.
#
# NOTE this needs swarmcli >= v1.13.0-rc4. CI is fine either way (PR workflows
# build `main`, nightly runs the pinned release), but `make e2e` against an older
# locally installed binary will not converge one-shot services.
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/e2e-test.sh [chart ...]
#   Defaults to all charts under charts/*.
#   Env: E2E_TIMEOUT     convergence budget per release, simple duration like
#                        3m / 90s / 1h (default 3m)
#        E2E_SWARM_INIT  set to 1 to `docker swarm init` if no swarm is active
#        E2E_CASES       space/comma-separated fixture case names to run (default: all)
#
# A chart may mark render-only fixtures (value combinations meant for scripts/test-charts.sh
# but not deployable in a normal environment — e.g. a GPU reservation that needs special
# hardware) by listing their case names, one per line, in charts/<chart>/ci/e2e-render-only.
# Those cases are skipped by the default all-fixtures sweep and only run when named
# explicitly in E2E_CASES (so someone with the hardware can still exercise them).
#
# Note: swarmcli auto-creates external attachable overlays (e.g. traefik-public)
# at install time per a chart's requirements.yaml. Uninstall leaves those shared
# networks in place (they are harmless); see docs/e2e-testing.md for cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWARMCLI="${SWARMCLI:-swarmcli}"
TIMEOUT="${E2E_TIMEOUT:-3m}"

# Optional per-chart fixture-case filter. E2E_CASES is a comma/space-separated list of
# case names (the <case> in ci/<case>-values.yaml). Set => only those fixtures run;
# unset/empty => every fixture runs (the `make e2e` default). CI passes a curated subset
# per chart (dropping fixtures that need a host plugin or a second DB engine).
CASES="${E2E_CASES:-}"; CASES="${CASES//,/ }"

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

  # Every hook below is invoked behind `[ -x ]`, so one committed without its execute
  # bit is not run and nothing says so. For e2e-check.sh that is the worst shape a
  # check can take: the fixture converges, no smoke test runs, and the case reports OK.
  # A hook that is present is meant to run, so refuse instead of skipping it.
  for hook in e2e-setup.sh e2e-check.sh e2e-teardown.sh; do
    if [ -f "$dir/ci/$hook" ] && [ ! -x "$dir/ci/$hook" ]; then
      echo "ERROR: $chart ci/$hook is not executable and would be silently skipped — chmod +x it"
      fail=1
      continue 2
    fi
  done

  matched=0
  for vf in "${fixtures[@]}"; do
    case="$(basename "$vf" -values.yaml)"

    # Fixture-case filter: skip cases not named in E2E_CASES (when it is set). Placed
    # before the release/echo lines so a filtered-out case produces no output at all.
    if [ -n "$CASES" ] && [[ " $CASES " != *" $case "* ]]; then
      continue
    fi

    # Render-only fixtures (charts/<chart>/ci/e2e-render-only) are skipped by the default
    # all-fixtures sweep — they render/validate in test-charts.sh but cannot converge here
    # (e.g. a GPU reservation needing hardware this runner lacks). Still run if E2E_CASES
    # names them explicitly.
    if [ -z "$CASES" ] && [ -f "$dir/ci/e2e-render-only" ] && grep -qxF "$case" "$dir/ci/e2e-render-only"; then
      echo "── $chart [$case]  render-only — skipped in e2e (runs in test-charts.sh)"
      continue
    fi
    matched=$(( matched + 1 ))

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

    # Deploy AND converge in one step. A non-zero exit is either a rejected
    # install (bad manifest, failed pre-flight) or a rollout that never settled;
    # swarmcli's own message distinguishes them, so it is printed either way.
    ok=1
    if ! out="$("$SWARMCLI" charts install "$release" "./$dir" -f "$vf" \
      --wait --timeout "$TIMEOUT" 2>&1)"; then
      ok=0
      echo "   FAIL: install did not succeed within $TIMEOUT"
      printf '%s\n' "$out" | sed 's/^/      /'
      docker stack ps "$release" --no-trunc 2>/dev/null | sed 's/^/      /' || true
      # Dump each service's recent logs so a non-converging task (crash loop, failed
      # first-boot init, bad config) is diagnosable straight from the CI output.
      for svc in $(docker stack services "$release" --format '{{.Name}}' 2>/dev/null); do
        echo "      --- docker service logs $svc (tail 120) ---"
        docker service logs --tail 120 "$svc" 2>&1 | sed 's/^/      /' || true
      done
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

  # A set E2E_CASES that matched nothing for this chart is almost always a typo in the
  # curated list — fail loudly rather than silently reporting a green "no cases ran".
  if [ -n "$CASES" ] && [ "$matched" -eq 0 ]; then
    echo "ERROR: $chart — E2E_CASES='$E2E_CASES' matched none of its ci/*-values.yaml fixtures"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "All charts deployed, converged, and tore down cleanly."
else
  echo "E2E FAILURES detected."
  exit 1
fi
