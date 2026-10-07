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
set -euo pipefail

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
  promtool_image="${GALERA_E2E_PROMTOOL_IMAGE:-prom/prometheus:v3.15.0}"
  if ! out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "$promtool_image" \
      test rules /chart/ci/galera-rules-test.yml 2>&1)"; then
    echo "  promtool test rules fails on monitoring/galera-rules.yml:"
    echo "$out" | sed 's/^/    /'
    exit 1
  fi
  metrics_ok=", $n_exp exporters scraped on monitoring, alert rules pass promtool"
fi

# With the proxy fixture, the thing worth proving is not that the cluster formed —
# the assertions above already did that — but that the CLIENT ENDPOINT keeps
# working while a peer is gone. That is the claim the proxy exists to make, and it
# cannot be made without it.
proxy="$(printf '%s\n' "$all_svcs" | { grep -E -- '-proxy$' || true; })"
if [ -n "$proxy" ]; then
  net="$(docker service inspect "$proxy" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}}{{end}}' | sed -n 1p)"
  pw="$(docker exec "$first" sh -c 'cat /run/secrets/mariadb_galera_root_password')"
  # Query through the alias, which now belongs to the proxy.
  via_proxy() {
    docker run --rm --network "$net" -e MYSQL_PWD="$pw" mariadb:12.3 \
      mariadb -h mariadb -uroot -N -B -e 'SELECT 1' 2>/dev/null
  }
  [ "$(via_proxy)" = "1" ] || { echo "  $proxy: cannot reach the cluster through the client endpoint"; exit 1; }

  # Take a peer away and keep asking. The endpoint must keep answering.
  victim="$(printf '%s\n' $peers | sed -n 2p)"
  docker service scale "${victim}=0" >/dev/null 2>&1
  ok=0; fail=0
  for _ in $(seq 1 20); do
    if [ "$(via_proxy)" = "1" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
    sleep 2
  done
  docker service scale "${victim}=1" >/dev/null 2>&1
  if [ "$fail" -gt 2 ]; then
    echo "  $proxy: $fail of $((ok+fail)) queries failed with $victim down — the endpoint did not route around it"
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
#   * peers stopped together (no peer holds the flag): every peer waits instead of
#     crash-looping, and no grastate.dat is rewritten to seqno -1, since that seqno
#     is what the operator compares to pick the peer to force.
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

  # Together, then nobody holds the flag. Clearing it on every volume makes the
  # outcome deterministic: a simultaneous stop usually leaves no flag, not always.
  for svc in $peers; do docker service scale --detach "$svc=0" >/dev/null; done
  for svc in $peers; do stop_peer "$svc"; done
  for v in $volumes; do
    docker run --rm -v "$v:/d" busybox:1.37 sed -i 's/^safe_to_bootstrap: 1$/safe_to_bootstrap: 0/' /d/grastate.dat
  done
  before="$(for v in $volumes; do grastate "$v"; echo; done)"
  start_all
  sleep 75
  # Each peer's own container log: `docker service logs` returned nothing at all for
  # these tasks while they waited, which would fail this check for no reason.
  logs="$(mktemp)"
  for svc in $peers; do
    c="$(cid_of "$svc")"
    [ -n "$c" ] || { echo "  $svc: no running container 75s after a simultaneous stop"; exit 1; }
    docker logs "$c" >>"$logs" 2>&1 || true
  done
  if grep -F 'No address to connect' "$logs" >/dev/null; then
    echo "  after a simultaneous stop a peer started mariadbd with no peer to reach:"
    grep -F -m 3 'No address to connect' "$logs" | sed 's/^/    /'
    exit 1
  fi
  grep -F 'waiting for a peer to come up' "$logs" >/dev/null \
    || { echo "  after a simultaneous stop no peer reports waiting:"; tail -5 "$logs" | sed 's/^/    /'; exit 1; }
  after="$(for v in $volumes; do grastate "$v"; echo; done)"
  [ "$after" = "$before" ] \
    || { echo "  waiting rewrote grastate.dat; before: $(echo $before) after: $(echo $after)"; exit 1; }
  rm -f "$logs"
  recovery_ok=", re-formed after a one-at-a-time stop and waited intact after a simultaneous one"
fi

echo "  ${release}: $want peers, all Synced, cross-peer write replicated$metrics_ok$recovery_ok OK"
