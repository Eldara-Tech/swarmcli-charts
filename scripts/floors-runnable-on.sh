#!/usr/bin/env bash
#
# Print the charts a given swarmcli binary can actually run — i.e. whose declared
# swarmcliVersion floor is <= the binary's version — and REPORT (::warning) the
# ones that are ahead of it.
#
# The nightly workflow renders/deploys against the latest RELEASE, but a chart
# may legitimately declare a floor no release has reached yet (today: zammad
# needs >=1.13.0 while the latest stable is v1.12.0). Running such a chart against
# an older binary would fail on behaviour that simply has not shipped — that is a
# known-good state, not a regression, so it is skipped and surfaced rather than
# turned red. This mirrors scripts/floor-check.sh's treatment of unreleased floors.
#
# Charts with no (or an unreadable) floor are treated as runnable: there is no
# lower bound to violate.
#
# Usage: scripts/floors-runnable-on.sh <swarmcli-binary>
#   Prints runnable chart names (one per line) on stdout; warnings on stderr.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:?usage: floors-runnable-on.sh <swarmcli-binary>}"

installed="$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$installed" ] || { echo "floors-runnable-on: could not read '$BIN' version" >&2; exit 1; }

# First X.Y.Z in a constraint (">= 1.11.0" -> "1.11.0"); same rule as floor-check.
floor_of() { printf '%s' "$1" | sed -nE 's/.*?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1; }

for dir in "$ROOT"/charts/*/; do
  chart="$(basename "$dir")"
  constraint="$(sed -n 's/^swarmcliVersion:[[:space:]]*//p' "$dir/Chart.yaml" | head -1 | tr -d '"'\'' ')"
  floor="$(floor_of "$constraint")"

  if [ -z "$floor" ]; then
    echo "$chart"
    continue
  fi

  # Runnable iff floor <= installed, i.e. floor sorts first (or equal).
  if [ "$(printf '%s\n%s\n' "$floor" "$installed" | sort -V | head -1)" = "$floor" ]; then
    echo "$chart"
  else
    echo "::warning title=Ahead of release::$chart declares swarmcliVersion '$constraint' (floor v$floor) > installed v$installed — skipped in the release run." >&2
  fi
done
