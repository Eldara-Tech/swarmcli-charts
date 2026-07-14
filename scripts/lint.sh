#!/usr/bin/env bash
#
# Chart correctness lint — no rendering. Checks every chart has the required
# files and fields, has at least one CI fixture, and passes yamllint. The render
# pipeline (scripts/test-charts.sh) covers behaviour; this covers structure.
#
# Usage: scripts/lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

for dir in charts/*/; do
  chart="$(basename "$dir")"
  for field in name version appVersion description; do
    grep -q "^$field:" "$dir/Chart.yaml" 2>/dev/null \
      || { echo "ERROR: $chart Chart.yaml is missing required field: $field"; fail=1; }
  done
  [ -f "$dir/values.yaml" ] \
    || { echo "ERROR: $chart is missing values.yaml"; fail=1; }
  [ -f "$dir/templates/stack.yaml.tmpl" ] \
    || { echo "ERROR: $chart is missing templates/stack.yaml.tmpl"; fail=1; }
  ls "$dir"ci/*-values.yaml >/dev/null 2>&1 \
    || { echo "ERROR: $chart has no ci/*-values.yaml fixture"; fail=1; }

  # Renovate reads the image pin from a `# renovate: image=<repo>` comment on the
  # line directly above appVersion. Without this check a new chart silently
  # escapes Renovate and its image goes stale forever, so require the comment and
  # require it to name the same image values.yaml actually deploys.
  declared="$(grep -B1 '^appVersion:' "$dir/Chart.yaml" 2>/dev/null \
    | sed -n 's|^# renovate: image=||p')"
  actual="$(sed -n '/^image:/,/^[^ ]/p' "$dir/values.yaml" 2>/dev/null \
    | sed -n 's|^  repository: *||p')"
  if [ -z "$declared" ]; then
    echo "ERROR: $chart Chart.yaml has no '# renovate: image=<repo>' comment directly above appVersion"
    fail=1
  elif [ "$declared" != "$actual" ]; then
    echo "ERROR: $chart renovate comment pins '$declared' but values.yaml image.repository is '$actual'"
    fail=1
  fi

  # A version echoed into a comment drifts the moment Renovate bumps appVersion,
  # because Renovate edits Chart.yaml and never touches these.
  if grep -qE 'defaults to appVersion from Chart\.yaml \(' "$dir/values.yaml" 2>/dev/null; then
    echo "ERROR: $chart values.yaml repeats the appVersion in a comment; it will drift — drop the parenthetical"
    fail=1
  fi

  # A floating tag is unpinnable and unreviewable: it changes what deploys without
  # a commit. Renovate can only keep a concrete tag fresh.
  if grep -nE '^[^#]*: *[^ #]+:latest *(#.*)?$' "$dir/values.yaml" 2>/dev/null; then
    echo "ERROR: $chart values.yaml references a :latest image (see above); pin a concrete tag"
    fail=1
  fi
done

if command -v yamllint >/dev/null 2>&1; then
  yamllint charts/ || fail=1
else
  echo "note: yamllint not installed — skipping YAML style lint (pip install yamllint)"
fi

if [ "$fail" -eq 0 ]; then
  echo "Lint OK."
else
  echo "Lint failed."
  exit 1
fi
