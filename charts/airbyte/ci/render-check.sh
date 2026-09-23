#!/usr/bin/env bash
#
# Render-time assertions for the airbyte chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy).
#
# The public scheme is the point: oauth2-proxy's callback and AIRBYTE_URL must follow
# exposure.tls, or login over a plain-HTTP published port redirects into https:// and fails.
set -euo pipefail

out="$1"
case="${2:-}"

scheme=https
[ "$case" = "published" ] && scheme=http

fail=0

grep -q -- "--redirect-url=$scheme://airbyte.example.com/oauth2/callback" "$out" \
  || { echo "  FAIL($case): oauth2-proxy redirect-url is not $scheme://"; fail=1; }
[ "$(grep -c "AIRBYTE_URL: $scheme://airbyte.example.com" "$out")" -eq 2 ] \
  || { echo "  FAIL($case): server and worker AIRBYTE_URL are not both $scheme://"; fail=1; }
grep -q -- '--ssl-insecure-skip-verify=false' "$out" \
  || { echo "  FAIL($case): oauth2-proxy skips TLS verification by default"; fail=1; }

# One Airbyte release everywhere: every platform image carries the tag AIRBYTE_VERSION names,
# or a Renovate bump of appVersion runs mixed versions.
versions="$(sed -n 's/^ *AIRBYTE_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$out" | sort -u)"
tags="$(sed -n 's/^ *image: airbyte\/[a-z-]*:\(.*\)$/\1/p' "$out" | sort -u)"
{ [ "$(printf '%s\n' "$versions" | wc -l)" -eq 1 ] && [ "$tags" = "$versions" ]; } \
  || { echo "  FAIL($case): platform image tags [$(echo $tags)] != AIRBYTE_VERSION [$(echo $versions)]"; fail=1; }

# Only the workload launcher holds the Docker socket; the worker never starts containers.
[ "$(grep -c '/var/run/docker.sock:/var/run/docker.sock' "$out")" -eq 1 ] \
  || { echo "  FAIL($case): docker.sock is mounted into more than the workload launcher"; fail=1; }

# A private registry's config.json reaches FakeK8s: the launcher mounts the secret and names
# the same path in FAKEK8S_REGISTRY_AUTH_FILE; without the value, neither appears.
if [ "$case" = "registry-auth" ]; then
  grep -q 'FAKEK8S_REGISTRY_AUTH_FILE: "\{0,1\}/run/secrets/airbyte_registry_auth"\{0,1\}$' "$out" \
    && grep -q '^ *- airbyte_registry_auth$' "$out" \
    || { echo "  FAIL($case): registry auth secret not mounted where FAKEK8S_REGISTRY_AUTH_FILE points"; fail=1; }
elif grep -q 'FAKEK8S_REGISTRY_AUTH_FILE' "$out"; then
  echo "  FAIL($case): FAKEK8S_REGISTRY_AUTH_FILE set without workloadLauncher.registryAuthSecretName"; fail=1
fi

# The data pin follows the two named volumes (session Redis and Temporal) and nothing else,
# and goes away with nodeLabel: "".
pins=2
[ "$case" = "published" ] && pins=0
[ "$(grep -c 'node.labels.airbyte-data == true' "$out")" -eq "$pins" ] \
  || { echo "  FAIL($case): expected $pins data-node pin(s), session Redis and Temporal"; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "  $case: public URLs use $scheme://, issuer TLS verified, one Airbyte version, one socket mount, $pins data pin"
