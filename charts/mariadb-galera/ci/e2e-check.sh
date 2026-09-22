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
#   docker node update --label-add mariadb-galera-<N>=true <node>   (N = 1..5)
set -euo pipefail

release="$1"

# Peer services, in peer order, discovered from the stack rather than assumed, so
# this works for the 3- and 5-peer fixtures alike.
all_svcs="$(docker service ls --filter "label=com.docker.stack.namespace=${release}" --format '{{.Name}}' | sort)"
[ -n "$all_svcs" ] || { echo "  no services found for stack ${release}"; exit 1; }
# The proxy is a service in this stack but it is NOT a peer: counting it would make
# `want` one too many and then try to run SQL inside HAProxy.
peers="$(printf '%s\n' "$all_svcs" | { grep -vE -- '-proxy$' || true; })"
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
  echo "  ${release}: $want peers, all Synced, cross-peer write replicated, endpoint survived losing $victim ($ok/$((ok+fail)) queries OK)"
  exit 0
fi

echo "  ${release}: $want peers, all Synced, cross-peer write replicated OK"
