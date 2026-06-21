#!/usr/bin/env bash
#
# Generates index.yaml by listing all GitHub Releases tagged <chart>/v<version>
# and reading each chart's Chart.yaml for metadata.
#
# Requires: gh CLI (authenticated), yq, sha256sum
#
# Usage: ./scripts/generate-index.sh <owner/repo> > index.yaml

set -euo pipefail

REPO="${1:?Usage: generate-index.sh <owner/repo>}"
BASE_URL="https://github.com/${REPO}/releases/download"

echo "apiVersion: v1"
echo "generated: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
echo "entries:"

# Get all release tags matching <chart>/v<version>
TAGS=$(gh release list --repo "$REPO" --limit 1000 --json tagName -q '.[].tagName' | grep '/v' || true)

if [ -z "$TAGS" ]; then
  echo "  {}" # empty entries map if no releases yet
  exit 0
fi

# Group tags by chart name
CHARTS=$(echo "$TAGS" | cut -d/ -f1 | sort -u)

for CHART in $CHARTS; do
  echo "  ${CHART}:"
  CHART_TAGS=$(echo "$TAGS" | grep "^${CHART}/v" | sort -rV)

  for TAG in $CHART_TAGS; do
    VERSION=${TAG#${CHART}/v}
    ASSET="${CHART}-v${VERSION}.tgz"
    CHECKSUM_ASSET="${ASSET}.sha256"

    # Pull Chart.yaml metadata as it existed at this tag
    CHART_YAML=$(git show "${TAG}:charts/${CHART}/Chart.yaml" 2>/dev/null || echo "")
    if [ -z "$CHART_YAML" ]; then
      echo "    WARNING: could not read charts/${CHART}/Chart.yaml at tag ${TAG}, skipping" >&2
      continue
    fi

    APP_VERSION=$(echo "$CHART_YAML" | grep '^appVersion:' | sed 's/appVersion: *//; s/"//g')
    DESCRIPTION=$(echo "$CHART_YAML" | grep '^description:' | sed 's/description: *//')

    # Download checksum file from the release to embed in the index
    DIGEST=""
    CHECKSUM_CONTENT=$(gh release download "$TAG" --repo "$REPO" --pattern "$CHECKSUM_ASSET" --output - 2>/dev/null || echo "")
    if [ -n "$CHECKSUM_CONTENT" ]; then
      DIGEST=$(echo "$CHECKSUM_CONTENT" | awk '{print $1}')
    fi

    echo "    - name: ${CHART}"
    echo "      version: \"${VERSION}\""
    echo "      appVersion: \"${APP_VERSION}\""
    echo "      description: \"${DESCRIPTION}\""
    echo "      urls:"
    echo "        - ${BASE_URL}/${TAG}/${ASSET}"
    if [ -n "$DIGEST" ]; then
      echo "      digest: sha256:${DIGEST}"
    fi
  done
done
