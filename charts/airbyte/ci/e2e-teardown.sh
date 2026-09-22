#!/usr/bin/env bash
#
# e2e teardown for the airbyte chart. scripts/e2e-test.sh runs this AFTER it uninstalls the
# release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# Removes what ci/e2e-setup.sh created — the three backing services, the mock's config, the
# six secrets and the airbyte-db-net overlay — plus any connector container or volume the
# release's FakeK8s left behind (they carry airbyte.fakek8s/owner=<release>; a clean run
# leaves none). Leaves the shared traefik-public overlay.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

release="$1"

docker service rm airbyte-e2e-postgres airbyte-e2e-minio airbyte-e2e-oidc >/dev/null 2>&1 || true
docker config rm airbyte-e2e-mock-oidc >/dev/null 2>&1 || true

leftovers="$(docker ps -aq -f "label=airbyte.fakek8s/owner=$release")"
[ -z "$leftovers" ] || docker rm -f $leftovers >/dev/null 2>&1 || true
vols="$(docker volume ls -q -f "label=airbyte.fakek8s/owner=$release")"
[ -z "$vols" ] || docker volume rm $vols >/dev/null 2>&1 || true

for s in airbyte_db_user airbyte_db_password airbyte_s3_access_key airbyte_s3_secret_key \
  airbyte_oauth_client_secret airbyte_oauth_cookie_secret; do
  docker secret rm "$s" >/dev/null 2>&1 || true
done

# The overlay can linger "in use" for a moment after the services detach; retry a few.
for _ in $(seq 1 10); do
  docker network rm airbyte-db-net >/dev/null 2>&1 && break
  sleep 1
done

exit 0
