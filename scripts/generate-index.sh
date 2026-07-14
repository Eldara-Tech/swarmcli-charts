#!/usr/bin/env bash
#
# Generates index.yaml by listing all GitHub Releases tagged <chart>/v<version>
# and reading each chart's Chart.yaml for metadata.
#
# Version is always taken from the tag (source of truth).
# If Chart.yaml version differs from the tag, a warning is emitted to stderr.
#
# The document is assembled as JSON and converted to YAML in one step, so every
# scalar is escaped by a real serializer. The previous `echo "description: $X"`
# form emitted a broken document the moment a description contained a quote.
#
# Requires: gh CLI (authenticated), jq, yq
#
# Usage: ./scripts/generate-index.sh <owner/repo> > index.yaml

set -euo pipefail

REPO="${1:?Usage: generate-index.sh <owner/repo>}"
BASE_URL="https://github.com/${REPO}/releases/download"

for tool in gh jq yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

# One call for every release. tagName drives the loop; publishedAt becomes each
# entry's `created`. Renovate maps `created` to a release timestamp, which is what
# its minimumReleaseAge ("let it bake N days") setting reads — without it, that
# safety valve silently does nothing for everyone consuming this index.
RELEASES=$(gh release list --repo "$REPO" --limit 1000 --json tagName,publishedAt \
  -q '.[] | select(.tagName | contains("/v")) | "\(.tagName)\t\(.publishedAt)"')

if [ -z "$RELEASES" ]; then
  printf 'apiVersion: v1\ngenerated: "%s"\nentries: {}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
fi

TAGS=$(echo "$RELEASES" | cut -f1)
ENTRIES="{}"

for CHART in $(echo "$TAGS" | cut -d/ -f1 | sort -u); do
  for TAG in $(echo "$TAGS" | grep "^${CHART}/v" | sort -rV); do
    VERSION=${TAG#"${CHART}"/v}
    ASSET="${CHART}-v${VERSION}.tgz"
    CREATED=$(echo "$RELEASES" | awk -F'\t' -v t="$TAG" '$1 == t { print $2; exit }')

    CHART_YAML=$(git show "${TAG}:charts/${CHART}/Chart.yaml" 2>/dev/null || echo "")
    if [ -z "$CHART_YAML" ]; then
      echo "WARNING: could not read charts/${CHART}/Chart.yaml at tag ${TAG}, skipping" >&2
      continue
    fi

    # Warn if Chart.yaml version doesn't match the tag (e.g. tag was pushed manually)
    CHART_VERSION=$(echo "$CHART_YAML" | yq -r '.version // ""')
    if [ "$CHART_VERSION" != "$VERSION" ]; then
      echo "WARNING: tag ${TAG} has version ${VERSION} but Chart.yaml says ${CHART_VERSION} — using tag version" >&2
    fi

    # The chart's own metadata, read through a parser rather than grep|sed.
    META=$(echo "$CHART_YAML" | yq -o=json -I=0 '{"appVersion": (.appVersion // "" | tostring), "description": (.description // ""), "home": (.home // "")}')

    DIGEST=""
    CHECKSUM=$(gh release download "$TAG" --repo "$REPO" --pattern "${ASSET}.sha256" --output - 2>/dev/null || echo "")
    [ -n "$CHECKSUM" ] && DIGEST="sha256:$(echo "$CHECKSUM" | awk '{print $1}')"

    # `sources` is this repository, NOT Chart.yaml's sources: those point at the
    # UPSTREAM project for half the charts (whoami -> traefik/whoami, superset ->
    # apache/superset), and a consumer resolving a chart's source from them would
    # go looking for a `whoami/v0.1.8` tag in traefik/whoami. The source of the
    # *chart* is always this repo.
    ENTRY=$(jq -n -c \
      --arg name "$CHART" \
      --arg version "$VERSION" \
      --arg created "$CREATED" \
      --arg digest "$DIGEST" \
      --arg url "${BASE_URL}/${TAG}/${ASSET}" \
      --arg source "https://github.com/${REPO}" \
      --argjson meta "$META" \
      '{name: $name, version: $version}
       + (if $meta.appVersion  != "" then {appVersion:  $meta.appVersion}  else {} end)
       + (if $meta.description != "" then {description: $meta.description} else {} end)
       + (if $created != "" then {created: $created} else {} end)
       + (if $meta.home != "" then {home: $meta.home} else {} end)
       + {sources: [$source], urls: [$url]}
       + (if $digest != "" then {digest: $digest} else {} end)')

    ENTRIES=$(jq -c --arg chart "$CHART" --argjson entry "$ENTRY" \
      '.[$chart] = ((.[$chart] // []) + [$entry])' <<<"$ENTRIES")
  done
done

jq -n --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson entries "$ENTRIES" \
  '{apiVersion: "v1", generated: $generated, entries: $entries}' \
  | yq -p=json -o=yaml
