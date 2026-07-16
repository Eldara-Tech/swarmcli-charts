#!/usr/bin/env bash
#
# e2e smoke check for the zammad chart. scripts/e2e-test.sh runs this once the release converges:
#   $1 = release name (== stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence is NOT enough. The harness waits for every task to reach Running — which for a Zammad
# role is the moment the container's bash wrapper starts, BEFORE the image entrypoint's
# check_zammad_ready has released and puma/nginx have bound. And the one-shot `init` is still
# migrating+seeding at that point. So this polls the app THROUGH nginx until it actually serves:
#
#   GET /api/v1/getting_started  200  -> nginx proxied to rails, which answered from a MIGRATED
#                                        database (the endpoint queries it). End-to-end proof that
#                                        init ran, the app's readiness gate released, and nginx's
#                                        rails upstream wiring (ZAMMAD_RAILSSERVER_HOST) is correct.
#
# The embedded-backing fixture publishes nginx on host port 8080 (exposure.mode: published, ingress
# routing mesh), so a single-node swarm reaches it at localhost:8080. Generous budget: first boot is
# a large image pull + alembic-style migrations + seed (+ a trivial reindex of the fresh DB).
set -euo pipefail

release="$1"
port=8080
url="http://localhost:${port}/api/v1/getting_started"

# Bound BOTH each probe (-m 10, so a slow/hung nginx→rails upstream cannot stall the loop) and the
# overall wait (a real wall-clock deadline). The old iteration count assumed every probe returned in
# ~10s; while the app boots each request sits on a read-timeout, so 90 iterations could run far past
# the intended budget. This runs AFTER convergence (image pull already paid), so the wall clock here
# covers only migrations + seed + puma binding.
ok=0
deadline=$(( $(date +%s) + 1800 ))   # 30 min wall-clock, hard
while [ "$(date +%s)" -lt "$deadline" ]; do
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 10
done

if [ "$ok" -ne 1 ]; then
  echo "   FAIL: ${url} never returned 200 (init did not migrate, the app never bound, or nginx's rails upstream is misrouted)"
  docker service logs --tail 80 "${release}_init"        2>&1 | sed 's/^/      init:   /' || true
  docker service logs --tail 80 "${release}_railsserver" 2>&1 | sed 's/^/      rails:  /' || true
  docker service logs --tail 40 "${release}_nginx"       2>&1 | sed 's/^/      nginx:  /' || true
  docker service logs --tail 20 "${release}_postgres"    2>&1 | sed 's/^/      pg:     /' || true
  exit 1
fi
echo "   ok: ${url} -> 200 (nginx -> rails -> migrated database)"
exit 0
