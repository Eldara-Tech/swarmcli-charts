#!/usr/bin/env bash
#
# Structural assertions on the RENDERED stack that `docker compose config` cannot
# make. scripts/test-charts.sh runs this per fixture, after the render:
#   $1 = rendered stack file   $2 = fixture case name
#
# What is worth asserting here is everything that makes this a CLUSTER rather than
# several unrelated databases, and every one of these has a plausible template bug that
# still renders as valid compose:
#   * a peer or etcd member reusing another's volume, node label or name (the copy-paste
#     bug the loops exist to prevent) gives two of them one data dir;
#   * an etcd member list missing a member, or a member advertising a URL that is not
#     its own entry in it, never forms a quorum;
#   * a proxy backend list missing a peer leaves that peer unreachable once it is primary;
#   * a healthcheck on etcd, or a strict one on the peers, deadlocks the first install or
#     kills a replica mid-copy, and still converges in a quick test;
#   * a peer, etcd or the REST API on the shared client overlay is reachable by every
#     app stack on it, unauthenticated.
#
# Deliberately free of bash 4 builtins (no mapfile): macOS /bin/bash is 3.2, and a check
# that only runs in CI is a check nobody runs before pushing.
set -euo pipefail

f="${1:?usage: render-check.sh <rendered-file> <case>}"
case_name="${2:-}"
fail=0
err() { echo "   RENDER-CHECK FAIL [$case_name]: $*" >&2; fail=1; }
count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

want_peers=3
want_members=3
case "$case_name" in
  two-peers) want_peers=2 ;;
  five) want_peers=5; want_members=5 ;;
esac
persist=yes
[ "$case_name" = ephemeral ] && persist=no
pinned=$persist
[ "$case_name" = unpinned ] && pinned=no

all="$(yq -r '.services | keys | .[]' "$f")"
peers="$(printf '%s\n' "$all" | { grep -E '^postgres-patroni-[0-9]+$' || true; } | sort -t- -k3,3n)"
members="$(printf '%s\n' "$all" | { grep -E '^postgres-patroni-etcd-[0-9]+$' || true; } | sort -t- -k4,4n)"
proxy="$(printf '%s\n' "$all" | { grep -xF 'postgres-patroni-proxy' || true; })"
[ "$(count "$peers")" -eq "$want_peers" ] || err "expected $want_peers peer services, rendered $(count "$peers"): $(echo $peers)"
[ "$(count "$members")" -eq "$want_members" ] || err "expected $want_members etcd services, rendered $(count "$members"): $(echo $members)"
[ -n "$proxy" ] || err "no proxy service rendered: without it nothing routes to the primary"
others="$(printf '%s\n' "$all" | { grep -vE '^postgres-patroni-([0-9]+|etcd-[0-9]+|proxy)$' || true; })"
[ -z "$others" ] || err "unexpected services rendered: $(echo $others)"

# The stack-internal overlay: chart-managed and not attachable, so nothing outside the
# stack joins it. Encrypted exactly when the fixture asks.
[ "$(yq -r '.networks.cluster.external // false' "$f")" = false ] || err "the cluster overlay is external: other stacks could join etcd's network"
[ "$(yq -r '.networks.cluster.attachable' "$f")" = false ] || err "the cluster overlay is attachable: any container could join etcd's network"
enc="$(yq -r '.networks.cluster.driver_opts.encrypted // "false"' "$f")"
if [ "$case_name" = internal-net ]; then
  [ "$enc" = true ] || err "network.encrypted did not encrypt the cluster overlay"
  [ "$(yq -r '.networks."postgres-patroni-net".driver_opts.encrypted // "false"' "$f")" = true ] \
    || err "network.encrypted did not encrypt the chart-managed client overlay"
else
  [ "$enc" = false ] || err "the cluster overlay is encrypted without network.encrypted"
fi

# --- etcd -------------------------------------------------------------------------
arg() {  # arg <service> <flag>: the value of --flag=… in its command
  yq -r ".services.\"$1\".command // [] | .[]" "$f" | sed -n "s/^--$2=//p"
}
initial_cluster=""
seen_ic=""
i=0
for s in $members; do
  i=$((i + 1))
  [ "$s" = "postgres-patroni-etcd-$i" ] || err "etcd member $i is named $s"
  [ "$(yq -r ".services.\"$s\".deploy.replicas" "$f")" = 1 ] || err "$s: replicas is not 1"
  [ "$(yq -r ".services.\"$s\".deploy.endpoint_mode" "$f")" = vip ] || err "$s: endpoint_mode is not vip, so its alias would not exist"
  [ "$(yq -r ".services.\"$s\".deploy.update_config.order" "$f")" = stop-first ] || err "$s: update order is not stop-first; two tasks would share one data dir"
  yq -r ".services.\"$s\".deploy.labels // [] | .[]" "$f" | grep -xF 'com.swarmcli.rollout=sequential' >/dev/null \
    || err "$s: lost com.swarmcli.rollout=sequential; an upgrade would restart every member at once and lose quorum"
  # Swarm publishes no DNS name of a task until its healthcheck passes, and every etcd
  # health endpoint needs quorum: a healthcheck here deadlocks the first install.
  [ "$(yq -r ".services.\"$s\".healthcheck // \"none\"" "$f")" = none ] || err "$s: has a healthcheck, which keeps its alias out of DNS until quorum, which needs that alias"
  [ "$(yq -r ".services.\"$s\".networks | keys | join(\",\")" "$f")" = cluster ] || err "$s: is not on the cluster overlay alone"
  [ "$(yq -r ".services.\"$s\".ports // [] | length" "$f")" = 0 ] || err "$s: publishes a port"
  [ "$(arg "$s" name)" = "$s" ] || err "$s: --name is '$(arg "$s" name)', not its service name"
  alias="$(yq -r ".services.\"$s\".networks.cluster.aliases // [] | .[]" "$f")"
  [ "$(arg "$s" initial-advertise-peer-urls)" = "http://$alias:2380" ] || err "$s: advertises peer URL '$(arg "$s" initial-advertise-peer-urls)', not its alias '$alias'"
  [ "$(arg "$s" advertise-client-urls)" = "http://$alias:2379" ] || err "$s: advertises client URL '$(arg "$s" advertise-client-urls)', not its alias"
  # etcd compares its own advertised URL with its entry in --initial-cluster as strings.
  ic="$(arg "$s" initial-cluster)"
  printf '%s\n' "$ic" | tr ',' '\n' | grep -xF "$s=http://$alias:2380" >/dev/null || err "$s: its own entry is missing from --initial-cluster"
  [ -z "$initial_cluster" ] || [ "$ic" = "$initial_cluster" ] || err "$s: --initial-cluster differs between members"
  initial_cluster="$ic"
  # Members with different tokens form different clusters out of one member list.
  tok="$(arg "$s" initial-cluster-token)"
  case "$tok" in
    *-postgres-patroni-1) ;;
    *) err "$s: --initial-cluster-token '$tok' does not end with cluster.name and etcd.generation" ;;
  esac
  [ -z "${token:-}" ] || [ "$tok" = "$token" ] || err "$s: --initial-cluster-token differs between members"
  token="$tok"
  seen_ic="$seen_ic$s=http://$alias:2380,"
  state="$(arg "$s" initial-cluster-state)"
  want_state=new
  [ "$case_name" = rejoin ] && [ "$i" = 3 ] && want_state=existing
  [ "$state" = "$want_state" ] || err "$s: --initial-cluster-state is '$state', want $want_state"
  [ "$(arg "$s" auto-compaction-mode)" = periodic ] && [ -n "$(arg "$s" auto-compaction-retention)" ] \
    || err "$s: no auto-compaction; Patroni's key history would fill the backend quota"
done
[ "$initial_cluster" = "${seen_ic%,}" ] || err "--initial-cluster '$initial_cluster' does not name exactly the rendered members"
aliases="$(for s in $members; do yq -r ".services.\"$s\".networks.cluster.aliases // [] | .[]" "$f"; done)"
[ "$(count "$aliases")" = "$(printf '%s\n' "$aliases" | sort -u | wc -l | tr -d ' ')" ] || err "etcd aliases are not distinct"

# --- peers ------------------------------------------------------------------------
cfg_of() { yq -r ".services.\"$1\".environment.PATRONI_YAML" "$f"; }
hosts_want="$(printf '%s\n' $aliases | sed 's/$/:2379/' | paste -sd, -)"
scopes=""
i=0
for s in $peers; do
  i=$((i + 1))
  [ "$s" = "postgres-patroni-$i" ] || err "peer $i is named $s"
  [ "$(yq -r ".services.\"$s\".deploy.replicas" "$f")" = 1 ] || err "$s: replicas is not 1 — two tasks would share one data dir"
  [ "$(yq -r ".services.\"$s\".deploy.endpoint_mode" "$f")" = vip ] || err "$s: endpoint_mode is not vip"
  [ "$(yq -r ".services.\"$s\".deploy.update_config.order" "$f")" = stop-first ] || err "$s: update order is not stop-first"
  yq -r ".services.\"$s\".deploy.labels // [] | .[]" "$f" | grep -xF 'com.swarmcli.rollout=sequential' >/dev/null \
    || err "$s: lost com.swarmcli.rollout=sequential; an upgrade would restart every peer at once"
  [ "$(yq -r ".services.\"$s\".hostname" "$f")" = "$s" ] || err "$s: hostname is not its service name, so the /etc/hosts lookup finds nothing"
  [ "$(yq -r ".services.\"$s\".networks | join(\",\")" "$f")" = cluster ] || err "$s: is not on the cluster overlay alone; app stacks would reach it past the proxy"
  [ "$(yq -r ".services.\"$s\".ports // [] | length" "$f")" = 0 ] || err "$s: publishes a port"
  cfg="$(cfg_of "$s")"
  [ "$(yq -r '.name' <<<"$cfg")" = "$s" ] || err "$s: Patroni member name is '$(yq -r '.name' <<<"$cfg")'"
  scopes="$scopes$(yq -r '.scope' <<<"$cfg")
"
  [ "$(yq -r '.etcd3.hosts' <<<"$cfg")" = "$hosts_want" ] || err "$s: etcd3.hosts '$(yq -r '.etcd3.hosts' <<<"$cfg")' does not name every member ($hosts_want)"
  [ "$(yq -r '.bootstrap.dcs.failsafe_mode' <<<"$cfg")" = true ] || err "$s: failsafe_mode is off; losing etcd's quorum would demote a healthy primary"
  [ "$(yq -r '.restapi.authentication // "none"' <<<"$cfg")" = none ] || err "$s: REST API credentials are in the config file, which breaks \`docker exec … patronictl\`"
  [ "$(yq -r '.postgresql.data_dir' <<<"$cfg")" = /data/db/pgdata ] || err "$s: data_dir is not below the /data/db mount"
  # Exactly these: anything looser lets a network client in without a password, and
  # nothing else would notice, since every test logs in with the right one.
  hba="$(yq -r '.postgresql.pg_hba[]' <<<"$cfg")"
  [ "$hba" = "local all all trust
host replication replicator all scram-sha-256
host all all all scram-sha-256" ] || err "$s: pg_hba is not the chart's three entries: $(echo $hba)"
  [ "$(yq -r ".services.\"$s\".secrets | map(.source // .) | sort | join(\",\")" "$f")" \
    = postgres_patroni_replication_password,postgres_patroni_restapi_password,postgres_patroni_superuser_password ] \
    || err "$s: does not mount exactly the three password secrets"
  # Assert the CODE, not a string the comments also contain.
  cmd="$(yq -r ".services.\"$s\".command[0]" "$f")"
  grep -Fq 'SELF_ADDR="$$(awk -v h="$$(hostname)"' <<<"$cmd" || err "$s: no longer establishes its own address with the /etc/hosts lookup"
  grep -Fq '/etc/hosts)"' <<<"$cmd" || err "$s: the address lookup no longer reads /etc/hosts"
  grep -Fq 'export PATRONI_POSTGRESQL_CONNECT_ADDRESS="$$SELF_ADDR:5432"' <<<"$cmd" || err "$s: does not advertise the address it established for PostgreSQL"
  grep -Fq 'export PATRONI_RESTAPI_CONNECT_ADDRESS="$$SELF_ADDR:8008"' <<<"$cmd" || err "$s: does not advertise the address it established for the REST API"
  grep -Fq 'exec patroni /tmp/patroni.yml' <<<"$cmd" || err "$s: does not exec Patroni"
  # Passwords come from the secret files, never from the compose environment.
  if yq -r ".services.\"$s\".environment | keys | .[]" "$f" | grep -i 'password' >/dev/null; then
    err "$s: a password variable is in the service environment, i.e. in \`docker inspect\`"
  fi
  # /liveness, never a check a replica fails while pg_basebackup copies the primary.
  hc="$(yq -r ".services.\"$s\".healthcheck.test // [] | join(\" \")" "$f")"
  [ "$hc" = "CMD curl -fsS -o /dev/null http://127.0.0.1:8008/liveness" ] || err "$s: healthcheck is '$hc', not Patroni's /liveness"
  params="$(yq -r '.postgresql.parameters.max_connections // ""' <<<"$cfg")/$(yq -r '.bootstrap.dcs.postgresql.parameters.max_connections // ""' <<<"$cfg")"
  if [ "$case_name" = published ]; then
    [ "$params" = 200/200 ] || err "$s: postgresql.parameters did not reach both the local and the bootstrap config ($params)"
  else
    [ "$params" = / ] || err "$s: renders PostgreSQL parameters nobody set ($params)"
  fi
done
[ "$(printf '%s' "$scopes" | sort -u | wc -l | tr -d ' ')" = 1 ] || err "the peers do not share one Patroni scope: $(echo $scopes)"

# --- volumes and pins: distinct per service, peer N and member N on label N --------
vol_of() { yq -r ".services.\"$1\".volumes // [] | .[]" "$f"; }
vols=""
for s in $peers $members; do
  v="$(vol_of "$s")"
  if [ "$persist" = yes ]; then
    [ "$(count "$v")" = 1 ] || err "$s: expected one volume, got $(count "$v")"
    case "$s" in
      *-etcd-*) want_target=/var/lib/etcd ;;
      *) want_target=/data/db ;;
    esac
    [ "${v#*:}" = "$want_target" ] || err "$s: volume mounted at '${v#*:}', want $want_target"
    vols="$vols${v%%:*}
"
  else
    [ -z "$v" ] || err "$s: mounts a volume with persistence off"
  fi
  pins="$(yq -r ".services.\"$s\".deploy.placement.constraints // [] | .[]" "$f")"
  n="${s##*-}"
  if [ "$pinned" = yes ]; then
    [ "$pins" = "node.labels.postgres-patroni-$n == true" ] || err "$s: pinned by '$(echo $pins)', want node.labels.postgres-patroni-$n"
  else
    [ -z "$pins" ] || err "$s: renders placement '$(echo $pins)' although nothing needs pinning"
  fi
done
if [ "$persist" = yes ]; then
  n_vols="$(printf '%s' "$vols" | grep -c . || true)"
  [ "$n_vols" = "$(printf '%s' "$vols" | sort -u | grep -c . || true)" ] || err "volumes are shared between services: $(echo $vols)"
  if [ "$case_name" = bind-mount ]; then
    printf '%s' "$vols" | grep -v '^/' >/dev/null && err "bind-mount: a volume is not a host path"
    [ "$(yq -r '.volumes // {} | length' "$f")" = 0 ] || err "bind-mount: still renders a top-level volumes block"
  else
    [ "$(yq -r '.volumes | length' "$f")" = "$n_vols" ] || err "the top-level volumes block does not declare exactly the mounted volumes"
  fi
fi

# --- proxy ------------------------------------------------------------------------
cfg="$(yq -r '.services."postgres-patroni-proxy".environment.HAPROXY_CFG' "$f")"
section() {  # the lines of one `listen <name>` block
  printf '%s\n' "$cfg" | awk -v want="listen $1" '/^[a-z]/ { inside = ($0 == want) } inside'
}
for l in primary replicas; do
  sec="$(section "$l")"
  [ -n "$sec" ] || { err "proxy: no 'listen $l' section"; continue; }
  case "$l" in
    primary) uri=/primary port=5432 ;;
    replicas) uri=/replica port=5433 ;;
  esac
  grep -xF "  bind :$port" <<<"$sec" >/dev/null || err "proxy $l: does not bind :$port"
  grep -xF "  option httpchk GET $uri" <<<"$sec" >/dev/null || err "proxy $l: does not check Patroni's $uri"
  servers="$(grep -E '^  server ' <<<"$sec" || true)"
  [ "$(count "$servers")" = "$want_peers" ] || err "proxy $l: $(count "$servers") backends for $want_peers peers"
  k=0
  for s in $peers; do
    k=$((k + 1))
    printf '%s\n' "$servers" | sed -n "${k}p" | grep -Ex "  server $s tasks\.[A-Za-z0-9_.-]+_$s:5432 check port 8008" >/dev/null \
      || err "proxy $l: backend $k is not $s at its tasks.<release>_$s address with the REST API check"
  done
done
# The exact line, not a substring: both options are also named in the comments above it.
ds="$(printf '%s\n' "$cfg" | { grep -E '^  default-server ' || true; })"
grep -Eq '(^| )on-marked-down shutdown-sessions( |$)' <<<"$ds" || err "proxy: connections to a demoted primary would survive a failover"
grep -Eq '(^| )init-addr none( |$)' <<<"$ds" || err "proxy: refuses to start while a peer is not in DNS"
grep -Eq '(^| )resolvers docker( |$)' <<<"$ds" || err "proxy: resolves each peer once at start and never follows a reschedule"
grep -xF '  bind :8405' <<<"$(printf '%s\n' "$cfg" | awk '/^[a-z]/ { inside = ($0 == "frontend health") } inside')" >/dev/null \
  || err "proxy: no health frontend on :8405"
[ "$(yq -r '.services."postgres-patroni-proxy".healthcheck.test | join(" ")' "$f")" = 'CMD bash -c exec 3<>/dev/tcp/127.0.0.1/8405' ] \
  || err "proxy: healthcheck does not probe the health frontend"
pnets="$(yq -r '.services."postgres-patroni-proxy".networks | keys | sort | join(",")' "$f")"
[ "$pnets" = "cluster,postgres-patroni-net" ] || err "proxy: networks are '$pnets', want the client and cluster overlays"
yq -r '.services."postgres-patroni-proxy".networks."postgres-patroni-net".aliases // [] | .[]' "$f" | grep -xF postgres >/dev/null \
  || err "proxy: lost the client alias 'postgres'"
pports="$(yq -r '.services."postgres-patroni-proxy".ports // [] | .[] | (.published | tostring) + ">" + (.target | tostring) + "/" + .mode' "$f" | paste -sd' ' -)"
if [ "$case_name" = published ]; then
  [ "$pports" = "15432>5432/ingress 15433>5433/ingress" ] || err "proxy: publishes '$pports', want 15432>5432 and 15433>5433 through ingress"
else
  [ -z "$pports" ] || err "proxy: publishes '$pports' without exposure.enabled"
fi

exit "$fail"
