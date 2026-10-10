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
# With metrics on (the metrics / metrics-no-auth fixtures) it also scrapes the exporter
# from the monitoring overlay, where Prometheus would, and — with auth — proves the
# exporter's ACL user can read server state but no key and no CONFIG.
#
# PREREQUISITES for the default/auth fixtures (scripts/e2e-test.sh sets these up):
#   docker node update --label-add redis-data=true <node>
#   printf test | docker secret create redis_password -
#   printf test | docker secret create redis_exporter_password -   (metrics)
set -euo pipefail

release="$1"
case="${3:-}"
cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_redis" | sed -n 1p)"
[ -n "$cid" ] || { echo "  ${release}_redis container not found"; exit 1; }

# Build the redis-cli auth prefix only if a secret is actually mounted (auth on).
# The chart mounts the auth secret, plus the exporter's with metrics on; discover the
# auth secret's name rather than assuming the default, so a fixture that overrides
# auth.secretName still works.
secret="$(docker exec "$cid" sh -c 'ls /run/secrets/ 2>/dev/null | grep -v exporter | head -1')"
if [ -n "$secret" ]; then
  pre='REDISCLI_AUTH="$(cat /run/secrets/'"$secret"')" '
else
  pre=''
fi

# Connectivity (+ auth).
docker exec "$cid" sh -c "${pre}redis-cli ping" | grep PONG >/dev/null

# Round-trip: SET then GET via the same auth.
docker exec "$cid" sh -c \
  "${pre}redis-cli set e2e:smoke ok >/dev/null && ${pre}redis-cli get e2e:smoke" \
  | grep '^ok$' >/dev/null

# Metrics: the exporter answers on the monitoring overlay — where Prometheus would
# scrape it — sees redis (redis_up 1, a clean last scrape) and counts the SET above.
# Keyed on the fixture, never on what is deployed: a metrics fixture whose exporter is
# missing must fail, and so must an exporter in any other fixture.
metrics_ok=""
exporter="${release}_redis-exporter"
has_exporter=no
docker service inspect "$exporter" >/dev/null 2>&1 && has_exporter=yes
case "$case" in
  metrics|metrics-no-auth) want_exporter=yes ;;
  *) want_exporter=no ;;
esac
[ "$has_exporter" = "$want_exporter" ] \
  || { echo "  $exporter: exists=$has_exporter, but fixture '$case' expects $want_exporter"; exit 1; }
has_secret=no
docker exec "$cid" test -f /run/secrets/redis_exporter_password && has_secret=yes
[ "$has_secret" = "$([ "$case" = metrics ] && echo yes || echo no)" ] \
  || { echo "  ${release}_redis: exporter secret mounted=$has_secret in fixture '$case'"; exit 1; }
if [ "$want_exporter" = yes ]; then
  m=""
  for _ in $(seq 1 15); do
    m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://$exporter:9121/metrics" 2>&1 || true)"
    grep -x 'redis_up 1' <<<"$m" >/dev/null && break
    sleep 2
  done
  if ! grep -x 'redis_up 1' <<<"$m" >/dev/null; then
    echo "  $exporter: redis_up is not 1 on the monitoring overlay. Scrape and exporter log:"
    grep -E '^redis_up|^redis_exporter_last_scrape_error|^curl' <<<"$m" | sed 's/^/    /'
    docker service logs --tail 5 "$exporter" 2>&1 | sed 's/^/    /'
    exit 1
  fi
  grep -xF 'redis_exporter_last_scrape_error{err=""} 0' <<<"$m" >/dev/null \
    || { echo "  $exporter: the last scrape reported an error:"; grep '^redis_exporter_last_scrape_error' <<<"$m" | sed 's/^/    /'; exit 1; }
  grep -E '^redis_commands_total\{cmd="set"\} [1-9]' <<<"$m" >/dev/null \
    || { echo "  $exporter: redis_commands_total{cmd=\"set\"} does not count the smoke SET"; exit 1; }
  # A second scrape sees the first one's commands in INFO: none of them may have been
  # denied, or every ACL-denial and error-rate alert on this Redis fires for ever.
  m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://$exporter:9121/metrics" 2>&1 || true)"
  grep -x 'redis_acl_access_denied_cmd_total 0' <<<"$m" >/dev/null \
    || { echo "  $exporter: its scrapes are denied commands:"; grep -E '^redis_acl_access_denied_cmd_total|^redis_errors_total|^redis_commands_rejected_calls_total\{.*\} [1-9]' <<<"$m" | sed 's/^/    /'; exit 1; }
  code="$(docker run --rm --network monitoring curlimages/curl:latest -s -o /dev/null -w '%{http_code}' \
    "http://$exporter:9121/scrape?target=redis://example.invalid:6379" || true)"
  [ "$code" = "404" ] || { echo "  $exporter: /scrape answered $code, expected 404 (it must be disabled)"; exit 1; }
  metrics_ok=" + exporter on monitoring (redis_up 1, /scrape 404)"

  # With auth, the exporter's ACL user: logs in, reads INFO, and is refused a key and
  # CONFIG GET (which would hand it requirepass). Its password comes from the secret
  # redis mounts to hash it.
  if [ "$case" = metrics ]; then
    as_exp() { docker exec "$cid" sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_exporter_password)" redis-cli --no-auth-warning --user exporter '"$1" 2>&1; }
    out="$(as_exp 'info server')"
    grep -F 'redis_version:' <<<"$out" >/dev/null || { echo "  exporter user cannot run INFO: $out"; exit 1; }
    for cmd in 'get e2e:smoke' 'config get requirepass' 'keys *' 'flushall'; do
      out="$(as_exp "$cmd")"
      grep -F 'NOPERM' <<<"$out" >/dev/null || { echo "  exporter user was not refused '$cmd': $out"; exit 1; }
    done
    metrics_ok="$metrics_ok + 0 denied scrape commands + ACL user refused GET/CONFIG GET/KEYS/FLUSHALL"
  fi
fi

# Persistence: assert AOF on disk only when this fixture enabled it.
if docker exec "$cid" sh -c 'ls /data/appendonly* >/dev/null 2>&1'; then
  echo "  ${release}_redis: connectivity + set/get + AOF$metrics_ok OK"
else
  echo "  ${release}_redis: connectivity + set/get$metrics_ok OK (ephemeral)"
fi
