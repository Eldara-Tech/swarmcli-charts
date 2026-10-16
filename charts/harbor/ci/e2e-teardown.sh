#!/usr/bin/env bash
#
# e2e teardown for the harbor chart. scripts/e2e-test.sh runs this AFTER it uninstalls the
# release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes what ci/e2e-setup.sh created and leaves harbor-e2e-db-net alone: removing it
# here races the next fixture's setup. Best-effort: every step tolerates already-gone
# resources.
set -uo pipefail

docker service rm harbor-e2e-db harbor-e2e-idp >/dev/null 2>&1 || true
docker secret rm harbor-db-password harbor-admin-password harbor-core-secret harbor-jobservice-secret \
  harbor-registry-http-secret harbor-csrf-key harbor-secret-key harbor-token-key \
  harbor-registry-password harbor-registry-htpasswd harbor-oidc-client-secret >/dev/null 2>&1 || true

exit 0
