#!/usr/bin/env bash
#
# e2e smoke check for the postgres-patroni chart. scripts/e2e-test.sh runs this after
# the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence alone is a WEAK signal for a cluster: three peers that each initialised a
# database of their own would all report healthy, and so would an etcd whose members
# formed three clusters of one. So every fixture asserts what can only be true of a real
# cluster, then exercises the failover the chart exists for:
#
#   1. Patroni reports exactly one leader and every other peer streaming from it, all on
#      one timeline, and etcd reports every member in one cluster with one leader. The
#      replicas start empty and can only stream after copying the primary, so this also
#      proves the replication role and its password work.
#   2. A row written through the proxy's primary port lands on the leader, and the
#      replica port serves it from every replica in turn, read-only.
#   3. Nothing on the client overlay can reach a peer, the Patroni REST API or etcd, and
#      the REST API refuses a write without its password.
#   4. Stopping the leader moves the primary to another peer, writes through the same
#      proxy endpoint resume, and the old leader rejoins as a replica with every row.
#
# The lifecycle fixture (its own CI job) adds what a long-lived cluster goes through;
# see the end of this file.
#
# PREREQUISITES (ci/e2e-setup.sh provisions these):
#   printf test | docker secret create postgres_patroni_{superuser,replication,restapi}_password -
#   docker node update --label-add postgres-patroni-<N>=true <node>   (N = 1..5)
set -Eeuo pipefail
# A command that fails without printing anything would otherwise end the check with no
# clue where; -E carries this into functions and command substitutions.
trap 'echo "  e2e-check.sh:$LINENO: exit $? from: $BASH_COMMAND" >&2' ERR

release="$1"
case="${3:-}"

svcs="$(docker service ls --filter "label=com.docker.stack.namespace=${release}" --format '{{.Name}}')"
peers="$(printf '%s\n' "$svcs" | { grep -E -- "^${release}_postgres-patroni-[0-9]+$" || true; } | sort -t- -k3,3n)"
members="$(printf '%s\n' "$svcs" | { grep -E -- "^${release}_postgres-patroni-etcd-[0-9]+$" || true; } | sort -t- -k4,4n)"
want="$(printf '%s\n' $peers | grep -c . || true)"
want_members="$(printf '%s\n' $members | grep -c . || true)"
# Derived from the stack, so sanity-checked against what a cluster can be: a stack that
# came up with one peer would otherwise set want=1, and "one leader, no replicas" would
# pass on exactly the failure this check exists to catch.
[ "$want" -ge 2 ] || { echo "  only $want peer service(s) in stack ${release}; a cluster is at least 2"; exit 1; }
[ "$want_members" -ge 3 ] || { echo "  only $want_members etcd service(s) in stack ${release}"; exit 1; }

cid_of() { docker ps -q -f "label=com.docker.swarm.service.name=$1" | sed -n 1p; }
image="$(docker service inspect "$(printf '%s\n' $peers | sed -n 1p)" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
# The client overlay is the proxy's network that is not the stack-internal one.
net=""
for id in $(docker service inspect "${release}_postgres-patroni-proxy" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}'); do
  n="$(docker network inspect "$id" --format '{{.Name}}')"
  [ "$n" = "${release}_cluster" ] || net="$n"
done
[ -n "$net" ] || { echo "  could not find the proxy's client overlay"; exit 1; }

# The cluster as Patroni sees it, from the first peer that answers.
cluster() {
  local p c out
  for p in $peers; do
    c="$(cid_of "$p")"
    [ -n "$c" ] || continue
    if out="$(docker exec "$c" patronictl list -f json 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}
leader() { cluster | jq -r '.[] | select(.Role == "Leader") | .Member'; }
# Waits until there is one leader and every other peer streams from it on its timeline,
# and then until the proxy routes to it: Patroni can settle a few seconds before the
# proxy's checks (rise 2, 3s apart) mark the new primary up, or before a rescheduled
# peer is in DNS at all.
wait_cluster() {
  local out="" i
  for i in $(seq 1 90); do
    out="$(cluster 2>/dev/null || true)"
    if [ -n "$out" ] && jq -e --argjson n "$want" '
        length == $n
        and ([.[] | select(.Role == "Leader" and .State == "running")] | length) == 1
        and ([.[] | select(.Role == "Replica" and .State == "streaming")] | length) == $n - 1
        and ([.[] | .TL] | unique | length) == 1' <<<"$out" >/dev/null; then
      for _ in $(seq 1 30); do
        [ "$(trap - ERR; sql 5432 'SELECT pg_is_in_recovery()' 2>/dev/null)" = f ] && break
        sleep 2
      done
      [ "$(trap - ERR; sql 5432 'SELECT pg_is_in_recovery()' 2>/dev/null)" = f ] \
        || { echo "  $1: the cluster settled, but the proxy's primary port did not reach it within 60s"; exit 1; }
      # And until Swarm counts every task as running. A task with a healthcheck stays
      # `starting` until its first healthy check, which can come after Patroni already
      # streams, and swarmcli rolls a service that is not running in the first batch,
      # beside the one it rolls first: the next upgrade would restart two peers at once.
      local states=""
      for _ in $(seq 1 60); do
        states="$(for s in $peers $members; do docker service ps --filter desired-state=running --format '{{.CurrentState}}' "$s" | sed -n 1p; done)"
        grep -v '^Running' <<<"$states" >/dev/null || return 0
        sleep 2
      done
      echo "  $1: the cluster settled, but Swarm does not count every task as running: $(echo $states)"
      exit 1
    fi
    sleep 4
  done
  echo "  $1: the cluster did not settle to 1 leader and $((want - 1)) streaming replicas:"
  printf '%s\n' "$out" | jq -c '.[] | {Member, Role, State, TL}' 2>/dev/null | sed 's/^/    /' || true
  for p in $peers; do
    docker service ps --no-trunc --format "    {{.Name}} {{.CurrentState}} {{.Error}}" "$p" 2>&1 | sed -n 1,3p
  done
  exit 1
}
# psql through the proxy, from a throwaway client on the client overlay, as an app would.
sql() {  # sql <port> <statement>
  docker run --rm --network "$net" -e PGPASSWORD=test -e PGCONNECT_TIMEOUT=5 --entrypoint psql "$image" \
    -h postgres -p "$1" -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "$2"
}
# psql inside a peer, over its socket, which bypasses the proxy.
local_sql() { docker exec "$(cid_of "$1")" psql -U postgres -d postgres -qAt -c "$2"; }
# Retries a write through the primary port until it succeeds; prints the server's address.
write_until() {  # write_until <id> <label>
  local i out=""
  for i in $(seq 1 45); do
    # trap - ERR: a command substitution does not inherit the `if`, so the trap would
    # report every write that fails while the primary moves, which is the expected case.
    if out="$(trap - ERR; sql 5432 "INSERT INTO e2e_patroni.t VALUES ($1, '$2') RETURNING inet_server_addr()" 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 2
  done
  echo "  $2: no write through the proxy succeeded within 90s; last: $out" >&2
  exit 1
}
host_of() { cluster | jq -r --arg m "${1#"${release}_"}" '.[] | select(.Member == $m) | .Host'; }
stop_svc() {
  docker service scale --detach "$1=0" >/dev/null
  local i
  for i in $(seq 1 60); do
    [ -z "$(cid_of "$1")" ] && return 0
    sleep 2
  done
  echo "  $1: did not stop"
  exit 1
}

# 1. One leader, the rest streaming; one etcd cluster with one leader.
wait_cluster "after install"
e1="$(cid_of "$(printf '%s\n' $members | sed -n 1p)")"
estatus="$(docker exec "$e1" etcdctl endpoint status --cluster -w json)"
jq -e --argjson n "$want_members" 'length == $n and ([.[] | select(.Status.leader == .Status.header.member_id)] | length) == 1
  and ([.[] | .Status.header.cluster_id] | unique | length) == 1' <<<"$estatus" >/dev/null \
  || { echo "  etcd is not one cluster of $want_members members with one leader:"; jq -c '.[] | {Endpoint, leader: .Status.leader, id: .Status.header.member_id}' <<<"$estatus"; exit 1; }
lead="$(leader)"

# 2. A write through 5432 lands on the leader; 5433 serves it from every replica, read-only.
sql 5432 "CREATE SCHEMA IF NOT EXISTS e2e_patroni; CREATE TABLE IF NOT EXISTS e2e_patroni.t (id int PRIMARY KEY, note text)" >/dev/null
got="$(write_until 1 install)"
[ "$got" = "$(host_of "$lead")" ] || { echo "  the primary port reached $got, not the leader $lead at $(host_of "$lead")"; exit 1; }
seen=""
for i in $(seq 1 30); do
  r="$(sql 5433 "SELECT inet_server_addr(), pg_is_in_recovery(), count(*) FROM e2e_patroni.t WHERE id = 1" 2>/dev/null || true)"
  case "$r" in
    *"|t|1") seen="$seen${r%%|*}
" ;;
    *"|f|"*) echo "  the replica port reached a primary: $r"; exit 1 ;;
  esac
  [ "$(printf '%s' "$seen" | sort -u | grep -c . || true)" -ge "$((want - 1))" ] && break
  sleep 1
done
n_seen="$(printf '%s' "$seen" | sort -u | grep -c . || true)"
[ "$n_seen" = "$((want - 1))" ] || { echo "  the replica port served the row from $n_seen of $((want - 1)) replicas: $(echo $seen)"; exit 1; }

# 3. The client overlay reaches the proxy and nothing behind it; the REST API wants its
#    password for anything but a read.
first_peer="$(printf '%s\n' $peers | sed -n 1p)"
first_member="$(printf '%s\n' $members | sed -n 1p)"
etcd_alias="$(echo "${release}" | tr '_.' '--')-etcd-1"
# One container, so a probe that cannot resolve anything does not read as isolation: the
# proxy's alias must resolve, and then nothing behind it may.
probe="$(docker run --rm --network "$net" --entrypoint bash "$image" -c \
  "getent hosts postgres >/dev/null || { echo no-proxy; exit 0; }
   for h in tasks.$first_peer $etcd_alias tasks.$first_member; do getent hosts \$h >/dev/null && echo \$h; done; true")"
case "$probe" in
  no-proxy) echo "  the probe could not resolve the proxy's alias on $net, so it proves nothing"; exit 1 ;;
  ?*) echo "  resolves on the client overlay $net: $(echo $probe)"; exit 1 ;;
esac
code="$(docker exec "$(cid_of "$first_peer")" curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8008/restart)"
[ "$code" = 401 ] || { echo "  the REST API answered an unauthenticated POST /restart with $code, not 401"; exit 1; }

# The published fixture: the same two endpoints on the host ports, through ingress.
if [ "$case" = published ]; then
  hostsql() { docker run --rm --network host -e PGPASSWORD=test -e PGCONNECT_TIMEOUT=5 --entrypoint psql "$image" \
    -h 127.0.0.1 -p "$1" -U postgres -d postgres -qAt -c 'SELECT pg_is_in_recovery()'; }
  [ "$(hostsql 15432)" = f ] || { echo "  host port 15432 does not reach the primary"; exit 1; }
  [ "$(hostsql 15433)" = t ] || { echo "  host port 15433 does not reach a replica"; exit 1; }
fi

# 4. Failover: stop the leader. Another peer takes over, writes through the same endpoint
#    resume, and the old leader comes back as a replica holding every row.
lead_svc="${release}_${lead}"
stop_svc "$lead_svc"
got="$(write_until 2 failover)"
new="$(leader)"
[ -n "$new" ] && [ "$new" != "$lead" ] || { echo "  no new leader after stopping $lead (leader: '$new')"; exit 1; }
[ "$got" = "$(host_of "$new")" ] || { echo "  after the failover the primary port reached $got, not the new leader $new"; exit 1; }
docker service scale --detach "$lead_svc=1" >/dev/null
wait_cluster "after $lead rejoined"
[ "$(leader)" = "$new" ] || { echo "  $lead took the leader back when it rejoined"; exit 1; }
# Kept apart from $lead and $new, which the lifecycle steps below reuse.
failed_over="from $lead to $new"
for i in $(seq 1 30); do
  [ "$(local_sql "$lead_svc" 'SELECT count(*) FROM e2e_patroni.t' 2>/dev/null || true)" = 2 ] && break
  [ "$i" = 30 ] && { echo "  $lead rejoined without the row written while it was down"; exit 1; }
  sleep 1
done

# The metrics fixture, from the monitoring overlay, where Prometheus would scrape and where
# the collector is the one thing of this release: it relays every exporter (pg_up 1, every
# default collector succeeding, which proves the one-shot created a pg_monitor role through
# the proxy whose password survived the secret's quoting traps), Patroni from every peer
# (exactly one primary) and etcd from every member (each with a leader), and nothing behind
# it resolves there, the exporters included.
metrics_ok=""
if [ "$case" = metrics ]; then
  col="${release}_postgres-patroni-metrics"
  want_up=$((2 * want + want_members))
  m=""
  for _ in $(seq 1 30); do
    m="$(docker run --rm --network monitoring curlimages/curl:8.17.0 -sSf -m 5 "http://$col:8889/metrics" 2>&1 || true)"
    [ "$(grep -cE '^up\{.*\} 1$' <<<"$m" || true)" = "$want_up" ] \
      && [ "$(grep -cE '^pg_up\{.*\} 1$' <<<"$m" || true)" = "$want" ] && break
    sleep 3
  done
  up_n="$(grep -cE '^up\{.*\} 1$' <<<"$m" || true)"
  if [ "$up_n" != "$want_up" ] || [ "$(grep -cE '^pg_up\{.*\} 1$' <<<"$m" || true)" != "$want" ]; then
    echo "  $col: reaches $up_n of $want_up targets, or an exporter does not reach its peer:"
    grep -E '^up\{|^pg_up\{|^curl' <<<"$m" | sed 's/^/    /'
    docker service logs --tail 5 "${release}_postgres-patroni-exporter-user" 2>&1 | sed 's/^/    /'
    exit 1
  fi
  failed="$(grep -E '^pg_scrape_collector_success\{.*\} 0$' <<<"$m" || true)"
  [ -z "$failed" ] || { echo "  failing exporter collectors (a missing privilege):"; echo "$failed" | sed 's/^/    /'; exit 1; }
  primaries="$(grep -E '^patroni_primary\{' <<<"$m" | awk '{ s += $NF } END { print s + 0 }')"
  [ "$primaries" = 1 ] || { echo "  $col: relays $primaries Patroni primaries, want 1"; exit 1; }
  [ "$(grep -cE '^patroni_primary\{' <<<"$m" || true)" = "$want" ] || { echo "  $col: relays patroni_primary for fewer than $want peers"; exit 1; }
  [ "$(grep -cE '^etcd_server_has_leader\{.*\} 1$' <<<"$m" || true)" = "$want_members" ] \
    || { echo "  $col: not every etcd member reports a leader:"; grep -E '^etcd_server_has_leader' <<<"$m" | sed 's/^/    /'; exit 1; }
  role="$(local_sql "${release}_$(leader)" "SELECT rolsuper, rolconnlimit, pg_has_role(rolname, 'pg_monitor', 'member') FROM pg_roles WHERE rolname = 'exporter'")"
  [ "$role" = "f|3|t" ] || { echo "  role exporter is '$role' (rolsuper|rolconnlimit|pg_monitor), expected 'f|3|t'"; exit 1; }
  # As on the client overlay: the collector must resolve, and then nothing behind it may.
  probe="$(docker run --rm --network monitoring --entrypoint bash "$image" -c \
    "getent hosts $col >/dev/null || { echo no-collector; exit 0; }
     for h in tasks.$first_peer $etcd_alias tasks.$first_member ${release}_postgres-patroni-proxy ${release}_postgres-patroni-exporter-1 tasks.${release}_postgres-patroni-exporter-1; do getent hosts \$h >/dev/null && echo \$h; done; true")"
  case "$probe" in
    no-collector) echo "  the probe could not resolve $col on monitoring, so it proves nothing"; exit 1 ;;
    ?*) echo "  resolves on the monitoring overlay: $(echo $probe)"; exit 1 ;;
  esac
  # The alert rules the chart ships for operators to load (monitoring/), checked here because
  # nothing deploys them: their logic, under the promtool of a pinned Prometheus.
  chart="$(cd "$2" && pwd)"
  prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart/../prometheus-stack/Chart.yaml")"
  if ! out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}" \
      test rules /chart/ci/postgres-patroni-rules-test.yml 2>&1)"; then
    echo "  promtool test rules fails on monitoring/postgres-patroni-rules.yml:"
    echo "$out" | sed 's/^/    /'
    exit 1
  fi
  metrics_ok="; metrics on monitoring through the collector alone: $want exporters at pg_up 1 with every collector OK, Patroni from $want peers with one primary, etcd from $want_members members, nothing behind it resolvable, rules pass promtool"
fi

lifecycle_ok=""
if [ "$case" = lifecycle ]; then
  # What a long-lived cluster goes through, each step asserting rows rather than
  # convergence. Runs `swarmcli charts upgrade` itself, so it needs $SWARMCLI, as
  # scripts/e2e-test.sh is given.
  SWARMCLI="${SWARMCLI:-swarmcli}"
  chart="./$2"
  upgrade() { "$SWARMCLI" charts upgrade "$release" "$chart" --reuse-values "$@" >/dev/null; }
  task_of() { docker service ps -q --filter desired-state=running "$1" | sed -n 1p; }
  # The row count through the primary port, retried: after an event the cluster can settle
  # a few seconds before the proxy's checks mark the new primary up, as an app would see.
  rows() {
    local i out
    for i in $(seq 1 30); do
      if out="$(trap - ERR; sql 5432 'SELECT count(*) FROM e2e_patroni.t' 2>/dev/null)"; then
        printf '%s\n' "$out"
        return 0
      fi
      sleep 2
    done
    echo "  no answer through the primary port within 60s" >&2
    return 1
  }
  # A writer through the primary port, one id per second from $1, recording every id the
  # server acknowledged, until $2 exists.
  writer() {
    # Runs in the background, where a failed write is the expected case mid-switchover.
    trap - ERR
    local id="$1"
    while [ ! -e "$2" ]; do
      if sql 5432 "INSERT INTO e2e_patroni.t VALUES ($id, 'writer')" >/dev/null 2>&1; then echo "$id"; fi
      id=$((id + 1))
      sleep 1
    done
  }
  acked_present() {  # acked_present <file> <label>: every acknowledged id is in the table
    local ids missing
    ids="$(paste -sd, "$1")"
    [ -n "$ids" ] || { echo "  $2: the writer got no write acknowledged at all"; exit 1; }
    missing="$(sql 5432 "SELECT count(*) FROM unnest(ARRAY[$ids]) id WHERE id NOT IN (SELECT id FROM e2e_patroni.t)")"
    [ "$missing" = 0 ] || { echo "  $2: $missing acknowledged writes are missing"; exit 1; }
  }

  # 1. An upgrade that changes every service, which is what a re-tagged image does. The
  #    peers and etcd members carry com.swarmcli.rollout=sequential, so swarmcli replaces
  #    them one at a time: the cluster keeps a primary through it but for the switchover
  #    each restart of the current one causes, and no write the server acknowledged is
  #    lost.
  stop="$(mktemp -u)"; acked="$(mktemp)"
  writer 1000 "$stop" >"$acked" &
  wpid=$!
  before="$(for s in $peers $members; do task_of "$s"; done | sort)"
  # Memory limits, not labels: a deploy label is service metadata, and changing one
  # replaces no task. Resources are part of the task template, as an image is.
  extra="$(mktemp)"
  printf 'resources:\n  limits:\n    memory: "2G"\netcd:\n  resources:\n    limits:\n      memory: "512M"\n' >"$extra"
  upgrade -f "$extra" --timeout 20m || { touch "$stop"; echo "  the all-service upgrade did not roll out"; exit 1; }
  after=""
  for i in $(seq 1 60); do
    after="$(for s in $peers $members; do task_of "$s"; done | sort)"
    [ "$(printf '%s\n' $after | grep -c .)" = "$((want + want_members))" ] \
      && [ -z "$(comm -12 <(echo "$before") <(echo "$after"))" ] && break
    [ "$i" = 60 ] && { touch "$stop"; echo "  the upgrade left some peer or member on its old task"; exit 1; }
    sleep 5
  done
  touch "$stop"; wait "$wpid" || true
  # Acknowledged writes alone do not tell one at a time from all at once. The start times
  # do: one at a time, each new task starts only after the one before outlived its monitor
  # window (60s for a peer in this fixture, 30s for an etcd member); all at once, they
  # start within seconds of each other.
  starts="$(for k in $after; do docker inspect --format '{{.CreatedAt.Unix}} {{.ServiceID}}' "$k"; done | sort -n)"
  prev=""
  for t in $(printf '%s\n' "$starts" | cut -d' ' -f1); do
    if [ -n "$prev" ] && [ $((t - prev)) -lt 25 ]; then
      echo "  two new tasks started $((t - prev))s apart; the upgrade did not roll one service at a time:"
      printf '%s\n' "$starts" | while read -r at id; do
        echo "    $at $(docker service inspect --format '{{.Spec.Name}}' "$id")"
      done
      exit 1
    fi
    prev="$t"
  done
  wait_cluster "after the rolling upgrade"
  acked_present "$acked" "rolling upgrade"
  upgrade_acked="$(grep -c . "$acked")"

  # 2. The leader's container killed, as a crash would: Swarm restarts it, and the cluster
  #    has a writable primary again once the leader key expires.
  lead="$(leader)"
  docker kill "$(cid_of "${release}_${lead}")" >/dev/null
  write_until 3 "leader crash" >/dev/null
  wait_cluster "after the leader crashed"

  # 3. etcd loses its quorum. failsafe_mode keeps the primary writable while it still
  #    reaches every other peer, so no write fails.
  m2="$(printf '%s\n' $members | sed -n 2p)"; m3="$(printf '%s\n' $members | sed -n 3p)"
  stop_svc "$m2"; stop_svc "$m3"
  failed=0
  for id in $(seq 2000 2029); do
    sql 5432 "INSERT INTO e2e_patroni.t VALUES ($id, 'no quorum')" >/dev/null 2>&1 || failed=$((failed + 1))
    sleep 2
  done
  [ "$failed" = 0 ] || { echo "  $failed of 30 writes failed while etcd had no quorum (failsafe_mode)"; exit 1; }
  docker service scale --detach "$m2=1" "$m3=1" >/dev/null
  wait_cluster "after etcd regained its quorum"

  # 4. A replica rebuilt from an empty volume copies the primary again.
  lead="$(leader)"
  replica="$(for p in $peers; do [ "$p" = "${release}_${lead}" ] || echo "$p"; done | sed -n 1p)"
  vol="$(docker service inspect "$replica" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Source}}{{end}}')"
  stop_svc "$replica"
  for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$replica"); do docker rm -f "$c" >/dev/null; done
  docker volume rm "$vol" >/dev/null
  docker service scale --detach "$replica=1" >/dev/null
  wait_cluster "after rebuilding $replica from an empty volume"
  want_rows="$(rows)"
  for i in $(seq 1 30); do
    [ "$(local_sql "$replica" 'SELECT count(*) FROM e2e_patroni.t' 2>/dev/null || true)" = "$want_rows" ] && break
    [ "$i" = 30 ] && { echo "  $replica was rebuilt without every row"; exit 1; }
    sleep 1
  done

  # 5. Every peer stopped together, then started again: Patroni elects a leader among
  #    them from what they hold, and nothing is lost.
  for p in $peers; do docker service scale --detach "$p=0" >/dev/null; done
  for p in $peers; do stop_svc "$p"; done
  for p in $peers; do docker service scale --detach "$p=1" >/dev/null; done
  wait_cluster "after a full stop"
  got="$(rows)"
  [ "$got" = "$want_rows" ] || { echo "  rows after the full stop: $got, want $want_rows"; exit 1; }

  # 6. An etcd member lost for good, replaced as README.md § Replacing an etcd member
  #    says: removed and re-added with etcdctl, then started empty with rejoinMembers.
  stop_svc "$m3"
  for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$m3"); do docker rm -f "$c" >/dev/null; done
  docker volume rm "${release}_postgres-patroni-etcd-3" >/dev/null
  e1="$(cid_of "$(printf '%s\n' $members | sed -n 1p)")"
  id="$(docker exec "$e1" etcdctl member list | awk -F', ' '$3 == "postgres-patroni-etcd-3" { print $1 }')"
  docker exec "$e1" etcdctl member remove "$id" >/dev/null
  docker exec "$e1" etcdctl member add postgres-patroni-etcd-3 --peer-urls="http://$(echo "${release}" | tr '_.' '--')-etcd-3:2380" >/dev/null
  upgrade --set 'etcd.rejoinMembers={3}' --timeout 10m || { echo "  the rejoinMembers upgrade did not roll out"; exit 1; }
  for i in $(seq 1 30); do
    estatus="$(docker exec "$e1" etcdctl endpoint status --cluster -w json 2>/dev/null || true)"
    jq -e --argjson n "$want_members" 'length == $n and ([.[] | .Status.header.cluster_id] | unique | length) == 1' <<<"$estatus" >/dev/null 2>&1 && break
    [ "$i" = 30 ] && { echo "  the replaced etcd member did not rejoin"; exit 1; }
    sleep 2
  done
  wait_cluster "after replacing etcd member 3"
  got="$(rows)"
  [ "$got" = "$want_rows" ] || { echo "  rows after replacing etcd member 3: $got, want $want_rows"; exit 1; }

  # 7. etcd's majority lost for good, recovered as README.md § etcd lost its majority for
  #    good says: every member wiped, then started empty under a new etcd.generation while
  #    the primary runs. failsafe_mode keeps it writable throughout, and Patroni writes its
  #    state back into the new etcd. Without the new generation the rebuilt etcd keeps its
  #    ID with a lower raft term, and Patroni refuses it for good.
  for m in $members; do docker service scale --detach "$m=0" >/dev/null; done
  for m in $members; do
    stop_svc "$m"
    for c in $(docker ps -aq -f "label=com.docker.swarm.service.name=$m"); do docker rm -f "$c" >/dev/null; done
  done
  for k in $(seq 1 "$want_members"); do docker volume rm "${release}_postgres-patroni-etcd-$k" >/dev/null; done
  write_until 4 "etcd wiped" >/dev/null
  # rejoinMembers cleared too: step 6 set it, and a rebuilt cluster needs every member new.
  upgrade --set etcd.generation=2 --set 'etcd.rejoinMembers={}' --timeout 10m \
    || { echo "  the etcd.generation upgrade did not roll out"; exit 1; }
  wait_cluster "after rebuilding etcd from empty"
  # The leader writes its configuration back a loop or two after it retakes the leader key,
  # which is what wait_cluster saw, so this polls.
  conf=""
  for _ in $(seq 1 30); do
    conf="$(docker exec "$(cid_of "$(printf '%s\n' $peers | sed -n 1p)")" patronictl show-config 2>/dev/null || true)"
    grep -qx 'failsafe_mode: true' <<<"$conf" && break
    sleep 2
  done
  grep -qx 'failsafe_mode: true' <<<"$conf" || { echo "  Patroni did not write its configuration back into the rebuilt etcd within 60s:"; echo "$conf"; exit 1; }
  got="$(rows)"
  [ "$got" = "$((want_rows + 1))" ] || { echo "  rows after rebuilding etcd: $got, want $((want_rows + 1))"; exit 1; }

  lifecycle_ok=", rolled every service one at a time with $upgrade_acked acknowledged writes all kept, recovered from a leader crash, stayed writable without etcd quorum, rebuilt a replica from an empty volume, came back from a full stop, replaced an etcd member, and rebuilt etcd from empty under a running primary"
fi

echo "  cluster: leader + $((want - 1)) streaming replicas over $want_members etcd members; primary/replica ports route by role; nothing behind the proxy reachable from $net; failed over $failed_over and rejoined$metrics_ok$lifecycle_ok"
