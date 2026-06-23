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
