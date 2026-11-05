#!/usr/bin/env bash
#
# e2e smoke check for the mariadb-galera chart. scripts/e2e-test.sh runs this after
# the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence alone is a WEAK signal for a cluster: three peers that each formed
# their own single-node cluster would all report healthy and all look identical
# from outside. So this asserts the three things that can only be true of a real
# cluster:
#
#   1. wsrep_cluster_size equals the number of peer services. Peers 2..N start with
#      an empty data dir and can only reach Synced by pulling a full state transfer
#      from the peer that bootstrapped — so this one number also proves the
#      mariadb-backup SST and its passwordless unix_socket account work. If the SST
#      account were wrong, size would stay at 1 and the joiners would never converge.
#   2. Every peer reports Synced, not Donor/Desynced or Joining.
#   3. A row written on the FIRST peer is readable on the LAST one, which is
#      replication actually working rather than just membership. The reader sets
#      wsrep_sync_wait=1 so the SELECT waits for its node to apply everything
#      already committed cluster-wide — without it a read on another node races the
#      apply queue and this check would flake.
#
# PREREQUISITES (ci/e2e-setup.sh provisions these):
#   printf test | docker secret create mariadb_galera_root_password -
#   printf test | docker secret create mariadb_galera_password -
#   printf test | docker secret create mariadb_galera_exporter_password -
#   docker node update --label-add mariadb-galera-<N>=true <node>   (N = 1..5)
set -Eeuo pipefail
# A command that fails without printing anything would otherwise end the check with
# no clue where; -E carries this into functions and command substitutions.
trap 'echo "  e2e-check.sh:$LINENO: exit $? from: $BASH_COMMAND" >&2' ERR

release="$1"
case="${3:-}"

# Peer services, in peer order, discovered from the stack rather than assumed, so
# this works for the 3- and 5-peer fixtures alike.
all_svcs="$(docker service ls --filter "label=com.docker.stack.namespace=${release}" --format '{{.Name}}' | sort)"
[ -n "$all_svcs" ] || { echo "  no services found for stack ${release}"; exit 1; }
# The proxy and the metrics services are in this stack but are NOT peers: counting
# them would make `want` too large and then try to run SQL inside HAProxy.
peers="$(printf '%s\n' "$all_svcs" | { grep -E -- '_mariadb-galera-[0-9]+$' || true; })"
[ -n "$peers" ] || { echo "  no peer services found for stack ${release}"; exit 1; }
want="$(printf '%s\n' "$peers" | wc -l | tr -d ' ')"
# The expected size is derived from the stack, so it must be sanity-checked against
# what a cluster can even be — otherwise a stack that came up with only one peer
# would set want=1 and then "cluster_size == want" would PASS on a single peer that
# had bootstrapped alone, which is the exact failure this check exists to catch.
if [ "$want" -lt 3 ]; then
  echo "  only $want peer service(s) in stack ${release}; a cluster is at least 3"
  exit 1
fi

cid_of() {
  docker ps -q -f "label=com.docker.swarm.service.name=$1" | sed -n 1p
}

# Run SQL as root, reading the password from the mounted secret via MYSQL_PWD so it
# never lands on a command line. The statement travels in an env var to keep the
# quoting flat.
q() {
  docker exec -e "SQL=$2" "$1" sh -c \
    'MYSQL_PWD="$(cat /run/secrets/mariadb_galera_root_password)" mariadb -uroot -N -B -e "$SQL"'
}

status_of() {
  q "$1" "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='$2'"
}

first=""
last=""
for svc in $peers; do
  cid="$(cid_of "$svc")"
  [ -n "$cid" ] || { echo "  $svc: no running container"; exit 1; }
  [ -n "$first" ] || first="$cid"
  last="$cid"

  size="$(status_of "$cid" 'WSREP_CLUSTER_SIZE')"
  if [ "$size" != "$want" ]; then
    echo "  $svc: wsrep_cluster_size is $size, expected $want — the peers did not form ONE cluster"
    echo "  (size 1 on every peer means each bootstrapped alone; check the state-transfer account)"
    exit 1
  fi

  state="$(status_of "$cid" 'WSREP_LOCAL_STATE_COMMENT')"
  if [ "$state" != "Synced" ]; then
    echo "  $svc: wsrep_local_state_comment is '$state', expected 'Synced'"
    exit 1
  fi
done

# Replication round-trip: write on the first peer, read on the last.
q "$first" "CREATE DATABASE IF NOT EXISTS e2e_galera;
  CREATE TABLE IF NOT EXISTS e2e_galera.t (id INT PRIMARY KEY, v VARCHAR(16));
  REPLACE INTO e2e_galera.t VALUES (1, 'replicated');" >/dev/null

got="$(q "$last" "SET SESSION wsrep_sync_wait=1; SELECT v FROM e2e_galera.t WHERE id = 1")"
if [ "$got" != "replicated" ]; then
  echo "  write on the first peer did not reach the last one (read back: '$got')"
  exit 1
fi

# With the metrics fixture: every exporter answers on the metrics overlay — where
# Prometheus would scrape it — logged in as the user the one-shot created (`--wait`
# only returns once that one-shot completed), sees the whole cluster, and every
# default collector succeeds. A missing grant shows up only as a collector failing,
# never as mysql_up 0, which is why the collectors are checked one by one.
metrics_ok=""
exporters="$(printf '%s\n' "$all_svcs" | { grep -E -- '-exporter-[0-9]+$' || true; })"
if [ -n "$exporters" ]; then
  n_exp="$(printf '%s\n' "$exporters" | wc -l | tr -d ' ')"
  [ "$n_exp" = "$want" ] || { echo "  $n_exp exporter(s) for $want peers"; exit 1; }
  for e in $exporters; do
    m=""
    for _ in $(seq 1 15); do
      m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://$e:9104/metrics" 2>&1 || true)"
      grep -qx 'mysql_up 1' <<<"$m" && break
      sleep 2
    done
    if ! grep -qx 'mysql_up 1' <<<"$m"; then
      echo "  $e: mysql_up is not 1 on the metrics overlay. Scrape and exporter log:"
      grep -E '^mysql_up|^curl' <<<"$m" | sed 's/^/    /'
      docker service logs --tail 5 "$e" 2>&1 | sed 's/^/    /'
      exit 1
    fi
    size="$(sed -n 's/^mysql_global_status_wsrep_cluster_size //p' <<<"$m")"
    [ "$size" = "$want" ] || { echo "  $e: mysql_global_status_wsrep_cluster_size is '$size', expected $want"; exit 1; }
    failed="$(grep -E '^mysql_exporter_collector_success\{.*\} 0$' <<<"$m" || true)"
    [ -z "$failed" ] || { echo "  $e: collectors failing (a missing grant):"; echo "$failed" | sed 's/^/    /'; exit 1; }
  done
  # The alert rules the chart ships for operators to load (monitoring/), checked here
  # because nothing deploys them: their logic, under the promtool of a pinned Prometheus.
  chart="$(cd "$2" && pwd)"
  prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart/../prometheus-stack/Chart.yaml")"
  promtool_image="${GALERA_E2E_PROMTOOL_IMAGE:-prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}}"
  if ! out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "$promtool_image" \
      test rules /chart/ci/galera-rules-test.yml 2>&1)"; then
    echo "  promtool test rules fails on monitoring/galera-rules.yml:"
    echo "$out" | sed 's/^/    /'
    exit 1
  fi
  metrics_ok=", $n_exp exporters scraped on monitoring, alert rules pass promtool"
fi

# With the single-writer fixture: every proxy replica sends every connection to the
# lowest-numbered Synced peer, and a connection held open across a change of writer
# is closed rather than left on the old one. Driven through the writer's loss, the
# next peer's loss too, the return of that next peer while the last one stands in (the
# return HAProxy's own options leave connections behind on), and the writer's own
# return. Then an app in a stack of its own reaches the proxy over the overlay with
# no port published.
if [ "$case" = single-writer ]; then
  proxy="$(printf '%s\n' "$all_svcs" | { grep -E -- '-proxy$' || true; })"
  [ -n "$proxy" ] || { echo "  no proxy service in stack ${release}"; exit 1; }
  net="$(docker service inspect "$proxy" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}}{{end}}' | sed -n 1p)"
  netname="$(docker network inspect --format '{{.Name}}' "$net")"
  pw="$(docker exec "$first" sh -c 'cat /run/secrets/mariadb_galera_root_password')"
  p1="$(printf '%s\n' $peers | sed -n 1p)"; h1="${p1##*_}"
  p2="$(printf '%s\n' $peers | sed -n 2p)"; h2="${p2##*_}"
  p3="$(printf '%s\n' $peers | sed -n 3p)"; h3="${p3##*_}"
  app="${release}-app"
  trap 'docker rm -f $(docker ps -aq -f "label=e2e-galera-held=$release") >/dev/null 2>&1; docker stack rm "$app" >/dev/null 2>&1 || true' EXIT
  proxy_log() {
    for c in $(docker ps -q -f "label=com.docker.swarm.service.name=$proxy"); do
      echo "    proxy container $c:"
      docker logs "$c" 2>&1 | { grep -vE '^[0-9.]+:[0-9]+ \[' || true; } | tail -n 20 | sed 's/^/      /'
    done
  }
  stop_peer() {
    docker service scale --detach "$1=0" >/dev/null
    for _ in $(seq 1 60); do
      [ -z "$(cid_of "$1")" ] && return 0
      sleep 2
    done
    echo "  $1: did not stop"; exit 1
  }
  start_peer() {
    local c state=""
    docker service scale --detach "$1=1" >/dev/null
    for _ in $(seq 1 90); do
      c="$(cid_of "$1")"
      state="$( [ -n "$c" ] && status_of "$c" 'WSREP_LOCAL_STATE_COMMENT' 2>/dev/null || true)"
      [ "$state" = Synced ] && return 0
      sleep 5
    done
    echo "  $1: did not rejoin (state '$state')"; exit 1
  }
  # The peer each proxy replica sends a new connection to, asked of each task directly.
  writers() {
    local c ip
    for c in $(docker ps -q -f "label=com.docker.swarm.service.name=$proxy"); do
      ip="$(docker inspect --format "{{(index .NetworkSettings.Networks \"$netname\").IPAddress}}" "$c")"
      docker run --rm --network "$net" -e MYSQL_PWD="$pw" mariadb:12.3 \
        mariadb -h "$ip" -uroot -N -B -e 'SELECT @@hostname' 2>&1 || true
    done
  }
  routes_to() {  # routes_to <peer host> <when>: every replica, within 60s
    local got=""
    for _ in $(seq 1 30); do
      got="$(writers | sort -u | tr '\n' ' ')"
      [ "$got" = "$1 " ] && return 0
      sleep 2
    done
    echo "  $2: the proxy replicas route to '$got', expected $1 from every one"
    proxy_log; exit 1
  }
  # Opens a connection through the client alias and holds it open; prints its container.
  hold() {
    local c
    c="$(docker run -d --label "e2e-galera-held=$release" --network "$net" -e MYSQL_PWD="$pw" mariadb:12.3 \
      mariadb --unbuffered -h mariadb -uroot -N -B -e 'SELECT @@hostname; SELECT SLEEP(3600)')"
    for _ in $(seq 1 15); do
      [ -n "$(docker logs "$c" 2>&1)" ] && break
      sleep 1
    done
    echo "$c"
  }
  on() {  # on <held container> <peer host>
    local got
    got="$(docker logs "$1" 2>&1 | sed -n 1p)"
    [ "$got" = "$2" ] || { echo "  a connection opened through the proxy landed on '$got', expected $2"; proxy_log; exit 1; }
  }
  closed() {  # closed <held container> <when>: within 30s
    for _ in $(seq 1 30); do
      [ "$(docker inspect --format '{{.State.Running}}' "$1")" = false ] && return 0
      sleep 1
    done
    echo "  $2: a connection held open to the old writer was not closed"; proxy_log; exit 1
  }
  # The Lua task, not the peer, closed what was left on <from>: a stopped peer drops its
  # own connections, so a closed one alone proves nothing about the proxy.
  lua_closed() {  # lua_closed <from host> <writer host> <when>
    local c
    for c in $(docker ps -q -f "label=com.docker.swarm.service.name=$proxy"); do
      docker logs "$c" 2>&1 | grep -E "single-writer: closing [0-9]+ connection\(s\) to $1; the writer is $2" >/dev/null && return 0
    done
    echo "  $3: no proxy replica logged closing the connections left on $1"; proxy_log; exit 1
  }
  # The events controller keeps the listed event on the peer the proxy writes to. It
  # runs every second and records which peer ran it. A second event, disabled on purpose
  # and not listed, must never run anywhere. Both belong to the app user, which every
  # move of the event must keep as its definer.
  ctl="$(printf '%s\n' "$all_svcs" | { grep -E -- '-events$' || true; })"
  [ -n "$ctl" ] || { echo "  no events controller in stack ${release}"; exit 1; }
  ctl_log() { docker service logs --raw "$ctl" 2>&1 | tail -n 15 | sed 's/^/    /'; }
  ticks_on() {  # ticks_on <svc> <peer host> <when>: the event's last 3s, asked of <svc>
    local got=""
    for _ in $(seq 1 20); do
      got="$(q "$(cid_of "$1")" "SELECT IFNULL(GROUP_CONCAT(DISTINCT peer ORDER BY peer), '') FROM e2e_galera.ticks WHERE at > NOW(6) - INTERVAL 3 SECOND" 2>/dev/null || true)"
      [ "$got" = "$2" ] && return 0
      sleep 2
    done
    echo "  $3: the event ran on '$got' in the last 3s, expected $2 alone, the peer the proxy writes to"; ctl_log; exit 1
  }
  q "$(cid_of "$p1")" "CREATE TABLE e2e_galera.ticks (id INT AUTO_INCREMENT PRIMARY KEY, peer VARCHAR(64) NOT NULL, at DATETIME(6) NOT NULL DEFAULT NOW(6));
    GRANT ALL ON e2e_galera.* TO 'app'@'%';
    CREATE DEFINER = 'app'@'%' EVENT e2e_galera.tick ON SCHEDULE EVERY 1 SECOND DO INSERT INTO e2e_galera.ticks (peer) VALUES (@@hostname);
    CREATE DEFINER = 'app'@'%' EVENT e2e_galera.off ON SCHEDULE EVERY 1 SECOND DISABLE DO INSERT INTO e2e_galera.ticks (peer) VALUES ('off')" >/dev/null

  routes_to "$h1" "after install"
  ticks_on "$p1" "$h1" "after install"
  # A writer that stays up but is not Synced: desynced, as a donor is. mariadbd keeps a
  # connection to it open, so only the proxy can close it, and the event must move too.
  c0="$(hold)"; on "$c0" "$h1"
  q "$(cid_of "$p1")" 'SET GLOBAL wsrep_desync = ON' >/dev/null
  closed "$c0" "after $h1 desynced"
  routes_to "$h2" "with $h1 desynced"
  ticks_on "$p2" "$h2" "with $h1 desynced"
  c0="$(hold)"; on "$c0" "$h2"
  q "$(cid_of "$p1")" 'SET GLOBAL wsrep_desync = OFF' >/dev/null
  closed "$c0" "after $h1 was Synced again"
  lua_closed "$h2" "$h1" "after $h1 was Synced again"
  routes_to "$h1" "after $h1 was Synced again"
  ticks_on "$p1" "$h1" "after $h1 was Synced again"
  c1="$(hold)"; on "$c1" "$h1"
  stop_peer "$p1"
  closed "$c1" "after $h1 stopped"
  routes_to "$h2" "with $h1 stopped"
  ticks_on "$p2" "$h2" "with $h1 stopped"
  c2="$(hold)"; on "$c2" "$h2"
  stop_peer "$p2"
  closed "$c2" "after $h2 stopped"
  routes_to "$h3" "with $h1 and $h2 stopped"
  ticks_on "$p3" "$h3" "with $h1 and $h2 stopped"
  c3="$(hold)"; on "$c3" "$h3"
  start_peer "$p2"
  closed "$c3" "after $h2 came back while $h3 stood in"
  lua_closed "$h3" "$h2" "after $h2 came back while $h3 stood in"
  routes_to "$h2" "after $h2 came back"
  ticks_on "$p2" "$h2" "after $h2 came back"
  c4="$(hold)"; on "$c4" "$h2"
  start_peer "$p1"
  closed "$c4" "after $h1 came back"
  lua_closed "$h2" "$h1" "after $h1 came back"
  routes_to "$h1" "after $h1 came back"
  ticks_on "$p1" "$h1" "after $h1 came back"

  # A full state transfer from the writer, its preferred donor in this fixture: the
  # writer is not Synced while it donates, and the rebuilt peer arrives holding the
  # writer's ENABLED copy of the event. Neither may run it twice.
  stop_peer "$p3"
  for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$p3"); do docker rm -f "$c" >/dev/null; done
  docker volume rm "$(docker volume ls -q --filter "label=com.docker.stack.namespace=${release}" | sort | tail -1)" >/dev/null
  start_peer "$p3"
  docker logs "$(cid_of "$p3")" 2>&1 | grep -E "Selected [0-9]+\.[0-9]+ \($h1\)" >/dev/null \
    || { echo "  $p3 did not take its state from $h1, so the donor step tests nothing"; exit 1; }
  routes_to "$h1" "after $p3 was rebuilt from $h1"
  ticks_on "$p1" "$h1" "after $p3 was rebuilt from $h1"

  # Through all four changes of writer: never two peers in the same second, the disabled
  # event never ran, and the definer is still the app user on every peer.
  got="$(q "$(cid_of "$p1")" "SET SESSION wsrep_sync_wait=1; SELECT COUNT(*) FROM (SELECT FLOOR(UNIX_TIMESTAMP(at)) s FROM e2e_galera.ticks GROUP BY s HAVING COUNT(DISTINCT peer) > 1) d")"
  [ "$got" = 0 ] || { echo "  in $got second(s) the event ran on two peers at once"; ctl_log; exit 1; }
  got="$(q "$(cid_of "$p1")" "SELECT COUNT(*) FROM e2e_galera.ticks WHERE peer = 'off'")"
  [ "$got" = 0 ] || { echo "  the event disabled on purpose ran $got time(s)"; ctl_log; exit 1; }
  for p in $peers; do
    got="$(q "$(cid_of "$p")" "SELECT GROUP_CONCAT(DISTINCT DEFINER) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'e2e_galera'")"
    [ "$got" = 'app@%' ] || { echo "  $p: the events' definer is '$got', expected app@%"; exit 1; }
  done
  docker service logs --raw "$ctl" 2>&1 | grep -F 'e2e_galera.tick was due at' >/dev/null \
    || { echo "  the controller logged no run that fell due while the writer was lost"; ctl_log; exit 1; }
  # Its state where Prometheus would scrape it: through the relay, on the metrics overlay.
  # Polled, because the pass that moves an event counts it misplaced until the next one.
  m=""
  for _ in $(seq 1 10); do
    m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://${ctl}-metrics:9104/metrics" 2>&1 || true)"
    grep -Fx 'mariadb_galera_events_writer_peer 1' <<<"$m" >/dev/null \
      && grep -Fx 'mariadb_galera_events_misplaced 0' <<<"$m" >/dev/null && break
    sleep 3
  done
  # Turning it off on a peer that is shutting down may fail, harmlessly; turning it on
  # on the writer must not.
  if docker service logs --raw "$ctl" 2>&1 | grep -F 'could not turn it on' >/dev/null; then
    echo "  the controller failed to turn the event on on a writer:"; ctl_log; exit 1
  fi
  for want_m in 'mariadb_galera_events_writer_peer 1' 'mariadb_galera_events_misplaced 0'; do
    grep -Fx "$want_m" <<<"$m" >/dev/null || { echo "  the controller's metrics lack '$want_m':"; grep -v '^#' <<<"$m" | sed 's/^/    /'; exit 1; }
  done
  got="$(sed -n 's/^mariadb_galera_events_takeovers_total //p' <<<"$m")"
  [ "${got:-0}" -ge 6 ] || { echo "  the controller counted '$got' takeovers through six changes of writer"; exit 1; }

  # An app in a stack of its own, as a user deploys one: the client alias over the
  # shared overlay, its password from the secret. The chart publishes no port.
  for s in $all_svcs; do
    [ "$(docker service inspect --format '{{len .Spec.EndpointSpec.Ports}}' "$s")" = 0 ] \
      || { echo "  $s publishes a port; this case must reach the cluster without one"; exit 1; }
  done
  docker stack deploy --detach=true -c - "$app" >/dev/null <<EOF
version: "3.9"
services:
  client:
    image: mariadb:12.3
    entrypoint: ["/bin/sh", "-c"]
    command:
      - 'export MYSQL_PWD="\$\$(cat /run/secrets/mariadb_galera_root_password)"; until mariadb -h mariadb -uroot -N -B -e "SELECT @@hostname"; do sleep 2; done; sleep 3600'
    networks: [galera]
    secrets: [mariadb_galera_root_password]
    deploy:
      restart_policy: { condition: none }
networks:
  galera:
    external: true
    name: $netname
secrets:
  mariadb_galera_root_password:
    external: true
EOF
  got=""
  for _ in $(seq 1 45); do
    got="$(docker service logs --raw "${app}_client" 2>/dev/null | grep -vE '^ERROR' | sed -n 1p || true)"
    [ -n "$got" ] && break
    sleep 2
  done
  [ "$got" = "$h1" ] || { echo "  an app in stack $app reached '$got' through the overlay, expected the writer $h1"; docker service logs --tail 5 "${app}_client" 2>&1 | sed 's/^/    /'; exit 1; }

  echo "  ${release}: $want peers, all Synced, every proxy replica routed to the lowest-numbered Synced peer through a desync, two failures and their returns, closing each connection held open to an old writer, the listed event followed it with never two peers at once and the disabled one never ran, and an app stack reached it over the overlay with no port published$metrics_ok OK"
  exit 0
fi

# With the slow-sst fixture: a joiner whose state transfer outlasts the healthcheck's
# window (startPeriod + interval x retries) keeps its task and reaches Synced, and the
# proxy routes it no connection before then, though Swarm publishes it in DNS for the
# whole transfer. The donors' mariadb-backup is throttled for this one transfer, so it
# is long without a large dataset. Peer 3 is kept out of DNS until every proxy replica
# has put it in maintenance, so it comes back the way that, without init-state down,
# HAProxy counts up before its first check.
if [ "$case" = slow-sst ]; then
  proxy="$(printf '%s\n' "$all_svcs" | { grep -E -- '-proxy$' || true; })"
  [ -n "$proxy" ] || { echo "  no proxy service in stack ${release}"; exit 1; }
  net="$(docker service inspect "$proxy" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}}{{end}}' | sed -n 1p)"
  pw="$(docker exec "$first" sh -c 'cat /run/secrets/mariadb_galera_root_password')"
  p3="$(printf '%s\n' $peers | tail -n 1)"; h3="${p3##*_}"
  window="$(docker service inspect "$p3" --format '{{json .Spec.TaskTemplate.ContainerSpec.Healthcheck}}' \
    | jq '(.StartPeriod + .Interval * .Retries) / 1000000000 | floor')"
  trap 'docker rm -f $(docker ps -aq -f "label=e2e-galera-client=$release") >/dev/null 2>&1 || true' EXIT
  replicas() { docker ps -q -f "label=com.docker.swarm.service.name=$proxy"; }
  # What a proxy replica logged about peer 3 since this case began, client connections
  # left out: its address, maintenance, and every UP/DOWN with its reason.
  h3_events() {
    docker logs "$1" 2>&1 | tail -n +"$(($(sed -n "s/^$1 //p" <<<"$marks") + 1))" \
      | { grep -vE '^[0-9.]+:[0-9]+ \[' || true; } | { grep -F "galera/$h3 " || true; }
  }
  proxy_seen() { for c in $(replicas); do echo "    proxy container $c:"; h3_events "$c" | tail -n 20 | sed 's/^/      /'; done; }
  # The healthcheck's own condition, asked of the joiner itself.
  receiving() {
    docker exec "$1" sh -c "test -e /var/lib/mysql/sst_in_progress && pgrep -f 'wsrep_sst_[m]ariabackup --role joiner' >/dev/null" 2>/dev/null
  }

  for p in $peers; do
    [ "$p" = "$p3" ] || docker exec "$(cid_of "$p")" sh -c \
      'printf "[sst]\ninno-backup-opts=--throttle=4\n" > /etc/mysql/conf.d/zz-e2e-throttle.cnf'
  done
  marks="$(for c in $(replicas); do echo "$c $(docker logs "$c" 2>&1 | wc -l | tr -d ' ')"; done)"
  docker service scale --detach "$p3=0" >/dev/null
  for _ in $(seq 1 60); do
    n=0; gone=0
    for c in $(replicas); do
      n=$((n + 1))
      h3_events "$c" | grep -F 'maintenance' >/dev/null && gone=$((gone + 1))
    done
    [ "$n" -gt 0 ] && [ "$gone" = "$n" ] && break
    sleep 2
  done
  [ "$n" -gt 0 ] && [ "$gone" = "$n" ] \
    || { echo "  $gone of $n proxy replicas put $h3 in maintenance after it left DNS"; proxy_seen; exit 1; }

  # A client asking through the proxy every 0.2s which peer answers, and in what state.
  client="$(docker run -d --label "e2e-galera-client=$release" --network "$net" -e MYSQL_PWD="$pw" \
    --entrypoint bash mariadb:12.3 -c 'while :; do
      if o="$(mariadb -h mariadb -uroot --connect-timeout=3 -N -B -e "SELECT @@hostname, VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = '"'"'WSREP_LOCAL_STATE'"'"'" 2>&1)"
      then echo "ok $o" | tr "\t" " "; else echo "err $o" | sed -n 1p; fi
      sleep 0.2
    done')"

  docker service scale --detach "$p3=1" >/dev/null
  tasks=""; state=""; t0=""; t1=""; t2=""; dns_mid=no
  for _ in $(seq 1 300); do
    t="$(docker service ps -q --filter desired-state=running "$p3" | sed -n 1p)"
    [ -z "$t" ] || [[ " $tasks " == *" $t "* ]] || tasks="$tasks $t"
    [ "$(echo $tasks | wc -w | tr -d ' ')" -le 1 ] || break
    c="$(cid_of "$p3")"
    if [ -n "$c" ]; then
      if receiving "$c"; then
        [ -n "$t0" ] || t0=$SECONDS
        if docker exec "$client" getent hosts "tasks.${release}_$h3" >/dev/null && receiving "$c"; then dns_mid=yes; fi
      elif [ -n "$t0" ] && [ -z "$t1" ]; then
        t1=$SECONDS
      fi
      state="$(status_of "$c" 'WSREP_LOCAL_STATE_COMMENT' 2>/dev/null || true)"
      [ "$state" = Synced ] && { t2=$SECONDS; break; }
    fi
    sleep 2
  done
  synced_after=""; [ -z "$t2" ] || synced_after=", Synced $((t2 - ${t1:-$t2}))s after it"
  echo "  $p3: transfer seen for $(( ${t1:-$SECONDS} - ${t0:-$SECONDS} ))s$synced_after, task(s):$tasks, state '$state'"
  [ "$(echo $tasks | wc -w | tr -d ' ')" = 1 ] \
    || { echo "  Swarm replaced $p3 during its transfer:$tasks"; docker service ps --no-trunc --format '    {{.Name}} {{.CurrentState}} {{.Error}}' "$p3" | sed -n 1,5p; exit 1; }
  [ "$state" = Synced ] || { echo "  $p3 did not reach Synced"; docker logs --tail 20 "$(cid_of "$p3")" 2>&1 | sed 's/^/    /'; exit 1; }
  [ -n "$t0" ] && [ -n "$t1" ] || { echo "  never saw $p3 receive a transfer, so this case tests nothing"; exit 1; }
  [ $((t1 - t0)) -gt "$window" ] \
    || { echo "  the transfer took $((t1 - t0))s, within the healthcheck's ${window}s window, so this case tests nothing"; exit 1; }
  [ "$dns_mid" = yes ] \
    || { echo "  tasks.${release}_$h3 never resolved mid-transfer, so the proxy was never offered the joiner"; exit 1; }

  # Peer 3, Synced, takes connections: proof the client would have seen it earlier.
  for _ in $(seq 1 30); do
    docker logs "$client" 2>&1 | grep -E "^ok $h3 " >/dev/null && break
    sleep 1
  done
  log="$(docker logs "$client" 2>&1)"
  docker rm -f "$client" >/dev/null
  grep -E "^ok $h3 " <<<"$log" >/dev/null || { echo "  $h3 got no connection through the proxy after it was Synced"; proxy_seen; exit 1; }
  # A donor answers for the few seconds the proxy takes to mark it down; it is writable
  # throughout. Only an error, or peer 3 answering before Synced, is a failure.
  bad="$(grep -E "^err |^ok $h3 [^4]" <<<"$log" || true)"
  [ -z "$bad" ] || { echo "  through the proxy, a client failed or reached $h3 before it was Synced:"; sort <<<"$bad" | uniq -c | sed -n 1,5p | sed 's/^/    /'; proxy_seen; exit 1; }
  # Each replica marked peer 3 up first on a passed check, the Synced responder's 200,
  # never on its return to DNS.
  for c in $(replicas); do
    first_up="$(h3_events "$c" | grep -F ' is UP' | sed -n 1p || true)"
    grep -F 'check passed' <<<"$first_up" >/dev/null \
      || { echo "  proxy container $c marked $h3 up other than by a passed check: '$first_up'"; proxy_seen; exit 1; }
  done
  echo "  ${release}: $want peers, all Synced, cross-peer write replicated, $h3 received a $((t1 - t0))s state transfer (window ${window}s) while in DNS without Swarm replacing it, and the proxy sent it $(grep -cE "^ok $h3 " <<<"$log") of $(wc -l <<<"$log" | tr -d ' ') queries, every one once Synced$metrics_ok OK"
  exit 0
fi

# With the proxy fixture, the thing worth proving is not that the cluster formed —
# the assertions above already did that — but that the CLIENT ENDPOINT keeps
# working while a peer is gone. That is the claim the proxy exists to make, and it
# cannot be made without it.
proxy="$(printf '%s\n' "$all_svcs" | { grep -E -- '-proxy$' || true; })"
if [ -n "$proxy" ]; then
  net="$(docker service inspect "$proxy" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}}{{end}}' | sed -n 1p)"
  pw="$(docker exec "$first" sh -c 'cat /run/secrets/mariadb_galera_root_password')"
  # Query through the alias, which now belongs to the proxy. The client's error is kept:
  # a failure has to say whether it was refused, timed out or found no backend.
  via_proxy() {
    docker run --rm --network "$net" -e MYSQL_PWD="$pw" mariadb:12.3 \
      mariadb -h mariadb -uroot -N -B -e 'SELECT 1' 2>&1
  }
  # What the proxy saw: its tasks, and every line HAProxy logged that is not a client
  # connection — start-up alerts, each peer's resolved address, and every UP/DOWN with
  # its reason. A tail of connection lines says only <NOSRV>, and hid these once.
  proxy_seen() {
    docker service ps "$proxy" --no-trunc --format '    {{.Name}} {{.CurrentState}} {{.Error}}' | sed -n '1,6p'
    for c in $(docker ps -q -f "label=com.docker.swarm.service.name=$proxy"); do
      echo "    proxy container $c:"
      docker logs "$c" 2>&1 | { grep -vE '^[0-9.]+:[0-9]+ \[' || true; } | tail -n 40 | sed 's/^/      /'
    done
  }
  # HAProxy marks a backend up only after `rise 2` checks `inter 2s` apart, so a probe
  # right after convergence can find none up yet: one probe made this check flaky
  # (#229). Allow 30s, and on failure show what the client and the proxy saw.
  out=""
  for _ in $(seq 1 15); do
    out="$(via_proxy || true)"
    [ "$out" = "1" ] && break
    sleep 2
  done
  if [ "$out" != "1" ]; then
    echo "  $proxy: cannot reach the cluster through the client endpoint; the client said: $out"
    proxy_seen
    exit 1
  fi

  # Take a peer away and keep asking. The endpoint must keep answering.
  victim="$(printf '%s\n' $peers | sed -n 2p)"
  docker service scale "${victim}=0" >/dev/null 2>&1
  ok=0; fail=0; last_err=""
  for _ in $(seq 1 20); do
    out="$(via_proxy || true)"
    if [ "$out" = "1" ]; then ok=$((ok+1)); else fail=$((fail+1)); last_err="$out"; fi
    sleep 2
  done
  docker service scale "${victim}=1" >/dev/null 2>&1
  if [ "$fail" -gt 2 ]; then
    echo "  $proxy: $fail of $((ok+fail)) queries failed with $victim down — the endpoint did not route around it; the client last said: $last_err"
    proxy_seen
    exit 1
  fi
  echo "  ${release}: $want peers, all Synced, cross-peer write replicated, endpoint survived losing $victim ($ok/$((ok+fail)) queries OK)$metrics_ok"
  exit 0
fi

# With the default fixture (the pinned shape, on real volumes): the full stops a
# chart upgrade or an outage causes. Swarm publishes a peer in DNS only once it is
# healthy, so with every peer down none can find another. Two outcomes are owed:
#   * peers stopped one at a time: the last one out (safe_to_bootstrap: 1) forms the
#     cluster again by itself, and the others rejoin with every row, including the
#     ones written after they had left;
#   * peers stopped together (no peer holds the flag): the peers elect the one with
#     the newest data and form the cluster again by themselves, with every row, and no
#     peer ever starts mariadbd with nobody to reach. Peer 1 is behind the first time,
#     and its volume is empty the second, so neither the default winner nor an empty
#     peer can win by accident.
recovery_ok=""
if [ "$case" = default ]; then
  stop_peer() {
    docker service scale --detach "$1=0" >/dev/null
    for _ in $(seq 1 60); do
      [ -z "$(cid_of "$1")" ] && return 0
      sleep 2
    done
    echo "  $1: did not stop"; exit 1
  }
  start_all() { for svc in $peers; do docker service scale --detach "$svc=1" >/dev/null; done; }
  volumes="$(docker volume ls -q --filter "label=com.docker.stack.namespace=${release}" | sort)"
  [ "$(printf '%s\n' "$volumes" | wc -l | tr -d ' ')" = "$want" ] \
    || { echo "  expected $want data volumes for ${release}, found: $(echo $volumes)"; exit 1; }
  grastate() { docker run --rm -v "$1:/d:ro" busybox:1.37 grep -E '^(seqno|safe_to_bootstrap):' /d/grastate.dat | tr -s ' ' | tr '\n' ' '; }
  # Every container the peers' tasks have had, exited ones included: an election's
  # winner announces itself and then exits to bootstrap in a fresh one.
  containers() { for svc in $peers; do docker ps -aq --no-trunc -f "label=com.docker.swarm.service.name=$svc"; done | sort; }
  # The peers whose containers started since $1 (output of `containers`) won an
  # election with data: the winner's log names its seqno.
  winners_since() {
    local c
    for c in $(comm -13 <(echo "$1") <(containers)); do
      if docker logs "$c" 2>&1 | grep -E 'the peers elected this one at seqno [0-9]+ ' >/dev/null; then
        docker inspect --format '{{index .Config.Labels "com.docker.swarm.service.name"}}' "$c"
      fi
    done | sort -u
  }
  # Stops every peer together and clears the flag on every volume, which makes the
  # outcome deterministic: a simultaneous stop usually leaves no flag, not always.
  stop_together() {
    local svc v
    for svc in $peers; do docker service scale --detach "$svc=0" >/dev/null; done
    for svc in $peers; do stop_peer "$svc"; done
    for v in $volumes; do
      docker run --rm -v "$v:/d" busybox:1.37 sed -i 's/^safe_to_bootstrap: 1$/safe_to_bootstrap: 0/' /d/grastate.dat 2>/dev/null || true
    done
  }
  # The peer the election must pick, from each volume's recorded seqno by the same rule:
  # the highest wins, ties go to the lowest peer number. Volume number $1, if given, is
  # skipped as about to be emptied (an empty peer reports -2 and cannot win).
  expected_winner() {
    local skip="${1:-0}" i=0 best="" best_seq=-3 v sq
    for v in $volumes; do
      i=$((i + 1))
      [ "$i" = "$skip" ] && continue
      sq="$(docker run --rm -v "$v:/d:ro" busybox:1.37 sed -n 's/^seqno:[[:space:]]*//p' /d/grastate.dat)"
      if [ "$sq" -gt "$best_seq" ]; then best_seq="$sq"; best="$i"; fi
    done
    printf '%s\n' $peers | sed -n "${best}p"
  }
  # Waits for the cluster seen from $1 to have every member, then checks the rows
  # 1..$n, that the election's only winner was $2, and that no peer started with
  # nobody to reach. $3 is the output of `containers` taken before the stop.
  reformed() {
    local svc="$1" expect="$2" since="$3" what="$4" cid="" size="" got logs c won
    for _ in $(seq 1 90); do
      cid="$(cid_of "$svc")"
      size="$( [ -n "$cid" ] && status_of "$cid" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)"
      [ "$size" = "$want" ] && break
      sleep 5
    done
    if [ "$size" != "$want" ]; then
      echo "  $what: the peers did not elect one and form the cluster again (size '$size' from $svc)"
      for v in $volumes; do echo "    $v: $(grastate "$v")"; done
      exit 1
    fi
    got="$(q "$cid" "SET SESSION wsrep_sync_wait=1; SELECT COUNT(*) FROM e2e_galera.t WHERE id <= $n")"
    [ "$got" = "$n" ] || { echo "  $what: rows lost: $got of $n"; exit 1; }
    # Each container's own log: `docker service logs` returned nothing at all for
    # tasks that had not yet passed a healthcheck.
    logs="$(mktemp)"
    for c in $(comm -13 <(echo "$since") <(containers)); do docker logs "$c" >>"$logs" 2>&1 || true; done
    if grep -F 'No address to connect' "$logs" >/dev/null; then
      echo "  $what: a peer started mariadbd with no peer to reach:"
      grep -F -m 3 'No address to connect' "$logs" | sed 's/^/    /'
      exit 1
    fi
    rm -f "$logs"
    won="$(winners_since "$since" | tr '\n' ' ')"
    [ "$won" = "$expect " ] \
      || { echo "  $what: the election was won by '$won', expected $expect"; exit 1; }
  }

  # One at a time, writing on the last peer between stops.
  last="$(printf '%s\n' $peers | tail -1)"
  n=1
  for svc in $peers; do
    if [ "$svc" != "$last" ]; then
      stop_peer "$svc"
      n=$((n + 1))
      q "$(cid_of "$last")" "REPLACE INTO e2e_galera.t VALUES ($n, 'after-$n')" >/dev/null
    fi
  done
  stop_peer "$last"
  start_all
  size=""
  for _ in $(seq 1 90); do
    cid="$(cid_of "$(printf '%s\n' $peers | sed -n 1p)")"
    size="$( [ -n "$cid" ] && status_of "$cid" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)"
    [ "$size" = "$want" ] && break
    sleep 5
  done
  if [ "$size" != "$want" ]; then
    echo "  after a one-at-a-time stop the cluster did not form again (size '$size')"
    for v in $volumes; do echo "    $v: $(grastate "$v")"; done
    exit 1
  fi
  got="$(q "$cid" "SET SESSION wsrep_sync_wait=1; SELECT COUNT(*) FROM e2e_galera.t WHERE id <= $n")"
  [ "$got" = "$n" ] || { echo "  rows written after peers left were lost: $got of $n"; exit 1; }

  # Together, with peer 1 behind: it stops first and misses a write, then the others
  # stop at once. A peer that holds that write must win, normally peer 2 (it ties with
  # peer 3 and has the lower number), and the row peer 1 missed must survive.
  p1="$(printf '%s\n' $peers | sed -n 1p)"
  p2="$(printf '%s\n' $peers | sed -n 2p)"
  stop_peer "$p1"
  n=$((n + 1))
  q "$(cid_of "$p2")" "REPLACE INTO e2e_galera.t VALUES ($n, 'after-$n')" >/dev/null
  stop_together
  exp="$(expected_winner)"
  [ "$exp" != "$p1" ] || { echo "  peer 1 is not behind after missing a write; the case tests nothing"; exit 1; }
  before_containers="$(containers)"
  start_all
  reformed "$p1" "$exp" "$before_containers" "after peers stopped together with peer 1 behind"

  # Together again, with peer 1's volume empty, as when its node is rebuilt during an
  # outage. It must lose to the peers with data and re-sync from them, not seed an
  # empty cluster that they then copy.
  stop_together
  exp="$(expected_winner 1)"
  for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$p1"); do docker rm -f "$c" >/dev/null; done
  docker volume rm "$(printf '%s\n' $volumes | sed -n 1p)" >/dev/null
  before_containers="$(containers)"
  start_all
  reformed "$p1" "$exp" "$before_containers" "after a full stop with peer 1's volume empty"
  recovery_ok=", re-formed after a one-at-a-time stop, elected the furthest-ahead peer after a simultaneous one, and re-synced an emptied peer 1 instead of letting it seed"
fi

# With the lifecycle fixture (its own CI job): what a long-lived cluster goes
# through, each step asserting the cluster and its rows rather than convergence.
# Runs `swarmcli charts upgrade` itself, so it needs $SWARMCLI, as scripts/e2e-test.sh
# is given.
lifecycle_ok=""
if [ "$case" = lifecycle ]; then
  SWARMCLI="${SWARMCLI:-swarmcli}"
  chart="./$2"
  first_svc="$(printf '%s\n' $peers | sed -n 1p)"
  stop_peer() {
    docker service scale --detach "$1=0" >/dev/null
    for _ in $(seq 1 60); do
      [ -z "$(cid_of "$1")" ] && return 0
      sleep 2
    done
    echo "  $1: did not stop"; exit 1
  }
  start_all() { for svc in $peers; do docker service scale --detach "$svc=1" >/dev/null; done; }
  # Polls the given peer (default the first) until the cluster has every member and
  # that peer is Synced, so a query sent to it next is answered.
  wait_cluster() {
    local svc="${1:-$first_svc}" c size="" state=""
    for _ in $(seq 1 90); do
      c="$(cid_of "$svc")"
      size="$( [ -n "$c" ] && status_of "$c" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)"
      state="$( [ -n "$c" ] && status_of "$c" 'WSREP_LOCAL_STATE_COMMENT' 2>/dev/null || true)"
      [ "$size" = "$want" ] && [ "$state" = Synced ] && return 0
      sleep 5
    done
    echo "  $2: the cluster did not reach $want members (seen from $svc: '$size')"
    for v in $volumes; do echo "    $v: $(grastate "$v")"; done
    # What the peer was doing: its tasks, and the end of its newest container's log.
    docker service ps --no-trunc --format '    {{.Name}} {{.CurrentState}} {{.Error}}' "$svc" 2>&1 | sed -n 1,5p
    c="$(docker ps -aq -f "label=com.docker.swarm.service.name=$svc" | sed -n 1p)"
    [ -z "$c" ] || docker logs --tail 20 "$c" 2>&1 | sed 's/^/    /'
    exit 1
  }
  rows_ok() {  # rows_ok <svc> <ids...>
    local svc="$1" want_n got
    shift
    want_n=$#
    got="$(q "$(cid_of "$svc")" "SET SESSION wsrep_sync_wait=1; SELECT COUNT(*) FROM e2e_galera.t WHERE id IN ($(echo "$@" | tr ' ' ','))")"
    [ "$got" = "$want_n" ] || { echo "  $svc: $got of $want_n expected rows present ($*)"; exit 1; }
  }
  volumes="$(docker volume ls -q --filter "label=com.docker.stack.namespace=${release}" | sort)"
  grastate() { docker run --rm -v "$1:/d:ro" busybox:1.37 grep -E '^(seqno|safe_to_bootstrap):' /d/grastate.dat | tr -s ' ' | tr '\n' ' '; }
  upgrade() { "$SWARMCLI" charts upgrade "$release" "$chart" --reuse-values "$@" >/dev/null; }
  task_of() { docker service ps -q --filter desired-state=running "$1" | sed -n 1p; }
  containers() { for svc in $peers; do docker ps -aq --no-trunc -f "label=com.docker.swarm.service.name=$svc"; done | sort; }
  # Whether a peer with data won an election in a container started since $1, the
  # output of `containers` taken before the event.
  elected_since() {
    local c found=no
    for c in $(comm -13 <(echo "$1") <(containers)); do
      docker logs "$c" 2>&1 | grep -E 'the peers elected this one at seqno [0-9]+ ' >/dev/null && found=yes
    done
    [ "$found" = yes ]
  }

  # 1. One peer restarted into a running cluster rejoins it. Polled only once its new
  #    task runs: the old container keeps answering for a moment while it stops.
  second="$(printf '%s\n' $peers | sed -n 2p)"
  old_task="$(task_of "$second")"
  docker service update --detach --force "$second" >/dev/null
  for _ in $(seq 1 60); do
    t="$(task_of "$second")"
    [ -n "$t" ] && [ "$t" != "$old_task" ] && break
    sleep 2
  done
  wait_cluster "$second" "after restarting $second"

  # 2. Peer 1 rebuilt from an empty volume while the others run re-syncs from them; it
  #    must not seed a rival cluster beside the survivors (README, How bootstrapping decides).
  q "$(cid_of "$second")" "REPLACE INTO e2e_galera.t VALUES (20, 'before-rebuild')" >/dev/null
  stop_peer "$first_svc"
  for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$first_svc"); do docker rm -f "$c" >/dev/null; done
  docker volume rm "$(printf '%s\n' $volumes | sed -n 1p)" >/dev/null
  docker service scale --detach "$first_svc=1" >/dev/null
  wait_cluster "$second" "after rebuilding $first_svc from an empty volume"
  wait_cluster "$first_svc" "after rebuilding $first_svc from an empty volume"
  rows_ok "$first_svc" 1 20
  # The fixture's extraConfig: every peer runs with its buffer pool, peer 1 included after
  # that state transfer under it, and the file holds the value as written, `$` and all.
  for svc in $peers; do
    c="$(cid_of "$svc")"
    bp="$(q "$c" 'SELECT @@innodb_buffer_pool_size')"
    [ "$bp" = 268435456 ] || { echo "  $svc: innodb_buffer_pool_size is $bp, expected 268435456 (256M) from extraConfig"; exit 1; }
    docker exec "$c" grep -Fqx '# escaping check: a literal $ survives compose' /etc/mysql/conf.d/extra-config.cnf \
      || { echo "  $svc: /etc/mysql/conf.d/extra-config.cnf does not hold extraConfig as written"; exit 1; }
  done

  # 3. An upgrade that changes every peer, which is what a re-tagged image does. The
  #    peers carry com.swarmcli.rollout=sequential, so swarmcli replaces them one at a
  #    time: the upgrade returns only once every peer runs a new task, each started a
  #    monitor window after the one before, and some peer answers at every sample, in
  #    a cluster of at least want-1.
  q "$(cid_of "$second")" "REPLACE INTO e2e_galera.t VALUES (30, 'before-upgrade')" >/dev/null
  extra="$(mktemp)"
  printf 'extraArgs:\n  - "--max-connections=201"\n' >"$extra"
  before_tasks="$(for svc in $peers; do task_of "$svc"; done)"
  sizes="$(mktemp)"
  (
    while :; do  # the cluster size seen by the first peer that answers, or "-"
      size="-"
      for svc in $peers; do
        c="$(cid_of "$svc")"
        v="$( [ -n "$c" ] && status_of "$c" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)"
        [ -n "$v" ] && { size="$v"; break; }
      done
      echo "$size" >>"$sizes"
      sleep 2
    done
  ) &
  sampler=$!
  upgrade -f "$extra" --timeout 10m || { kill "$sampler"; echo "  the all-peer upgrade did not roll out"; exit 1; }
  # One at a time, the upgrade has already waited for every peer. All at once, it
  # returns before swarm has even created their new tasks (stop-first), so wait for
  # them and for the cluster, sampling all the while, before judging either.
  now_tasks=""
  for _ in $(seq 1 120); do
    now_tasks="$(for svc in $peers; do task_of "$svc"; done)"
    [ "$(printf '%s\n' $now_tasks | wc -l | tr -d ' ')" = "$want" ] \
      && [ -z "$(comm -12 <(echo "$before_tasks" | sort) <(echo "$now_tasks" | sort))" ] && break
    sleep 5
  done
  [ "$(printf '%s\n' $now_tasks | wc -l | tr -d ' ')" = "$want" ] \
    && [ -z "$(comm -12 <(echo "$before_tasks" | sort) <(echo "$now_tasks" | sort))" ] \
    || { kill "$sampler"; echo "  the upgrade did not give every peer a new task"; exit 1; }
  wait_cluster "$first_svc" "after the all-peer upgrade"
  kill "$sampler"; wait "$sampler" 2>/dev/null || true
  if grep -x -- - "$sizes" >/dev/null; then
    echo "  no peer answered at $(grep -cx -- - "$sizes") of $(wc -l <"$sizes" | tr -d ' ') samples; the peers did not roll one at a time"
    exit 1
  fi
  min="$(sort -n "$sizes" | sed -n 1p)"
  [ "$min" -ge $((want - 1)) ] \
    || { echo "  the cluster shrank to $min of $want during the upgrade; the peers did not roll one at a time"; exit 1; }
  # Quorum alone does not tell one at a time from all at once: peers updated together
  # kept it here too, by the luck of staggered shutdowns. The order does. One at a time,
  # each new task starts only after the one before has outlived its 150s monitor
  # window; all at once, they start within seconds of each other.
  starts=""
  for t in $now_tasks; do
    c="$(docker inspect --format '{{.CreatedAt.Unix}}' "$t")"
    starts="$starts $c"
  done
  [ "$(printf '%s\n' $starts | wc -l | tr -d ' ')" = "$want" ] \
    || { echo "  read $(echo $starts) as the peers' start times, expected $want"; exit 1; }
  prev=""
  for t in $(printf '%s\n' $starts | sort -n); do
    if [ -n "$prev" ] && [ $((t - prev)) -lt 120 ]; then
      echo "  two peers' new tasks started $((t - prev))s apart; the upgrade did not wait out a monitor window between them"
      exit 1
    fi
    prev="$t"
  done
  rows_ok "$first_svc" 1 20 30

  # Then every peer stopped together, with no peer holding the flag: the peers must
  # elect the one with the newest data and form the cluster again by themselves.
  for svc in $peers; do docker service scale --detach "$svc=0" >/dev/null; done
  for svc in $peers; do stop_peer "$svc"; done
  for v in $volumes; do
    docker run --rm -v "$v:/d" busybox:1.37 sed -i 's/^safe_to_bootstrap: 1$/safe_to_bootstrap: 0/' /d/grastate.dat
  done
  before_containers="$(containers)"
  start_all
  wait_cluster "$first_svc" "after every peer stopped together"
  elected_since "$before_containers" \
    || { echo "  the cluster re-formed after every peer stopped together, but not through an election"; exit 1; }
  rows_ok "$first_svc" 1 20 30

  # 4. A peer lost for good, its node gone: the others must not elect without it, since
  #    it may hold the newest data, and forcing the furthest-ahead of those left, as the
  #    README runbook says, must form the cluster with every row. Removing its placement
  #    label stands in for the lost node.
  node="$(docker node ls --format '{{.ID}} {{.Self}}' | awk '$2=="true"{print $1; exit}')"
  lost_svc="$(printf '%s\n' $peers | tail -1)"
  lost="${lost_svc##*-}"
  for svc in $peers; do docker service scale --detach "$svc=0" >/dev/null; done
  for svc in $peers; do stop_peer "$svc"; done
  for v in $volumes; do
    docker run --rm -v "$v:/d" busybox:1.37 sed -i 's/^safe_to_bootstrap: 1$/safe_to_bootstrap: 0/' /d/grastate.dat
  done
  # Each position read with the runbook's own command, every peer stopped.
  image="$(docker service inspect "$first_svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
  best=""; best_seq=-2; i=0
  for v in $volumes; do
    i=$((i + 1))
    [ "$i" = "$lost" ] && continue
    if ! out="$(docker run --rm --network none -v "$v:/var/lib/mysql" "$image" \
      mariadbd --user=mysql --wsrep-on=ON --wsrep-provider=/usr/lib/galera/libgalera_smm.so \
      --wsrep-cluster-address=gcomm:// --wsrep-recover 2>&1)"; then
      echo "  $v: --wsrep-recover failed:"; tail -15 <<<"$out" | sed 's/^/    /'; exit 1
    fi
    pos="$(sed -n 's/.*WSREP: Recovered position: [^:]*:\([-0-9]*\).*/\1/p' <<<"$out" | tail -1)"
    case "$pos" in
      ''|-1) echo "  $v: --wsrep-recover gave no position ('$pos'):"; tail -15 <<<"$out" | sed 's/^/    /'; exit 1 ;;
    esac
    if [ "$pos" -gt "$best_seq" ]; then best_seq="$pos"; best="$i"; fi
  done
  docker node update --label-rm "mariadb-galera-$lost" "$node" >/dev/null
  start_all
  sleep 90
  for svc in $peers; do
    [ "$svc" = "$lost_svc" ] && continue
    c="$(cid_of "$svc")"
    [ -n "$c" ] || { echo "  $svc: no running container while peer $lost is lost"; exit 1; }
    [ -z "$(status_of "$c" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)" ] \
      || { echo "  $svc: the peers formed a cluster without peer $lost, which may hold the newest data"; exit 1; }
  done
  # No --wait: the lost peer can never converge. The rollout still waits for the
  # forced peer, the one service this changes.
  upgrade -f "$extra" --set "cluster.forceBootstrap=$best" --timeout 15m \
    || { echo "  forceBootstrap=$best did not roll out"; for v in $volumes; do echo "    $v: $(grastate "$v")"; done; exit 1; }
  best_svc="$(printf '%s\n' $peers | sed -n "${best}p")"
  size=""
  for _ in $(seq 1 90); do
    c="$(cid_of "$best_svc")"
    size="$( [ -n "$c" ] && status_of "$c" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)"
    [ "$size" = "$((want - 1))" ] && break
    sleep 5
  done
  [ "$size" = "$((want - 1))" ] \
    || { echo "  after forceBootstrap=$best the peers left did not form a cluster of $((want - 1)) (size '$size')"; exit 1; }
  rows_ok "$best_svc" 1 20 30
  docker node update --label-add "mariadb-galera-$lost=true" "$node" >/dev/null
  # Restoring the label did not get the task Swarm had left Pending placed: it stayed
  # "no suitable node" for minutes on Docker 29.2, though the constraint held. A task
  # of a fresh service is placed within seconds, so this is the label stand-in, not
  # how a returning node behaves. A forced update has Swarm place a new task.
  docker service update --detach --force "$lost_svc" >/dev/null
  wait_cluster "$lost_svc" "after peer $lost came back"
  rows_ok "$lost_svc" 1 20 30

  # 5. Clearing it restarts only the forced peer; the rest keep their tasks, so the
  #    cluster stays up through the second upgrade.
  kept=""
  n=0
  for svc in $peers; do
    n=$((n + 1)); [ "$n" = "$best" ] || kept="$kept $svc=$(task_of "$svc")"
  done
  upgrade -f "$extra" --set "cluster.forceBootstrap=" --wait --timeout 15m \
    || { echo "  clearing forceBootstrap did not converge"; exit 1; }
  for kv in $kept; do
    [ "$(task_of "${kv%%=*}")" = "${kv#*=}" ] || { echo "  ${kv%%=*} restarted when forceBootstrap was cleared"; exit 1; }
  done
  wait_cluster "$first_svc" "after clearing forceBootstrap"

  # 6. Every peer killed at once (a power loss): grastate says seqno -1 everywhere, so
  #    each peer must recover its position with --wsrep-recover, and the peers must
  #    elect the furthest-ahead one and form the cluster with every committed row,
  #    with no one stepping in.
  q "$(cid_of "$second")" "REPLACE INTO e2e_galera.t VALUES (40, 'before-crash')" >/dev/null
  before_containers="$(containers)"
  docker kill $(for svc in $peers; do cid_of "$svc"; done) >/dev/null
  sleep 10
  wait_cluster "$first_svc" "after every peer was killed"
  elected_since "$before_containers" \
    || { echo "  the cluster re-formed after a crash, but not through an election"; exit 1; }
  rows_ok "$first_svc" 1 20 30 40

  # 7. A replacement that starts while the old container still runs. A stop-first update
  #    starts the new task after waiting at most a minute for the old one, and a frozen
  #    old container lives until the fixture's stopGracePeriod (90s) runs out. It is
  #    frozen the way a slow clean shutdown leaves it: Galera has recorded its position
  #    in grastate.dat, so a replacement rejoins by IST on the same files, while InnoDB
  #    still holds them. (At seqno -1 the replacement would take a full state transfer
  #    instead, which replaces the files rather than opening them.) The new container
  #    must wait for the old one's lock on the data dir rather than start a second
  #    mariadbd on those files (`Unable to lock ./ibdata1`), so the update completes with no
  #    failed task, and the row written just before the freeze survives.
  # Step 6 waited on the first peer's view; this one may still be catching up.
  wait_cluster "$second" "before replacing $second beside its old container"
  q "$(cid_of "$second")" "REPLACE INTO e2e_galera.t VALUES (50, 'before-overlap')" >/dev/null
  old_c="$(cid_of "$second")"
  seqno="$(status_of "$old_c" 'WSREP_LAST_COMMITTED')"
  before_tasks="$(docker service ps -q "$second" | sort)"
  upd() { docker service inspect --format '{{if .UpdateStatus}}{{.UpdateStatus.StartedAt}} {{.UpdateStatus.State}}{{end}}' "$second"; }
  before_upd="$(upd)"
  docker kill --signal STOP "$old_c" >/dev/null
  docker exec "$old_c" sed -i "s/^seqno:.*/seqno:   $seqno/" /var/lib/mysql/grastate.dat
  docker service update --detach --force "$second" >/dev/null
  st=""
  for _ in $(seq 1 90); do
    now_upd="$(upd)"
    if [ "$now_upd" != "$before_upd" ]; then
      st="${now_upd##* }"
      [ "$st" = updating ] || break
    fi
    sleep 5
  done
  new_tasks="$(comm -13 <(echo "$before_tasks") <(docker service ps -q "$second" | sort))"
  if [ "$st" != completed ] || [ "$(echo $new_tasks | wc -w | tr -d ' ')" != 1 ]; then
    echo "  replacing $second while its old container still ran: update '$st', new task(s): $(echo $new_tasks)"
    docker service ps --no-trunc --format '    {{.Name}} {{.CurrentState}} {{.Error}}' "$second" | sed -n 1,5p
    for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$second" | sed -n 1,2p); do
      docker logs "$c" 2>&1 | { grep -E 'Unable to lock|exclusive lock|\[ERROR\]' || true; } | tail -n 6 | sed 's/^/    /'
    done
    exit 1
  fi
  docker logs "$(cid_of "$second")" 2>&1 | grep -F 'waiting for the previous container of this peer to release its data dir' >/dev/null \
    || { echo "  the new $second container never waited for the old one, so this step tests nothing"; exit 1; }
  wait_cluster "$second" "after replacing $second beside its old container"
  rows_ok "$second" 1 20 30 40 50
  rm -f "$extra" "$sizes"
  lifecycle_ok=", rejoined, re-synced a rebuilt peer 1 with extraConfig's buffer pool, rolled an all-peer upgrade with quorum kept, elected a peer after a full stop and after a crash, forced one with a peer lost, and replaced one beside its old container, which it waited out"
fi

# With the events fixture: a scheduled event keeps running on the one peer that owns
# it, through restarts and through a full state transfer FROM that peer. Every peer
# runs the scheduler, and peer 1 is every joiner's preferred donor, so a peer rebuilt
# from an empty volume copies peer 1's ENABLED event. Only its own server_id keeps it
# from running the event as well (README, Scheduled events).
events_ok=""
if [ "$case" = events ]; then
  p1="$(printf '%s\n' $peers | sed -n 1p)"
  p2="$(printf '%s\n' $peers | sed -n 2p)"
  p3="$(printf '%s\n' $peers | tail -1)"
  owner="${p1##*_}"
  stop_peer() {
    docker service scale --detach "$1=0" >/dev/null
    for _ in $(seq 1 60); do
      [ -z "$(cid_of "$1")" ] && return 0
      sleep 2
    done
    echo "  $1: did not stop"; exit 1
  }
  wait_cluster() {  # wait_cluster <svc> <what>: every member present, <svc> Synced
    local c size="" state=""
    for _ in $(seq 1 90); do
      c="$(cid_of "$1")"
      size="$( [ -n "$c" ] && status_of "$c" 'WSREP_CLUSTER_SIZE' 2>/dev/null || true)"
      state="$( [ -n "$c" ] && status_of "$c" 'WSREP_LOCAL_STATE_COMMENT' 2>/dev/null || true)"
      [ "$size" = "$want" ] && [ "$state" = Synced ] && return 0
      sleep 5
    done
    echo "  $2: $1 is '$state' in a cluster of '$size', expected Synced in $want"
    docker service ps --no-trunc --format '    {{.Name}} {{.CurrentState}} {{.Error}}' "$1" 2>&1 | sed -n 1,5p
    exit 1
  }
  restart() {  # restart <svc>: a new task, Synced in the whole cluster
    local old t
    old="$(docker service ps -q --filter desired-state=running "$1" | sed -n 1p)"
    docker service update --detach --force "$1" >/dev/null
    for _ in $(seq 1 60); do
      t="$(docker service ps -q --filter desired-state=running "$1" | sed -n 1p)"
      [ -n "$t" ] && [ "$t" != "$old" ] && break
      sleep 2
    done
    wait_cluster "$1" "after restarting $1"
  }
  now() { q "$(cid_of "$p1")" 'SELECT NOW(6)'; }
  # Which peers ran the event since $1: it must be the owner alone, and it must have run.
  ran_since() {
    local got
    sleep 6
    got="$(q "$(cid_of "$p1")" "SET SESSION wsrep_sync_wait=1; SELECT GROUP_CONCAT(DISTINCT peer ORDER BY peer) FROM e2e_galera.ticks WHERE at > '$1'")"
    [ "$got" = "$owner" ] || { echo "  $2: the event ran on '$got', expected $owner alone"; exit 1; }
  }

  q "$(cid_of "$p1")" "CREATE TABLE e2e_galera.ticks (id INT AUTO_INCREMENT PRIMARY KEY, peer VARCHAR(64) NOT NULL, at DATETIME(6) NOT NULL DEFAULT NOW(6));
    CREATE EVENT e2e_galera.tick ON SCHEDULE EVERY 1 SECOND DO INSERT INTO e2e_galera.ticks (peer) VALUES (@@hostname)" >/dev/null
  ran_since "$(now)" "after creating the event on $owner"

  # A restarted peer that does not own the event leaves it alone, and the owner, once
  # restarted, runs it again.
  restart "$p2"
  ran_since "$(now)" "after restarting $p2"
  restart "$p1"
  ran_since "$(now)" "after restarting $p1"

  # A full state transfer from the owner. The joiner's copy of the event arrives
  # ENABLED, exactly as the owner holds it; at start-up the joiner must disable it.
  stop_peer "$p3"
  for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$p3"); do docker rm -f "$c" >/dev/null; done
  docker volume rm "$(docker volume ls -q --filter "label=com.docker.stack.namespace=${release}" | sort | tail -1)" >/dev/null
  docker service scale --detach "$p3=1" >/dev/null
  wait_cluster "$p3" "after rebuilding $p3 from an empty volume"
  docker logs "$(cid_of "$p3")" 2>&1 | grep -E "Selected [0-9]+\.[0-9]+ \($owner\)" >/dev/null \
    || { echo "  $p3 did not take its state from $owner, so this case tests nothing"; exit 1; }
  st="$(q "$(cid_of "$p3")" "SELECT STATUS FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'e2e_galera' AND EVENT_NAME = 'tick'")"
  [ "$st" = SLAVESIDE_DISABLED ] \
    || { echo "  $p3 holds the event as '$st' after a state transfer from $owner, expected SLAVESIDE_DISABLED"; exit 1; }
  ran_since "$(now)" "after rebuilding $p3 by a state transfer from $owner"
  events_ok=", the event ran on $owner alone through restarts and a full state transfer from it"
fi

echo "  ${release}: $want peers, all Synced, cross-peer write replicated$metrics_ok$recovery_ok$lifecycle_ok$events_ok OK"
