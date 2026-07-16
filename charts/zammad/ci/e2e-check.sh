#!/usr/bin/env bash
#
# e2e smoke check for the zammad chart. scripts/e2e-test.sh runs this once the release converges:
#   $1 = release name (== stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence is NOT enough: a role reaches "Running" the moment its bash wrapper starts, before the
# image's check_zammad_ready releases and puma/nginx bind, and while the one-shot `init` is still
# migrating+seeding. So this polls the app until it actually serves:
#
#   GET /api/v1/getting_started 200  -> nginx proxied to rails, which answered from a MIGRATED
#                                       database. Proof that init ran, the readiness gate released,
#                                       and nginx's rails upstream wiring (ZAMMAD_RAILSSERVER_HOST)
#                                       is correct.
#
# It probes nginx ON THE STACK'S INTERNAL OVERLAY (a throwaway curl container joins it), NOT the host
# published port. The published port exercises Swarm's ingress routing mesh, which is Docker infra —
# not something this chart controls — and it is unreliable on CI runners: the mesh accepts the TCP
# connection but returns 0 bytes when its backend LB has no route, so localhost:8080 hangs even though
# nginx and rails are healthy. Every sibling chart's smoke check reaches its service from inside a
# container for the same reason (see charts/whoami and charts/superset ci/e2e-check.sh).
set -euo pipefail

release="$1"
target="http://nginx:8080/api/v1/getting_started"

# The chart-managed internal overlay is attachable; find its Swarm-qualified name (<release>_<net>).
net="$(docker network ls --filter "name=${release}" --format '{{.Name}}' 2>/dev/null | grep -m1 internal || true)"
if [ -z "$net" ]; then
  echo "   FAIL: could not find the internal overlay for release ${release}"
  docker network ls --filter "name=${release}" 2>/dev/null | sed 's/^/      /' || true
  exit 1
fi

# One throwaway curl container joins the overlay and polls nginx until it serves 200 (or the 10 min
# deadline). Each probe is bounded (-m 25; a cold request on a slow CI disk can exceed 10s); the
# heartbeat logs the observed status every ~2 min so a failure shows WHAT it got, not just "never 200".
if docker run --rm --network "$net" --entrypoint sh -e TARGET="$target" curlimages/curl:8.11.1 -c '
  deadline=$(( $(date +%s) + 600 )); next=0; code=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -s -o /dev/null -m 25 -w "%{http_code}" "$TARGET" 2>/dev/null || true)
    [ "$code" = "200" ] && { echo "   ok: $TARGET -> 200 (nginx -> rails -> migrated database)"; exit 0; }
    now=$(date +%s)
    if [ "$now" -ge "$next" ]; then
      echo "   ... waiting: $TARGET -> ${code:-000} ($(( (deadline - now) / 60 ))m left)"
      next=$(( now + 120 ))
    fi
    sleep 10
  done
  echo "   (last status: ${code:-000})"; exit 1
'; then
  exit 0
fi

# --- failure diagnostics -------------------------------------------------------------------------
echo "   FAIL: ${target} never returned 200"
echo "   --- docker service ps (state / restarts / rejection reasons) ---"
for svc in init railsserver websocket scheduler nginx postgres redis memcached elasticsearch; do
  docker service ps --no-trunc "${release}_${svc}" 2>/dev/null | sed 's/^/      /' || true
done
echo "   --- rails DIRECT on the overlay (bypasses nginx; splits app-broken from nginx-broken) ---"
docker run --rm --network "$net" curlimages/curl:8.11.1 \
  -s -m 25 -o /dev/null -w 'railsserver:3000 -> %{http_code}\n' \
  "http://railsserver:3000/api/v1/getting_started" 2>&1 | sed 's/^/      /' || true
echo "   --- service logs ---"
for svc in init railsserver nginx elasticsearch postgres redis; do
  echo "      === ${svc} ==="
  docker service logs --tail 60 "${release}_${svc}" 2>&1 | sed 's/^/      /' || true
done
exit 1
