#!/usr/bin/env bash
# Render every chart with the swarmcli version it CLAIMS to need.
#
# A chart's Chart.yaml swarmcliVersion is a promise: "I run on this". Nothing
# verified that promise. test-charts.sh renders with swarmcli `main`, which is
# newer than anything a user has installed, so a chart can quietly depend on
# unreleased behaviour and still go green. That is exactly how charts/zammad came
# to require an unreleased fix (control flow in requirements.yaml, swarmcli #457)
# without anyone noticing — it renders on main and fails on every release.
#
# `swarmcli charts lint --for-version` checks the promise's SHAPE (does the
# declared floor admit that version). Only a real binary of that version can
# check its TRUTH, which is what this script does.
#
# A chart whose floor names a version that is not released yet cannot be
# verified. Those are SKIPPED and REPORTED — never silently passed. Same for a
# chart that declares no floor at all: there is nothing to check, and saying so
# is the point.
#
# Usage: scripts/floor-check.sh [bindir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINDIR="${1:-$ROOT/.floor-bin}"
REPO_URL="${SWARMCLI_REPO:-https://github.com/Eldara-Tech/swarmcli.git}"

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "ERROR: mikefarah yq v4 is required (https://github.com/mikefarah/yq)" >&2
  exit 2
fi

fail=0
skipped=()
checked=()

# floor_of extracts the first X.Y.Z in a constraint (">= 1.11.0" -> "1.11.0").
# Deliberately simple: every floor this repo declares is a lower bound, and a
# constraint fancy enough to defeat this should not be a chart's floor.
floor_of() {
  printf '%s' "$1" | sed -nE 's/.*?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1
}

released() {
  git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/v$1" >/dev/null 2>&1
}

for dir in "$ROOT"/charts/*/; do
  chart="$(basename "$dir")"
  constraint="$(yq -r '.swarmcliVersion // ""' "$dir/Chart.yaml")"

  if [ -z "$constraint" ]; then
    echo "── $chart: declares no swarmcliVersion — floor NOT verified"
    skipped+=("$chart (no floor declared)")
    continue
  fi

  floor="$(floor_of "$constraint")"
  if [ -z "$floor" ]; then
    echo "── $chart: cannot read a floor out of swarmcliVersion '$constraint'"
    skipped+=("$chart (unreadable floor: $constraint)")
    continue
  fi

  if ! released "$floor"; then
    echo "── $chart: declares '$constraint' but v$floor is not released — floor NOT verified"
    echo "::warning title=Floor not verified::$chart declares swarmcliVersion '$constraint'; v$floor is not released yet, so its floor could not be proven."
    skipped+=("$chart (v$floor unreleased)")
    continue
  fi

  bin="$BINDIR/v$floor"
  if [ ! -x "$bin/swarmcli" ]; then
    echo "── building swarmcli v$floor"
    SWARMCLI_REF="v$floor" "$ROOT/scripts/install-swarmcli.sh" "$bin" >/dev/null
  fi

  echo "── $chart: rendering with real swarmcli v$floor"
  mapfile -t fixtures < <(find "$dir/ci" -maxdepth 1 -name '*-values.yaml' 2>/dev/null | sort)
  if [ "${#fixtures[@]}" -eq 0 ]; then
    echo "   no ci fixtures — nothing to render"
    skipped+=("$chart (no ci fixtures)")
    continue
  fi

  for vf in "${fixtures[@]}"; do
    case="$(basename "$vf" -values.yaml)"
    if err="$("$bin/swarmcli" charts template floorcheck "$dir" -f "$vf" 2>&1 >/dev/null)"; then
      echo "   OK   [$case]"
    else
      echo "   FAIL [$case] — chart does not run on the v$floor it declares"
      printf '%s\n' "$err" | sed 's/^/        /'
      fail=1
    fi
  done
  checked+=("$chart (v$floor)")
done

echo
echo "Verified against their declared floor: ${#checked[@]}"
for c in "${checked[@]:-}"; do [ -n "$c" ] && echo "  - $c"; done
echo "Not verified: ${#skipped[@]}"
for c in "${skipped[@]:-}"; do [ -n "$c" ] && echo "  - $c"; done

if [ "$fail" -ne 0 ]; then
  echo
  echo "FAILURES: a chart does not run on the swarmcli it declares. Either fix the"
  echo "chart, or raise its swarmcliVersion to a release that actually supports it."
  exit 1
fi
echo
echo "All declared floors hold."
