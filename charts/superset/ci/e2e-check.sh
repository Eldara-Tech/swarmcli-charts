#!/usr/bin/env bash
#
# e2e smoke check for the superset chart. scripts/e2e-test.sh runs this once the release
# converges:  $1 = release name (== stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence is NOT enough here. The tasks reach Running the moment their containers start —
# before the pip step, before superset-init has migrated the database, and (for the app) before
# gunicorn binds. And /health is a liveness probe that never touches the database, so it would
# go green on a completely unmigrated stack. So this asserts BOTH:
#
#   /health   200  -> gunicorn is serving
#   /login/   200  -> Flask-AppBuilder rendered a real page, which it can only do against a
#                     MIGRATED metadata database. This is the end-to-end proof that the
#                     one-shot init service ran and that the app's wait-for-init gate released.
#
# Generous retries: first boot is an image pull + pip install + alembic migrations.
set -euo pipefail

release="$1"
dir="$2"
case="$3"

# One probe against the app task, from inside the container (the app port is not published in
# every fixture). curl ships in the image — it is the image's own healthcheck. Re-resolves the
# container each call: a crash-looping or health-replaced task changes container id.
probe() {
  local path="$1" cid code
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_app" | head -1)"
  [ -n "$cid" ] || return 1
  code="$(docker exec "$cid" curl -s -o /dev/null -w '%{http_code}' "http://localhost:8088${path}" 2>/dev/null)" || return 1
  [ "$code" = "200" ]
}

for path in /health /login/; do
  ok=0
  for _ in $(seq 1 60); do
    if probe "$path"; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" -ne 1 ]; then
    echo "   FAIL: $path never returned 200 (init did not migrate, or the app never came up)"
    docker service logs --tail 60 "${release}_init" 2>&1 | sed 's/^/      init: /' || true
    docker service logs --tail 60 "${release}_app"  2>&1 | sed 's/^/      app:  /' || true
    exit 1
  fi
  echo "   ok: $path -> 200"
done

# The embedded-redis fixture additionally proves the chart's OWN Redis actually works. /login/
# above does not: Superset renders it fine against a dead Redis (the caches miss, and rate-limit
# storage only bites under load). The Celery worker's healthcheck is the honest probe — it is
# `celery ... inspect ping`, which round-trips through the broker, so a healthy worker means the
# embedded Redis is up, authenticated with the mounted secret, and carrying Celery traffic.
if [ "$case" = "embedded-redis" ]; then
  ok=0
  for _ in $(seq 1 60); do
    cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_worker" | head -1)"
    if [ -n "$cid" ] &&
       [ "$(docker inspect -f '{{ .State.Health.Status }}' "$cid" 2>/dev/null)" = "healthy" ]; then
      ok=1; break
    fi
    sleep 5
  done
  if [ "$ok" -ne 1 ]; then
    echo "   FAIL: the celery worker never went healthy — the embedded Redis is not carrying broker traffic"
    docker service logs --tail 60 "${release}_redis"  2>&1 | sed 's/^/      redis:  /' || true
    docker service logs --tail 60 "${release}_worker" 2>&1 | sed 's/^/      worker: /' || true
    exit 1
  fi
  echo "   ok: celery worker healthy -> the embedded Redis is serving the broker"
fi

# The edge fixture additionally proves a real request routes THROUGH Traefik to Superset —
# the deploy labels being present in the manifest is not the same as the swarm provider
# actually discovering the service (issue #63).
if [ "$case" = "edge" ]; then
  # shellcheck source=/dev/null
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed superset.e2e.local /login/ 200
fi

exit 0
