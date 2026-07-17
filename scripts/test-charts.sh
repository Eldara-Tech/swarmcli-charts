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
#   5. scripts/requirements-check -> every external resource the manifest uses is
#                                    declared in requirements.yaml (swarmcli's contract)
#   6. ci/render-check.sh (opt-in) -> chart-specific assertions on the rendered stack
#                                    (e.g. a GPU fixture emits the Swarm generic_resources
#                                    form, not the no-op devices form). Runs only if the
#                                    chart ships an executable ci/render-check.sh.
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/test-charts.sh [chart ...]
#   Defaults to all charts under charts/*. Rendered output is written to
#   .rendered/<chart>__<case>.yaml for inspection and CI artifact upload.
#
# Requires mikefarah yq v4 (steps 5 and 6 are written in it) — hard-checked below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWARMCLI="${SWARMCLI:-swarmcli}"
RELEASE="${RELEASE:-ci}"
OUT="$ROOT/.rendered"

# mikefarah yq v4 is a HARD prerequisite, not a nice-to-have. Steps 5 and 6 above are
# written in it, and they used to degrade to a "note: … skipping" + exit 0 when it was
# absent — which meant `make test` printed "All charts passed." while asserting nothing
# about requirements.yaml or any chart's render checks. A skipped check is
# indistinguishable from a passing one, so the harness now refuses to run without it.
# (GitHub-hosted runners ship it; charts.yml also installs it explicitly so CI never
# depends on the runner image's contents.)
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -qi mikefarah; then
  cat >&2 <<'EOF'
ERROR: mikefarah yq v4 not found — refusing to run.

  scripts/requirements-check.sh and the charts' ci/render-check.sh assertions are
  written in it. Without yq they would silently skip, and `make test` would report
  success while checking nothing.

  Install one of:
    go install github.com/mikefarah/yq/v4@latest        # needs Go; lands in $(go env GOPATH)/bin
    snap install yq
    brew install yq                                     # macOS
    https://github.com/mikefarah/yq/releases            # static binary

  NOTE: the `yq` in Debian/Ubuntu apt is a DIFFERENT tool (a Python jq wrapper) and
  will not work — `yq --version` must mention "mikefarah".
EOF
  exit 1
fi

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
    # A render that succeeded can still have said something. `charts template` is
    # warn-only about a chart whose swarmcliVersion this renderer does not
    # satisfy: it exits 0 and writes the warning to stderr. Without this the
    # message dies in $err, which is deleted at the end of a green run — so the
    # only signal about a compat problem would be silently discarded.
    if [ -s "$err" ]; then
      echo "   NOTE: renderer warnings"
      sed 's/^/      /' "$err"
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
    # Render requirements.yaml with the same values as the manifest so a templated
    # declaration (e.g. name: "{{ .Values.database.network }}") is checked as its
    # resolved value. requirements-check.sh falls back to the on-disk file when
    # this is empty (chart without a requirements.yaml).
    reqout=""
    if [ -f "$dir/requirements.yaml" ]; then
      reqout="$OUT/${chart}__${case}.requirements.yaml"
      if ! "$SWARMCLI" charts template "$RELEASE" "./$dir" -f "$vf" --requirements >"$reqout" 2>"$err"; then
        echo "   FAIL: rendering requirements.yaml"
        sed 's/^/      /' "$err"
        fail=1
        continue
      fi
    fi
    if ! scripts/requirements-check.sh "$out" "$dir" "$reqout"; then
      fail=1
      continue
    fi
    # Optional per-chart render assertion: charts/<chart>/ci/render-check.sh <rendered> <case>
    if [ -x "$dir/ci/render-check.sh" ] && ! "$dir/ci/render-check.sh" "$out" "$case"; then
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
