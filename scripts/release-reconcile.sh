#!/usr/bin/env bash
#
# Release every chart whose committed state is ahead of what it last published.
#
# Merging a pin does not publish a chart, so `main` drifts ahead of the released
# `.tgz` files until somebody releases by hand — ten charts in one sitting, the day
# Renovate first ran. This closes that gap without guessing at intent.
#
# THE COMPARISON. `release.yml` packages a chart with
# `tar -czf <chart>-<version>.tgz -C charts <chart>` from the TAGGED commit, and
# stamps `version:` into Chart.yaml inside the workflow — never in git. So the tag's
# tree *is* what was published, and the committed `version:` placeholder is identical
# on both sides. One diff therefore answers the whole question:
#
#   git diff --quiet <newest tag> HEAD -- charts/<chart>/
#
# No rule about which keys constitute a pin, and it stays correct when a chart gains
# files later. A path filter cannot do this: charts/renovate/README.md changed in #86
# without any pin moving, and "something under charts/<name>/ changed" would have
# released the chart for a docs edit.
#
# LEVEL-TRIGGERED, deliberately. It does not care which event fired or whether a run
# was cancelled — only whether published state matches committed state. Both failure
# modes seen in practice are therefore harmless here: main's E2E being cancelled
# mid-flight by the next merge (`concurrency: cancel-in-progress`), and GitHub
# silently dropping tag-push events past three per push. A release that fails at 3am
# is simply retried on the next pass.
#
# A chart with no tag at all is REPORTED, never released: a chart can be deliberately
# unpublished (zammad sat unreleasable while its swarmcli floor was unshipped), so
# starting a series stays a human act.
#
# Usage: scripts/release-reconcile.sh [--dry-run]
#   Needs full history and tags (checkout with fetch-depth: 0, fetch-tags: true).
#   Dispatching needs `gh` authenticated with actions:write; --dry-run needs neither.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: release-reconcile.sh [--dry-run]" >&2; exit 2 ;;
esac

stale=()

for dir in charts/*/; do
  chart="$(basename "$dir")"

  # Same ordering as release.yml's dispatch path, so both agree on "newest".
  tag="$(git tag --list "$chart/v*" --sort=-v:refname | sed -n 1p)"

  if [ -z "$tag" ]; then
    echo "$chart: never released — reporting only"
    continue
  fi

  if git diff --quiet "$tag" HEAD -- "charts/$chart/"; then
    echo "$chart: current ($tag)"
    continue
  fi

  echo "$chart: STALE since $tag"
  git diff --stat "$tag" HEAD -- "charts/$chart/" | sed 's/^/    /'
  stale+=("$chart")
done

if [ "${#stale[@]}" -eq 0 ]; then
  echo
  echo "Everything published matches main. Nothing to release."
  exit 0
fi

echo
echo "Behind their published release: ${stale[*]}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(--dry-run: nothing dispatched)"
  exit 0
fi

# One dispatch per chart. release.yml derives the next version from the newest
# existing tag and creates the tag itself, which also sidesteps GitHub dropping
# tag-push events beyond three per push.
for chart in "${stale[@]}"; do
  echo "Dispatching release.yml: chart=$chart bump=patch"
  gh workflow run release.yml -f chart="$chart" -f bump=patch
done
