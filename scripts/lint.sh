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

  # A version echoed into prose drifts the moment Renovate bumps appVersion, because
  # Renovate edits Chart.yaml and never touches values.yaml comments or the README.
  # Say "defaults to appVersion" and let the reader look it up.
  if grep -qE 'defaults to appVersion from Chart\.yaml \(' "$dir/values.yaml" 2>/dev/null; then
    echo "ERROR: $chart values.yaml repeats the appVersion in a comment; it will drift — drop the parenthetical"
    fail=1
  fi
  if grep -qEi 'defaults to .?appVersion.? \(' "$dir/README.md" 2>/dev/null; then
    echo "ERROR: $chart README.md repeats the appVersion in the values table; it will drift — say 'defaults to appVersion in Chart.yaml'"
    fail=1
  fi

  # A floating tag is unpinnable and unreviewable: it changes what deploys without
  # a commit. Renovate can only keep a concrete tag fresh.
  if grep -nE '^[^#]*: *[^ #]+:latest *(#.*)?$' "$dir/values.yaml" 2>/dev/null; then
    echo "ERROR: $chart values.yaml references a :latest image (see above); pin a concrete tag"
    fail=1
  fi
  if grep -qE '`[^`]+:latest`' "$dir/README.md" 2>/dev/null; then
    echo "ERROR: $chart README.md documents a :latest default that values.yaml cannot have"
    fail=1
  fi
done

# A consumer that exits early kills the producer, and pipefail keeps the corpse.
#
# `producer | grep -q PATTERN` under `set -o pipefail` reports a MATCH as no match:
# grep -q exits the instant it matches, the producer's next write gets SIGPIPE (yq
# dies with 141), and pipefail promotes that 141 to the pipeline's status. It is a
# scheduling race — green on an idle laptop, red on a loaded runner — and on
# 2026-08-10 it took out both charts.yml runs on assertions that were true
# (zammad "rendered no host-path mount", swarmcli-cd "carries no node.role ==
# manager"). Written the other way round, `producer | grep -q X && flag_risk`, the
# same race silently drops the risk instead.
#
# Write `| grep PATTERN >/dev/null` (reads to EOF, same exit status, and a real
# producer failure is still caught) and `| sed -n 1p` for `| head -1`. Enforced over
# the render/validate harness — the scripts `make test` runs. grep against a FILE is
# unaffected: no pipe, no SIGPIPE. The e2e scripts and workflows still carry the
# pattern — #149 tracks them; widen `harness` below as they are cleaned up.
harness=(scripts/lint.sh scripts/test-charts.sh scripts/security-scan.sh
         scripts/requirements-check.sh scripts/floor-check.sh charts/*/ci/render-check.sh)
for f in "${harness[@]}"; do
  [ -f "$f" ] || continue
  # The trailing filter drops comment lines, so the paragraphs above (and their
  # counterparts in each render-check) can name the pattern they forbid.
  if grep -nE '\|[[:space:]]*(grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*q[a-zA-Z]*([[:space:]]|$)|head([[:space:]]|$))' "$f" \
       | grep -vE '^[0-9]+:[[:space:]]*#'; then
    echo "ERROR: $f pipes into an early-exiting consumer (see above) — under pipefail that"
    echo "       turns a match into a false negative. Use '| grep P >/dev/null' or '| sed -n 1p'."
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
