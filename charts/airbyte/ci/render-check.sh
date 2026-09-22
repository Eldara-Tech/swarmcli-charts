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

[ "$fail" -eq 0 ] || exit 1
echo "  $case: public URLs use $scheme://, issuer TLS verified"
