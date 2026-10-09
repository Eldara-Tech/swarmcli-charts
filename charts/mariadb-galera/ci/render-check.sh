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

# The proxy fixtures render one extra service, and the metrics fixture an exporter
# per peer plus the one-shot that creates its user; every other fixture renders
# peers only.
proxy_svc=""
all="$(yq -r '.services | keys | .[]' "$f")"
if [ "$case_name" = "proxy" ] || [ "$case_name" = "proxy-published" ]; then
  proxy_svc="$(printf '%s\n' "$all" | { grep -E -- '-proxy$' || true; })"
  [ -n "$proxy_svc" ] || err "the proxy fixture rendered no proxy service"
elif grep -qE -- '-proxy$' <<<"$all"; then
  # Not `… | { grep -q … && err …; }`: the brace group runs in a pipeline subshell, so
  # err's fail=1 died with it and this check printed its failure but never failed.
  err "a proxy service is rendered for case '$case_name'; it must be opt-in"
fi
if [ "$case_name" != "metrics" ] && grep -qE -- '-exporter-' <<<"$all"; then
  err "exporter services are rendered for case '$case_name'; metrics must be opt-in"
fi
svcs="$(printf '%s\n' "$all" | { grep -E -- '^mariadb-galera-[0-9]+$' || true; })"
n_svcs="$(count "$svcs")"
if [ "$n_svcs" -ne "$want_peers" ]; then
  err "expected $want_peers peer services, rendered $n_svcs: $(echo "$svcs" | tr '\n' ' ')"
fi

# Every peer is a single replica in vip mode, and names ITSELF in wsrep-node-name
# and in the address it resolves for wsrep-node-address.
for s in $svcs; do
  [ "$(yq -r ".services.\"$s\".deploy.replicas" "$f")" = "1" ] \
    || err "$s: replicas is not 1 — two tasks would share one data dir"
  yq -r ".services.\"$s\".deploy.labels // [] | .[]" "$f" | grep -xF 'com.swarmcli.rollout=sequential' >/dev/null \
    || err "$s: lost com.swarmcli.rollout=sequential; an upgrade would restart every peer at once"
  [ "$(yq -r ".services.\"$s\".deploy.endpoint_mode" "$f")" = "vip" ] \
    || err "$s: endpoint_mode is not vip — dnsrr drops network aliases, so the per-peer and client aliases would silently not exist"
  cmd="$(yq -r ".services.\"$s\".command[0]" "$f")"
  grep -Fq -- "--wsrep-node-name=$s" <<<"$cmd" \
    || err "$s: does not set --wsrep-node-name=$s (peer identity crossed over)"
  # The advertised address must be a real local IP, established at start-up from
  # /etc/hosts. Galera BINDS its IST listener to it, so a DNS name here fails with
  # "Failed to open IST listener ... Host not found (authoritative)" and the joiner
  # aborts — which is how this chart burned a CI run.
  grep -Fq -- '--wsrep-node-address="$$SELF_ADDR"' <<<"$cmd" \
    || err "$s: does not advertise the address it established at start-up"
  # Assert the CODE, not a string that also appears in the comment above it: the
  # first version of this grepped for "/etc/hosts", which the explanatory comment
  # satisfies on its own, so swapping the real lookup to /dev/null passed.
  grep -Fq 'SELF_ADDR="$$(awk -v h="$$(hostname)"' <<<"$cmd" \
    || err "$s: no longer establishes its own address with the /etc/hosts lookup"
  grep -Fq '/etc/hosts)"' <<<"$cmd" \
    || err "$s: the address lookup no longer reads /etc/hosts"
  # An `x && err` here would exit the whole script under `set -e` on the HAPPY
  # path, because the grep correctly finds nothing. It has to be an if.
  if grep -Fq 'tasks.' <<<"$(grep -F 'SELF_ADDR=' <<<"$cmd")"; then
    err "$s: sets its own address to a tasks.<...> NAME — Galera cannot bind a listener to one"
  fi
  # No silent fallback: a peer that cannot find its own address must refuse to
  # start rather than join advertising something nothing can dial.
  grep -Fq 'cannot determine this peer own address' <<<"$cmd" \
    || err "$s: lost the hard failure when its own address cannot be determined"
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
labels="$(for s in $svcs; do yq -r ".services.\"$s\".deploy.placement.constraints // [] | .[]" "$f"; done | { grep -E 'node\.labels\.' || true; })"
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

# The client alias: on every peer when there is no proxy, and on the proxy ALONE
# when there is. Two things answering the same name would defeat the proxy.
alias_count="$(yq -r '[.services.*.networks[] | select(tag == "!!map") | .aliases // [] | .[] | select(. == "mariadb")] | length' "$f")"
if [ -n "$proxy_svc" ]; then
  [ "$alias_count" -eq 1 ] \
    || err "client alias 'mariadb' is on $alias_count services; with the proxy on it belongs to the proxy alone"
  if ! yq -r ".services.\"$proxy_svc\".networks.*.aliases // [] | .[]" "$f" | grep -xF 'mariadb' >/dev/null; then
    err "the client alias is not on the proxy"
  fi
else
  [ "$alias_count" -eq "$want_peers" ] \
    || err "client alias 'mariadb' is on $alias_count of $want_peers peers"
fi

# With the proxy on: every peer must be a backend, checked on the responder port,
# and the check must be the HTTP Synced probe — a bare TCP check would route to a
# peer that is listening but not Synced, which is the whole point of the responder.
if [ -n "$proxy_svc" ]; then
  # CMD-SHELL here means dash, which has no /dev/tcp: the check would fail forever
  # and Swarm would kill the proxy on a loop. This cost a CI run.
  hc0="$(yq -r ".services.\"$proxy_svc\".healthcheck.test[0] // \"\"" "$f")"
  [ "$hc0" != "CMD-SHELL" ] \
    || err "proxy healthcheck uses CMD-SHELL (dash, no /dev/tcp); use CMD with an explicit bash"

  cfg="$(yq -r ".services.\"$proxy_svc\".environment.HAPROXY_CFG" "$f")"
  grep -Fq 'option httpchk' <<<"$cfg" || err "proxy does not use an HTTP check"
  grep -Fq 'http-check expect status 200' <<<"$cfg" || err "proxy does not require a 200 from the Synced responder"
  # The Synced responder's port, not the election's (4566), which listens too.
  port="$(yq -r '.services.*.command[0]' "$f" | { grep -oE 'TCP-LISTEN:[0-9]+,fork,reuseaddr EXEC:/usr/local/bin/galera-synced-check' || true; } | sed -n 1p | sed 's/^TCP-LISTEN:\([0-9]*\),.*/\1/')"
  [ -n "$port" ] || err "no peer runs the Synced responder"
  for s in $svcs; do
    grep -Eq "server $s $s:[0-9]+ check port $port" <<<"$cfg" \
      || err "peer $s is not a proxy backend checked on the responder port $port"
    grep -Fq 'galera-synced-check' <<<"$(yq -r ".services.\"$s\".command[0]" "$f")" \
      || err "peer $s does not run the Synced responder the proxy checks"
  done
fi

# The healthcheck must run as the mysql unix user, with --su-mysql FIRST. Any other
# ordering is silently wrong (the script re-execs through gosu and drops earlier
# options), and without it the check authenticates from a file in the data dir that
# a state transfer deletes — so it fails forever on a healthy peer and Swarm kills
# it every startPeriod. That cost a CI run.
for s in $svcs; do
  hc="$(yq -r ".services.\"$s\".healthcheck.test // [] | join(\" \")" "$f")"
  # Exact, not a prefix: `--su-mysql` on its own runs no tests at all and would
  # report healthy unconditionally. The chart owns this list entirely, so there is
  # no legitimate variation to allow for.
  want_hc='CMD-SHELL test -e /tmp/galera-electing || exec healthcheck.sh --su-mysql --connect --galera_ready'
  if [ -n "$hc" ] && [ "$hc" != "$want_hc" ]; then
    err "$s: healthcheck is '$hc', expected '$want_hc' — --su-mysql must come first (the script re-execs and drops earlier options) and the probe must be --galera_ready, not --galera_online, which would kill donors"
  fi
done

# Ports: a peer never publishes in ingress mode (several peers publish the same
# port), and never Galera's own.
for s in $svcs; do
  for m in $(yq -r ".services.\"$s\".ports // [] | .[] | .mode" "$f"); do
    [ "$m" = "host" ] || err "$s: port published in '$m' mode; only host mode can be repeated across peers"
  done
done
# With the proxy on, the SQL port belongs to the proxy alone: a peer publishing it
# too lets external clients bypass the proxy's health checks.
if [ -n "$proxy_svc" ]; then
  n_peer_ports="$(yq -r '[.services | to_entries | .[] | select(.key | test("-proxy$") | not) | .value.ports // [] | .[]] | length' "$f")"
  [ "$n_peer_ports" -eq 0 ] \
    || err "$n_peer_ports peer port(s) published with the proxy on; the proxy must be the only external endpoint"
  pports="$(yq -r ".services.\"$proxy_svc\".ports // [] | .[] | (.published | tostring) + \"/\" + .mode" "$f")"
  if [ "$case_name" = "proxy-published" ]; then
    [ "$pports" = "3306/ingress" ] \
      || err "proxy publishes '$(echo $pports)', expected exactly 3306/ingress"
  else
    [ -z "$pports" ] || err "proxy publishes '$(echo $pports)' with exposure disabled"
  fi
fi
for p in $(yq -r '.services.*.ports // [] | .[] | .published' "$f"); do
  case "$p" in
    4567|4568|4444) err "Galera port $p is published; replication must stay on the overlay" ;;
  esac
done

# Metrics: one exporter per peer, watching THAT peer. An exporter pointed at its
# neighbour renders, scrapes and graphs perfectly well — under the wrong peer's
# name — so identity is checked per peer, like the gcomm list above.
if [ "$case_name" = "metrics" ]; then
  exporters="$(printf '%s\n' "$all" | { grep -E -- '-exporter-[0-9]+$' || true; })"
  [ "$(count "$exporters")" -eq "$want_peers" ] \
    || err "expected $want_peers exporter services, rendered $(count "$exporters")"
  for s in $svcs; do
    e="mariadb-galera-exporter-${s##*-}"
    cmd="$(yq -r ".services.\"$e\".command[0] // \"\"" "$f")"
    grep -Eq -- "--mysqld\.address=tasks\.[A-Za-z0-9_.-]*_$s:3306( |$)" <<<"$cmd" \
      || err "$e: does not scrape its own peer at tasks.<release>_$s:3306"
    grep -Fq 'MYSQLD_EXPORTER_PASSWORD="$$(cat /run/secrets/mariadb_galera_exporter_password)"' <<<"$cmd" \
      || err "$e: does not read its password from the mounted secret"
    # Exactly the two discovery labels: once a service opts in, every deploy label
    # it carries is readable through Prometheus's targets API, so the fixture's
    # own `labels` must not reach it.
    lbls="$(yq -r ".services.\"$e\".deploy.labels // [] | sort | join(\",\")" "$f")"
    [ "$lbls" = "prometheus.io/port=9104,prometheus.io/scrape=true" ] \
      || err "$e: deploy labels are '$lbls', expected exactly the two discovery labels"
    nets="$(yq -r ".services.\"$e\".networks // [] | .[]" "$f" | sort | tr '\n' ' ')"
    [ "$nets" = "mariadb-galera-net monitoring " ] \
      || err "$e: networks are '$nets', expected the Galera overlay and the metrics overlay"
    [ "$(yq -r ".services.\"$e\".ports // [] | length" "$f")" = "0" ] \
      || err "$e: publishes a port; /metrics has no authentication"
    [ "$(yq -o=json -I=0 ".services.\"$e\".deploy.placement" "$f")" = "$(yq -o=json -I=0 ".services.\"$s\".deploy.placement" "$f")" ] \
      || err "$e: placement differs from $s's; the exporter belongs on its peer's node"
    # The peer itself must not change: turning metrics on would otherwise restart
    # every peer at once, and a peer on the metrics overlay exposes its SQL and
    # Galera ports to everything that can reach Prometheus.
    if yq -r ".services.\"$s\".networks | keys | .[]" "$f" | grep -xF monitoring >/dev/null; then
      err "$s: the peer joined the metrics overlay"
    fi
    if yq -r ".services.\"$s\".secrets // [] | .[]" "$f" | grep -xF mariadb_galera_exporter_password >/dev/null; then
      err "$s: the peer mounts the exporter secret"
    fi
  done

  # The one-shot that creates the user: runs once, may reach any peer, and holds
  # root, so it stays off the metrics overlay.
  u="mariadb-galera-exporter-user"
  [ "$(yq -r ".services.\"$u\".deploy.restart_policy.condition // \"\"" "$f")" = "on-failure" ] \
    || err "$u: restart condition is not on-failure; it must run to completion once, and retry if the cluster is not writable yet"
  ucmd="$(yq -r ".services.\"$u\".command[0] // \"\"" "$f")"
  for s in $svcs; do
    grep -Eq "tasks\.[A-Za-z0-9_.-]*_$s( |;)" <<<"$ucmd" \
      || err "$u: does not try peer $s"
  done
  # The statements carry the exporter password, so they go in on stdin: `-e` would put
  # it in the client's argv, readable on the node through ps and /proc/<pid>/cmdline.
  if grep -Eq -- '(^|[[:space:]])(-e|--execute)([[:space:]=]|$)' <<<"$ucmd"; then
    err "$u: passes SQL to the client on its command line; the exporter password would be in argv"
  fi
  grep -Fq 'SET SESSION sql_log_off = 1;' <<<"$ucmd" \
    || err "$u: no longer turns off the general query log for the session that sets the password"
  grep -Fq "GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO" <<<"$ucmd" \
    || err "$u: the grant changed; anything wider than PROCESS, REPLICATION CLIENT, SLAVE MONITOR reads data, and anything narrower fails a default collector"
  if yq -r ".services.\"$u\".networks // [] | .[]" "$f" | grep -xF monitoring >/dev/null; then
    err "$u: joined the metrics overlay while holding the root password"
  fi

  # The dashboard shipped for operators (monitoring/): every query scoped to the selected
  # cluster, or two releases' peers would mix in one panel.
  gd="$(dirname "$0")/../monitoring/galera-dashboard.json"
  unscoped="$(yq -p json -o yaml -r '.. | select(tag == "!!map" and has("expr")) | .expr' "$gd" | grep -vF 'stack="$stack"' || true)"
  [ -z "$unscoped" ] || err "$gd has queries not scoped to the selected cluster: $unscoped"
fi

# EXACTLY ONE peer may be able to bootstrap, in any fixture. This is the assertion
# that matters most, and the one whose absence let a broken chart reach CI: when
# every peer carried the "bootstrap if no peer answers" branch, a first install
# started them all at once with empty data dirs and none listening yet, so each
# formed its own cluster and wsrep_cluster_size stayed at 1 on all three. They
# still converged and still reported healthy — which is precisely why this has to
# be checked on the render rather than trusted to the deploy.
#
# Only a forced peer bootstraps unconditionally; every other peer, peer 1 included,
# goes through the rejoin wait, whose election decides who forms the cluster, a first
# install's included. A second unconditional bootstrapper would form a rival cluster.
# The wait's safe_to_bootstrap clause is not one: Galera marks at most one peer, and
# only the last to leave a cluster that stopped one peer at a time.
forced="$(grep -cF 'cluster.forceBootstrap names this peer' "$f" || true)"
waiters="$(grep -cF 'REJOINING PEER:' "$f" || true)"

want_forced=0
if [ "$case_name" = "force-bootstrap" ]; then want_forced=1; fi
[ "$forced" -eq "$want_forced" ] \
  || err "$forced peers bootstrap unconditionally, expected $want_forced"
[ "$waiters" -eq "$((want_peers - forced))" ] \
  || err "$waiters peers wait to rejoin, expected every peer but the forced one ($((want_peers - forced)))"

# Every peer but a forced one waits for ANOTHER peer to resolve before starting
# mariadbd. Swarm publishes a task in DNS only once it is healthy, so after a full
# stop nothing resolves: a peer that starts anyway dies with `No address to connect`
# in a loop that also rewrites grastate.dat to seqno -1, so the cluster can never
# recover on its own and the record the operator needs to recover it is gone.
for s in $svcs; do
  cmd="$(yq -r ".services.\"$s\".command[0]" "$f")"
  grep -Fq 'cluster.forceBootstrap names this peer' <<<"$cmd" && continue
  grep -Fq 'getent hosts "$$p" >/dev/null || continue' <<<"$cmd" \
    || err "$s: starts mariadbd without waiting for a peer to resolve; after a full stop it would crash-loop"
  # A member is a peer that answers on the Galera port, the one thing worth joining.
  # An electing peer resolves too, and without a healthcheck any running peer does,
  # so resolving alone must not count.
  grep -Fq 'if timeout 2 bash -c "exec 3<>/dev/tcp/$$p/4567" 2>/dev/null; then' <<<"$cmd" \
    && grep -Fq 'MEMBER="$$p"' <<<"$cmd" \
    || err "$s: does not tell a member by its Galera port; it would join a peer that is not in a cluster"
  wait_list="$(grep -E '^[[:space:]]*for p in tasks\.' <<<"$cmd" | tail -1)"
  if grep -Eq "tasks\.[A-Za-z0-9_.-]*_$s( |;)" <<<"$wait_list"; then
    err "$s: waits for its own name, which resolves only once it is already healthy"
  fi
  for p in $svcs; do
    [ "$p" = "$s" ] && continue
    grep -Eq "tasks\.[A-Za-z0-9_.-]*_$p( |;)" <<<"$wait_list" \
      || err "$s: does not wait on peer $p"
  done
  # The one exit from an all-down cluster without an operator: the peer Galera marked
  # as the last to leave. Present in every peer, whatever cluster.forceBootstrap says,
  # so that clearing that value does not restart every peer at once.
  grep -Fq "if grep -qx 'safe_to_bootstrap: 1' /var/lib/mysql/grastate.dat 2>/dev/null; then" <<<"$cmd" \
    || err "$s: lost the safe_to_bootstrap exit; a cluster stopped one peer at a time would never restart"
  # The election for an all-down cluster. Each property here is what keeps it from
  # forming a cluster on stale data: only peers with data take part, all of them
  # must have reported, and the highest seqno wins (ties to the lowest peer number,
  # so every peer computes the same winner).
  grep -Fq "socat TCP-LISTEN:4566,fork,reuseaddr SYSTEM:'cat /tmp/galera-position'" <<<"$cmd" \
    || err "$s: does not serve its position for the election"
  # An empty peer reports -2, below any real position, so it can win only when every
  # peer is empty, as on a first install. Reporting anything higher would let a
  # rebuilt peer form a cluster that the others then copy, losing every row.
  grep -Fq 'SEQNO=-2' <<<"$cmd" \
    || err "$s: an empty peer does not report -2; it could win and wipe the others"
  # mariadb 12.3.3 refuses --wsrep-recover without a cluster address, which would
  # leave every crashed peer without a position and the election stuck.
  grep -Fq -- '--wsrep-cluster-address=gcomm:// --wsrep-recover' <<<"$cmd" \
    || err "$s: --wsrep-recover has no cluster address; it fails on mariadb 12.3.3 and the election never completes after a crash"
  # A marker from an earlier round that this peer no longer wins must not stop it
  # reporting, or the others wait for it forever.
  grep -Fq 'ELECTED=no' <<<"$(sed -n '/WINNER" != /,/fi/p' <<<"$cmd")" \
    || err "$s: a peer holding a stale election marker never reports again; the election would never complete"
  grep -Fq "grep -c .)\" -eq $((want_peers - 1)) ]; then" <<<"$cmd" \
    || err "$s: does not wait for all $want_peers peers before electing; a missing peer may hold the newest data"
  grep -Fq "sort -k2,2nr -k1,1n" <<<"$cmd" \
    || err "$s: the election no longer picks the highest seqno, then the lowest peer number"
  # Exactly two ways for a non-forced peer to bootstrap: the safe_to_bootstrap exit and
  # winning the election. A third, such as the old "bootstrap if no peer answers"
  # seed, races the election and forms a rival cluster.
  bootstraps="$(grep -cF "GCOMM='gcomm://'" <<<"$cmd" || true)"
  [ "$bootstraps" -eq 2 ] \
    || err "$s: $bootstraps places set GCOMM='gcomm://', expected 2 (the safe_to_bootstrap exit and the election's winner)"
  # A peer reports, compares and claims under its OWN number. Under another, two peers
  # would each find themselves the winner of a tie and both bootstrap.
  own="${s##*-}"
  grep -Fq "printf '%s %s\n' $own \"\$\$SEQNO\" > /tmp/galera-position" <<<"$cmd" \
    && grep -Fq "\"\$\$STATES\" $own \"\$\$SEQNO\"" <<<"$cmd" \
    && grep -Fq "if [ \"\$\$WINNER\" = $own ]; then" <<<"$cmd" \
    || err "$s: the election does not report, compare and claim under peer number $own; two peers could both win"
done
for prt in $(yq -r '.services.*.ports // [] | .[] | .published' "$f"); do
  [ "$prt" != 4566 ] || err "the election port 4566 is published; it must stay inside the overlay"
done
# Without a volume a winner's marker would not survive its restart, and it would win
# again on every one; it must bootstrap in place instead.
if [ "$case_name" = "ephemeral" ] && grep -Fq 'touch /var/lib/mysql/.galera-elected' "$f"; then
  err "the ephemeral fixture's winner restarts to bootstrap; without a volume its marker is lost and it never forms the cluster"
fi
# Galera refuses to bootstrap from safe_to_bootstrap: 0, which every peer has after a
# simultaneous stop, so a forced peer must set it or the recovery lever does nothing.
if [ "$forced" -gt 0 ]; then
  grep -Fq "sed -i 's/^safe_to_bootstrap: 0\$\$/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat" "$f" \
    || err "the forced peer does not mark itself safe_to_bootstrap; Galera would refuse to bootstrap it"
fi

# The ephemeral fixture must render no volumes and no pins at all.
if [ "$case_name" = "ephemeral" ]; then
  [ "$(yq -r '.volumes // {} | length' "$f")" = "0" ] \
    || err "ephemeral fixture rendered a top-level volumes: block"
  [ "$(yq -r '[.services.*.deploy.placement] | map(select(. != null)) | length' "$f")" = "0" ] \
    || err "ephemeral fixture rendered a placement block — tasks would strand Pending on a missing label"
fi

exit "$fail"
