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
  # Query through the alias, which now belongs to the proxy. The client's error is kept:
  # a failure has to say whether it was refused, timed out or found no backend.
  via_proxy() {
    docker run --rm --network "$net" -e MYSQL_PWD="$pw" mariadb:12.3 \
      mariadb -h mariadb -uroot -N -B -e 'SELECT 1' 2>&1
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
    docker service ps "$proxy" --no-trunc --format '    {{.Name}} {{.CurrentState}} {{.Error}}' | sed -n '1,6p'
    for c in $(docker ps -q -f "label=com.docker.swarm.service.name=$proxy"); do
      docker logs --tail 30 "$c" 2>&1 | sed 's/^/    /'
    done
    exit 1
  fi

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
  rm -f "$extra" "$sizes"
  lifecycle_ok=", rejoined, re-synced a rebuilt peer 1, rolled an all-peer upgrade with quorum kept, elected a peer after a full stop and after a crash, and forced one with a peer lost"
fi

echo "  ${release}: $want peers, all Synced, cross-peer write replicated$metrics_ok$recovery_ok$lifecycle_ok OK"
