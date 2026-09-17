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
peers="$(docker service ls --filter "label=com.docker.stack.namespace=${release}" --format '{{.Name}}' | sort)"
want="$(printf '%s\n' "$peers" | wc -l | tr -d ' ')"
[ "$want" -gt 0 ] || { echo "  no services found for stack ${release}"; exit 1; }

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

echo "  ${release}: $want peers, all Synced, cross-peer write replicated OK"
