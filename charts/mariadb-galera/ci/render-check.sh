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
#   * endpoint_mode switched to dnsrr drops network aliases, so the per-peer and
#     client aliases silently stop existing and every state transfer fails to
#     resolve its target;
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

# Every peer is a single replica in vip mode, and names ITSELF in wsrep-node-name
# and in the address it resolves for wsrep-node-address.
for s in $svcs; do
  [ "$(yq -r ".services.\"$s\".deploy.replicas" "$f")" = "1" ] \
    || err "$s: replicas is not 1 — two tasks would share one data dir"
  [ "$(yq -r ".services.\"$s\".deploy.endpoint_mode" "$f")" = "vip" ] \
    || err "$s: endpoint_mode is not vip — dnsrr drops network aliases, so the per-peer and client aliases would silently not exist"
  cmd="$(yq -r ".services.\"$s\".command[0]" "$f")"
  grep -Fq -- "--wsrep-node-name=$s" <<<"$cmd" \
    || err "$s: does not set --wsrep-node-name=$s (peer identity crossed over)"
  # The advertised address is resolved at runtime, so what must be per-peer here is
  # the name it resolves: tasks.<release>_<this peer>.
  grep -Eq "getent hosts 'tasks\.[A-Za-z0-9_.-]*_$s'" <<<"$cmd" \
    || err "$s: does not resolve its own tasks.<release>_$s address (peer identity crossed over)"
  grep -Fq -- '--wsrep-node-address="$$SELF_ADDR"' <<<"$cmd" \
    || err "$s: does not advertise the resolved address — a name that fails to resolve breaks every state transfer to it"
  grep -Fq 'rm -f /var/lib/mysql/wsrep_sst.pid' <<<"$cmd" \
    || err "$s: lost the stale wsrep_sst.pid cleanup — a peer interrupted mid-transfer would refuse to retry forever"
  grep -Fq -- "--wsrep-sst-auth=mysql:" <<<"$cmd" \
    || err "$s: lost the passwordless unix_socket SST auth"
  # The gcomm list must name every peer, or a peer cannot find the cluster.
  for p in $svcs; do
    grep -Eq "(gcomm://|,)tasks\.[A-Za-z0-9_.-]*_$p(,|')" <<<"$cmd" \
      || err "$s: gcomm list does not name peer $p by its tasks.<release>_$p address"
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

# EXACTLY ONE peer may be able to bootstrap, in any fixture. This is the assertion
# that matters most, and the one whose absence let a broken chart reach CI: when
# every peer carried the "bootstrap if no peer answers" branch, a first install
# started them all at once with empty data dirs and none listening yet, so each
# formed its own cluster and wsrep_cluster_size stayed at 1 on all three. They
# still converged and still reported healthy — which is precisely why this has to
# be checked on the render rather than trusted to the deploy.
#
# A forced peer and the seed peer both count as bootstrappers, and the template
# renders the seed branch only when no peer is forced, so the sum is always 1.
forced="$(grep -cF 'cluster.forceBootstrap names this peer' "$f" || true)"
seeds="$(grep -cF 'SEED PEER:' "$f" || true)"
waiters="$(grep -cF 'JOINING PEER:' "$f" || true)"

want_forced=0
if [ "$case_name" = "force-bootstrap" ]; then want_forced=1; fi
[ "$forced" -eq "$want_forced" ] \
  || err "$forced peers bootstrap unconditionally, expected $want_forced"
[ "$((seeds + forced))" -eq 1 ] \
  || err "$((seeds + forced)) peers can bootstrap ($seeds seed + $forced forced), expected exactly 1 — two racing bootstrappers each form their own cluster"
[ "$waiters" -eq "$((want_peers - 1))" ] \
  || err "$waiters peers are join-only, expected $((want_peers - 1))"

# A seed that bootstraps without first checking for live peers would, once rebuilt
# from an empty volume, form a rival cluster beside the survivors. Both halves of
# its guard must survive: the data-dir test and the port probe.
if [ "$seeds" -eq 1 ]; then
  grep -Fq 'if [ ! -d /var/lib/mysql/mysql ]; then' "$f" \
    || err "the seed peer lost its data-dir test — it would bootstrap on every restart"
  grep -Fq 'if [ "$$PEER_UP" = no ]; then' "$f" \
    || err "the seed peer lost its live-peer probe — a rebuilt seed would form a rival cluster"
fi

# Joining peers wait for someone to listen. Losing this does not corrupt anything —
# Swarm's restart policy still gets them there — but it turns a quiet first install
# into a burst of crash-restarts, so it is worth keeping honest.
if [ "$waiters" -gt 0 ]; then
  grep -Fq 'while [ "$$SECONDS" -lt 60 ]; do' "$f" \
    || err "joining peers lost their wait gate — they would crash-restart until the seed appears"
fi

# The ephemeral fixture must render no volumes and no pins at all.
if [ "$case_name" = "ephemeral" ]; then
  [ "$(yq -r '.volumes // {} | length' "$f")" = "0" ] \
    || err "ephemeral fixture rendered a top-level volumes: block"
  [ "$(yq -r '[.services.*.deploy.placement] | map(select(. != null)) | length' "$f")" = "0" ] \
    || err "ephemeral fixture rendered a placement block — tasks would strand Pending on a missing label"
fi

exit "$fail"
