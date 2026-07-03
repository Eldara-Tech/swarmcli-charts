#!/usr/bin/env bash
#
# Optional e2e smoke check for the redis chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# It is run once per fixture (default / no-auth / ephemeral / published-port), so
# it probes the running container instead of assuming auth or persistence: it
# locates the redis task container for service "<release>_redis" (a local e2e
# swarm is single-node) and `docker exec`s in, so it never needs the operator's
# password. Auth is detected by the presence of the mounted secret; persistence
# by the AOF directory on disk.
#
# PREREQUISITES for the default/auth fixtures (scripts/e2e-test.sh sets these up):
#   docker node update --label-add redis-data=true <node>
#   printf test | docker secret create redis_password -
set -euo pipefail

release="$1"
cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_redis" | head -1)"
[ -n "$cid" ] || { echo "  ${release}_redis container not found"; exit 1; }

# Build the redis-cli auth prefix only if a secret is actually mounted (auth on).
# The chart mounts exactly one secret; discover its name rather than assuming the
# default, so a fixture that overrides auth.secretName still works.
secret="$(docker exec "$cid" sh -c 'ls /run/secrets/ 2>/dev/null | head -1')"
if [ -n "$secret" ]; then
  pre='REDISCLI_AUTH="$(cat /run/secrets/'"$secret"')" '
else
  pre=''
fi

# Connectivity (+ auth).
docker exec "$cid" sh -c "${pre}redis-cli ping" | grep -q PONG

# Round-trip: SET then GET via the same auth.
docker exec "$cid" sh -c \
  "${pre}redis-cli set e2e:smoke ok >/dev/null && ${pre}redis-cli get e2e:smoke" \
  | grep -q '^ok$'

# Persistence: assert AOF on disk only when this fixture enabled it.
if docker exec "$cid" sh -c 'ls /data/appendonly* >/dev/null 2>&1'; then
  echo "  ${release}_redis: connectivity + set/get + AOF OK"
else
  echo "  ${release}_redis: connectivity + set/get OK (ephemeral)"
fi
