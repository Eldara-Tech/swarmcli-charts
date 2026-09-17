#!/usr/bin/env bash
#
# Structural assertions on the RENDERED stack that `docker compose config` cannot
# make. scripts/test-charts.sh runs this per fixture, after the render:
#   $1 = rendered stack file   $2 = fixture case name
#
# What is worth asserting here is everything that makes this a CLUSTER rather than
# three unrelated databases — and every one of these has a plausible template bug
# that still renders as valid compose:
#   * a peer that reuses another peer's volume, node label or wsrep node name
#     (the copy-paste bug the peer loop exists to prevent) silently gives two
#     peers one data dir;
#   * a gcomm list missing a peer leaves that peer unable to find the cluster;
#   * endpoint_mode back to vip makes peer addresses resolve to a load-balanced
#     VIP, which Galera's group communication cannot use;
#   * an ingress-mode port, or a published Galera port, is accepted by compose and
#     rejected (or worse, exposed) only later.
#
# Deliberately free of bash 4 builtins (no mapfile): macOS /bin/bash is 3.2, and a
# check that only runs in CI is a check nobody runs before pushing.
set -euo pipefail

f="${1:?usage: render-check.sh <rendered-file> <case>}"
case_name="${2:-}"
fail=0
err() { echo "   RENDER-CHECK FAIL [$case_name]: $*" >&2; fail=1; }
count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

# Expected peer count per fixture.
want_peers=3
if [ "$case_name" = "five-peers" ]; then want_peers=5; fi

svcs="$(yq -r '.services | keys | .[]' "$f")"
n_svcs="$(count "$svcs")"
if [ "$n_svcs" -ne "$want_peers" ]; then
  err "expected $want_peers peer services, rendered $n_svcs: $(echo "$svcs" | tr '\n' ' ')"
fi

# Every peer is a single replica, dnsrr, and names ITSELF in wsrep-node-name /
# wsrep-node-address.
for s in $svcs; do
  [ "$(yq -r ".services.\"$s\".deploy.replicas" "$f")" = "1" ] \
    || err "$s: replicas is not 1 — two tasks would share one data dir"
  [ "$(yq -r ".services.\"$s\".deploy.endpoint_mode" "$f")" = "dnsrr" ] \
    || err "$s: endpoint_mode is not dnsrr — peer addresses would resolve to a VIP"
  cmd="$(yq -r ".services.\"$s\".command[0]" "$f")"
  grep -Fq -- "--wsrep-node-name=$s" <<<"$cmd" \
    || err "$s: does not set --wsrep-node-name=$s (peer identity crossed over)"
  grep -Fq -- "--wsrep-node-address=$s" <<<"$cmd" \
    || err "$s: does not set --wsrep-node-address=$s (peer identity crossed over)"
  grep -Fq -- "--wsrep-sst-auth=mysql:" <<<"$cmd" \
    || err "$s: lost the passwordless unix_socket SST auth"
  # The gcomm list must name every peer, or a peer cannot find the cluster.
  for p in $svcs; do
    grep -Eq "(gcomm://|,)$p(,|')" <<<"$cmd" \
      || err "$s: gcomm list does not name peer $p"
  done
done

# Distinct per-peer identity: node labels and volume sources must never repeat.
labels="$(yq -r '.services.*.deploy.placement.constraints // [] | .[]' "$f" | { grep -E 'node\.labels\.' || true; })"
n_labels="$(count "$labels")"
if [ "$n_labels" -gt 0 ]; then
  uniq_labels="$(printf '%s\n' "$labels" | sort -u | wc -l | tr -d ' ')"
  [ "$uniq_labels" -eq "$n_labels" ] \
    || err "peers share a node label ($n_labels pins, $uniq_labels distinct) — they would contend for one node"
  [ "$n_labels" -eq "$want_peers" ] \
    || err "expected $want_peers node-label pins, found $n_labels"
fi

vols="$(yq -r '.services.*.volumes // [] | .[]' "$f")"
n_vols="$(count "$vols")"
if [ "$n_vols" -gt 0 ]; then
  uniq_vols="$(printf '%s\n' "$vols" | sort -u | wc -l | tr -d ' ')"
  [ "$uniq_vols" -eq "$n_vols" ] \
    || err "peers share a data volume ($n_vols mounts, $uniq_vols distinct) — that corrupts the data dir"
  [ "$n_vols" -eq "$want_peers" ] \
    || err "expected $want_peers data mounts, found $n_vols"
fi

# The shared client alias must be on every peer, or DNS round-robin reaches only some.
alias_count="$(yq -r '[.services.*.networks.*.aliases // [] | .[] | select(. == "mariadb")] | length' "$f")"
[ "$alias_count" -eq "$want_peers" ] \
  || err "client alias 'mariadb' is on $alias_count of $want_peers peers"

# Ports: never ingress (several peers publish the same port), and never Galera's own.
pmodes="$(yq -r '.services.*.ports // [] | .[] | .mode' "$f")"
for m in $pmodes; do
  [ "$m" = "host" ] || err "port published in '$m' mode; only host mode can be repeated across peers"
done
for p in $(yq -r '.services.*.ports // [] | .[] | .published' "$f"); do
  case "$p" in
    4567|4568|4444) err "Galera port $p is published; replication must stay on the overlay" ;;
  esac
done

# Exactly one peer may bootstrap unconditionally, and only when asked to.
forced="$(grep -cF 'cluster.forceBootstrap names this peer' "$f" || true)"
want_forced=0
if [ "$case_name" = "force-bootstrap" ]; then want_forced=1; fi
[ "$forced" -eq "$want_forced" ] \
  || err "$forced peers bootstrap unconditionally, expected $want_forced — more than one is a split brain"

# The ephemeral fixture must render no volumes and no pins at all.
if [ "$case_name" = "ephemeral" ]; then
  [ "$(yq -r '.volumes // {} | length' "$f")" = "0" ] \
    || err "ephemeral fixture rendered a top-level volumes: block"
  [ "$(yq -r '[.services.*.deploy.placement] | map(select(. != null)) | length' "$f")" = "0" ] \
    || err "ephemeral fixture rendered a placement block — tasks would strand Pending on a missing label"
fi

exit "$fail"
