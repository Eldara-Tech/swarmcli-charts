#!/usr/bin/env bash
#
# e2e teardown for the zammad chart: removes the secrets ci/e2e-setup.sh created.
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# scripts/e2e-test.sh runs this after the case (and before it, to clean up a crashed run), so it
# must be idempotent and must never fail. The release stack + its volumes are removed by
# `swarmcli uninstall --purge-volumes` before this runs; there are no shared overlays to leave
# behind (the embedded fixture owns its network).
set -euo pipefail

for s in zammad_db_password zammad_redis_password zammad_elasticsearch_password; do
  docker secret rm "$s" >/dev/null 2>&1 || true
done

exit 0
