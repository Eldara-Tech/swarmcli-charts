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

# ── sentinel mode ─────────────────────────────────────────────────────────────────────
# Convergence proves little here: peers that each started as a master, or Sentinels that
# each watch a different one, all report healthy. So the check asserts one master named by
# every Sentinel with every other peer streaming from it, a write read back on every
# replica, the Sentinels' passwordless default user refused everything but discovery from
# another container on the overlay (where a client such as Harbor sits), and a restarted
# Sentinel rejoining under its own id. With persistence (`sentinel`) also a failover the old
# master rejoins as a replica, and a master whose volume was lost waiting for the Sentinels
# to promote a replica instead of starting empty and being copied. With metrics
# (`sentinel-metrics`) each peer's exporter, exactly one of them reporting a master.
case "$case" in
sentinel*)
  fail=0
  bad() { echo "  FAIL: $*"; fail=1; }
  count() { docker service ls --filter "label=com.docker.stack.namespace=$release" --format '{{.Name}}' | grep -c "^${release}_$1-[0-9]*\$" || true; }
  peers="$(count redis)"
  members="$(count sentinel)"
  if [ "$peers" -lt 2 ] || [ "$members" -lt 3 ]; then echo "  FAIL: found $peers peers and $members Sentinels"; exit 1; fi
  cid_of() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_$1" | sed -n 1p; }
  # redis-cli on peer N with the auth secret, on Sentinel N as the passwordless default user,
  # and on Sentinel N as admin. The password stays inside the container.
  peer() { local n="$1"; shift; docker exec "$(cid_of "redis-$n")" sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password)" exec redis-cli --no-auth-warning --raw "$@"' sh "$@"; }
  sen() { local n="$1"; shift; docker exec "$(cid_of "sentinel-$n")" redis-cli -p 26379 --raw "$@"; }
  sen_admin() { local n="$1"; shift; docker exec "$(cid_of "sentinel-$n")" sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password)" exec redis-cli -p 26379 --user admin --no-auth-warning --raw "$@"' sh "$@"; }
  repl() { peer "$1" info replication 2>/dev/null | tr -d '\r' | sed -n "s/^$2://p"; }
  # The master's peer number when every Sentinel names the same one, else nothing.
  agreed() {
    local n m first=""
    for n in $(seq 1 "$members"); do
      m="$(sen "$n" sentinel get-master-addr-by-name mymaster 2>/dev/null | sed -n 1p || true)"
      case "$m" in "${release}-redis-"[0-9]*) ;; *) return 0 ;; esac
      [ -n "$first" ] || first="$m"
      [ "$m" = "$first" ] || return 0
    done
    printf '%s' "${first##*-}"
  }
  # Waits up to $1 seconds for an agreed master with every other peer streaming from it, and
  # prints its peer number.
  settled() {
    local end=$(( $(date +%s) + $1 )) m r ok
    while [ "$(date +%s)" -lt "$end" ]; do
      m="$(agreed)"
      if [ -n "$m" ] && [ "$(repl "$m" role)" = master ] && [ "$(repl "$m" connected_slaves)" = "$((peers - 1))" ]; then
        ok=1
        for r in $(seq 1 "$peers"); do
          [ "$r" = "$m" ] && continue
          [ "$(repl "$r" master_host)" = "${release}-redis-$m" ] && [ "$(repl "$r" master_link_status)" = up ] || ok=0
        done
        [ "$ok" = 1 ] && { printf '%s' "$m"; return 0; }
      fi
      sleep 3
    done
    return 1
  }
  diag() {
    local svc
    for svc in $(docker stack services "$release" --format '{{.Name}}'); do
      echo "  --- $svc (tail 15)"; docker service logs --tail 15 "$svc" 2>&1 | sed 's/^/    /'
    done
  }
  # Waits up to $1 seconds until every Sentinel knows each other one exactly once.
  known() {
    local end=$(( $(date +%s) + $1 )) n ok
    while [ "$(date +%s)" -lt "$end" ]; do
      ok=1
      for n in $(seq 1 "$members"); do
        [ "$(sen "$n" sentinel sentinels mymaster 2>/dev/null | grep -c '^name$' || true)" = "$((members - 1))" ] || ok=0
      done
      [ "$ok" = 1 ] && return 0
      sleep 3
    done
    return 1
  }

  m="$(settled 180)" || { echo "  FAIL: the Sentinels never agreed on a master with all $((peers - 1)) replicas streaming"; diag; exit 1; }
  [ "$m" = 1 ] || bad "a first install's master is peer $m, not peer 1"
  known 60 || bad "the Sentinels do not each know the other $((members - 1)) exactly once"
  peer "$m" set e2e:k1 v1 >/dev/null
  [ "$(peer "$m" wait $((peers - 1)) 5000)" = "$((peers - 1))" ] || bad "the write did not reach every replica"
  for r in $(seq 1 "$peers"); do
    [ "$(peer "$r" get e2e:k1)" = v1 ] || bad "peer $r does not read back the write"
    if [ "$r" != "$m" ]; then
      out="$(peer "$r" set e2e:x y 2>&1 || true)"
      grep READONLY <<<"$out" >/dev/null || bad "replica peer $r accepted a write: $out"
    fi
  done

  # As a client on the overlay sees it, from a container of no stack.
  img="$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "${release}_sentinel-1" | sed 's/@.*//')"
  # Swarm pulled it by digest, untagged: pull the tag now, or the first `docker run` prints
  # its pull progress into the answer read below.
  docker pull -q "$img" >/dev/null
  cli() { docker run --rm --network redis-net "$img" redis-cli --raw "$@" 2>&1; }
  [ "$(cli -h "${release}-sentinel-1" -p 26379 sentinel get-master-addr-by-name mymaster | sed -n 1p)" = "${release}-redis-$m" ] \
    || bad "a client on redis-net cannot discover the master from ${release}-sentinel-1"
  for cmd in 'sentinel set mymaster quorum 1' 'sentinel monitor evil 127.0.0.1 6379 1' 'sentinel remove mymaster' \
      'sentinel failover mymaster' 'sentinel reset mymaster' 'sentinel config set resolve-hostnames no' 'acl list' 'info'; do
    # shellcheck disable=SC2086 # each command is several words
    out="$(cli -h "${release}-sentinel-1" -p 26379 $cmd)"
    grep NOPERM <<<"$out" >/dev/null || bad "the Sentinels' default user was not refused '$cmd': $out"
  done
  out="$(cli -h "${release}-redis-$m" get e2e:k1)"
  grep NOAUTH <<<"$out" >/dev/null || bad "the master answered a client without the password: $out"
  out="$(sen_admin 1 sentinel ckquorum mymaster 2>&1)"
  grep '^OK' <<<"$out" >/dev/null || bad "admin cannot run SENTINEL CKQUORUM: $out"

  # A Sentinel restarted (from its saved file, or ephemeral by asking the others) rejoins
  # under its own id: a new one would leave the others counting a ghost toward the majority.
  docker service update --detach --force "${release}_sentinel-1" >/dev/null
  sleep 15
  known 120 || bad "after sentinel-1 restarted, the Sentinels do not each know the other $((members - 1)) exactly once"
  [ "$(agreed)" = "$m" ] || bad "after sentinel-1 restarted, the Sentinels do not agree on peer $m"

  if [ "$case" = sentinel ]; then
    # Failover: the master stops; a replica is promoted, and the old master returns as one.
    old="$m"
    f0="$fail"; fail=0
    docker service scale --detach "${release}_redis-$old=0" >/dev/null
    new=""
    for _ in $(seq 1 60); do new="$(agreed)"; [ -n "$new" ] && [ "$new" != "$old" ] && break; sleep 3; done
    if [ -z "$new" ] || [ "$new" = "$old" ]; then
      bad "no replica was promoted after the master stopped"
    else
      peer "$new" set e2e:k2 v2 >/dev/null
      docker service scale --detach "${release}_redis-$old=1" >/dev/null
      m="$(settled 180)" || bad "peer $old did not rejoin as a replica of peer $new"
      [ "$(peer "$old" get e2e:k2)" = v2 ] || bad "peer $old does not have the write made on peer $new"
      [ "$fail" = 0 ] && echo "  failover: peer $old -> peer $new, peer $old rejoined as a replica"
    fi
    fail=$((fail | f0))

    # A master whose volume was lost comes back before the Sentinels notice it went. It must
    # wait for them to promote a replica, not start empty and have every replica copy it.
    vic="$(agreed)"
    f0="$fail"; fail=0
    docker service scale --detach "${release}_redis-$vic=0" >/dev/null
    for _ in $(seq 1 30); do [ -z "$(cid_of "redis-$vic")" ] && break; sleep 1; done
    docker ps -aq -f "label=com.docker.swarm.service.name=${release}_redis-$vic" | xargs docker rm -f >/dev/null 2>&1 || true
    docker volume rm "${release}_redis-data-$vic" >/dev/null || bad "could not remove peer $vic's volume"
    docker service scale --detach "${release}_redis-$vic=1" >/dev/null
    m="$(settled 240)" || bad "the cluster did not settle after peer $vic lost its volume"
    [ "$m" != "$vic" ] || bad "peer $vic came back empty and is master again"
    docker service logs "${release}_redis-$vic" 2>&1 | grep 'waiting for them to promote one' >/dev/null \
      || bad "peer $vic never waited for a promotion (it came back after the failover, so this run proves nothing about it)"
    for r in $(seq 1 "$peers"); do
      [ "$(peer "$r" get e2e:k2)" = v2 ] || bad "peer $r lost e2e:k2: the empty peer was copied"
    done
    [ "$fail" = 0 ] && echo "  lost volume: peer $vic waited, peer $m was promoted, no key lost"
    fail=$((fail | f0))
  fi

  if [ "$case" = sentinel-metrics ]; then
    masters=0
    for n in $(seq 1 "$peers"); do
      body=""
      for _ in $(seq 1 15); do
        body="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://${release}_redis-exporter-$n:9121/metrics" 2>&1 || true)"
        grep -x 'redis_up 1' <<<"$body" >/dev/null && break
        sleep 2
      done
      grep -x 'redis_up 1' <<<"$body" >/dev/null || bad "redis-exporter-$n does not report redis_up 1"
      if grep -E '^redis_instance_info\{.*role="master"' <<<"$body" >/dev/null; then
        masters=$((masters + 1))
      else
        grep -E '^redis_master_link_up\{.*\} 1$' <<<"$body" >/dev/null || bad "redis-exporter-$n reports a replica whose link is not up"
      fi
    done
    [ "$masters" = 1 ] || bad "$masters exporters report a master, expected 1"
    chart="$(cd "$2" && pwd)"
    prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart/../prometheus-stack/Chart.yaml")"
    if ! out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "${REDIS_E2E_PROMTOOL_IMAGE:-prom/prometheus:${prom_tag:?}}" \
        test rules /chart/ci/redis-rules-test.yml 2>&1)"; then
      bad "promtool test rules fails: $out"
    fi
  fi

  [ "$fail" = 0 ] || { diag; exit 1; }
  echo "  ${release}: master peer $m, $((peers - 1)) replicas streaming, $members Sentinels agreeing, default user refused, restart rejoined OK"
  exit 0
  ;;
esac
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

    # The alert rules the chart ships for operators to load (monitoring/), checked here
    # because nothing deploys them: their logic, under the promtool of a pinned Prometheus.
    # The image follows prometheus-stack's appVersion, which Renovate keeps current.
    chart="$(cd "$2" && pwd)"
    prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart/../prometheus-stack/Chart.yaml")"
    promtool_image="${REDIS_E2E_PROMTOOL_IMAGE:-prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}}"
    if ! out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "$promtool_image" \
        test rules /chart/ci/redis-rules-test.yml 2>&1)"; then
      echo "  promtool test rules fails on monitoring/redis-rules.yml:"
      echo "$out" | sed 's/^/    /'
      exit 1
    fi
    metrics_ok="$metrics_ok + alert rules pass promtool"
  fi
fi

# Persistence: assert AOF on disk only when this fixture enabled it.
if docker exec "$cid" sh -c 'ls /data/appendonly* >/dev/null 2>&1'; then
  echo "  ${release}_redis: connectivity + set/get + AOF$metrics_ok OK"
else
  echo "  ${release}_redis: connectivity + set/get$metrics_ok OK (ephemeral)"
fi
