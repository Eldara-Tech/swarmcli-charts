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

# Each probe is bounded (-m 25; a cold first request on a slow CI disk can exceed 10s, so we must not
# cut a valid-but-slow response), and the whole wait has a wall-clock deadline. rails' puma is already
# listening by the time convergence completes, so a healthy stack serves almost immediately — 10 min
# is ample, and a shorter budget gets us to the diagnostics faster. The heartbeat logs the OBSERVED
# status every ~2 min, so a failing run shows WHAT it got (000 unreachable / 502 / 503 / redirect),
# instead of the old black-box "never 200".
ok=0
code=""
deadline=$(( $(date +%s) + 600 ))   # 10 min wall-clock, hard
next_beat=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  code="$(curl -s -o /dev/null -m 25 -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then ok=1; break; fi
  now="$(date +%s)"
  if [ "$now" -ge "$next_beat" ]; then
    echo "   … waiting: ${url} -> ${code:-000}  ($(( (deadline - now) / 60 ))m left)"
    next_beat=$(( now + 120 ))
  fi
  sleep 10
done

if [ "$ok" -ne 1 ]; then
  echo "   FAIL: ${url} never returned 200 (last status: ${code:-000})"

  echo "   --- curl -v to the host published port (what does the edge actually answer?) ---"
  curl -sv -m 25 -o /dev/null "$url" 2>&1 | sed 's/^/      /' | tail -25 || true

  echo "   --- docker service ps: health / restarts / rejection reasons ---"
  for svc in init railsserver websocket scheduler nginx postgres redis memcached elasticsearch; do
    docker service ps --no-trunc "${release}_${svc}" 2>/dev/null | sed 's/^/      /' || true
  done

  # Probe rails DIRECTLY on the internal overlay (a throwaway curl container joins it), bypassing
  # nginx and the ingress routing mesh — this splits "app is broken" from "nginx/mesh is broken".
  echo "   --- rails direct on the internal overlay (bypasses nginx + routing mesh) ---"
  net="$(docker network ls --filter "name=${release}" --format '{{.Name}}' 2>/dev/null | grep -m1 internal || true)"
  if [ -n "$net" ]; then
    docker run --rm --network "$net" curlimages/curl:8.11.1 \
      -s -m 25 -o /dev/null -w 'railsserver:3000 -> %{http_code}\n' \
      "http://railsserver:3000/api/v1/getting_started" 2>&1 | sed 's/^/      /' || true
  fi

  echo "   --- service logs ---"
  for svc in init railsserver nginx elasticsearch postgres redis; do
    echo "      === ${svc} ==="
    docker service logs --tail 60 "${release}_${svc}" 2>&1 | sed 's/^/      /' || true
  done
  exit 1
fi
echo "   ok: ${url} -> 200 (nginx -> rails -> migrated database)"
exit 0
