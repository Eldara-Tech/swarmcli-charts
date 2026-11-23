#!/usr/bin/env bash
#
# Structural assertions on the RENDERED stack that `docker compose config` cannot make.
# scripts/test-charts.sh runs this per fixture, after the render:
#   $1 = rendered stack file   $2 = fixture case name
#
# What is worth asserting is everything that makes this ONE cluster rather than three
# unrelated brokers, and every item has a plausible template bug that still renders as
# valid compose:
#   * two peers sharing a node.id, a volume, a node label or an alias silently share an
#     identity or a data dir;
#   * a bootstrap list missing a peer, or a peer advertising another's alias, leaves
#     peers or clients unable to find each other;
#   * a second peer allowed to format --standalone creates a second cluster under the
#     same cluster id, and a cluster id that differs between peers stops them joining;
#   * a password in the environment shows in `docker inspect`, and an exporter carrying
#     other labels, or a peer on the metrics overlay, exposes more to Prometheus than the
#     metrics;
#   * the opt-in services (exporter, users one-shot) render where they must not.
# The refusals, rendered from the default fixture, prove the guards fire.
#
# Deliberately free of bash 4 builtins (no mapfile): macOS /bin/bash is 3.2.
set -euo pipefail

f="${1:?usage: render-check.sh <rendered-file> <case>}"
case_name="${2:-}"
fail=0
err() { echo "   RENDER-CHECK FAIL [$case_name]: $*" >&2; fail=1; }
# grep that reads its whole input: `| grep -q` exits at the first match, and under
# pipefail the producer it killed turns that match into a failure (CONTRIBUTING.md).
has() { grep "$@" >/dev/null; }
q() { yq -r "$1" "$f"; }

want=3; [ "$case_name" = five-peers ] && want=5
auth=1; [ "$case_name" = no-auth ] && auth=0
rel="ci"  # scripts/test-charts.sh renders every fixture as release "ci"

all="$(q '.services | keys | .[]')"
peers="$(printf '%s\n' "$all" | { grep -E '^kafka-[0-9]+$' || true; } | sort -t- -k2 -n)"
[ "$(printf '%s\n' "$peers" | grep -c .)" -eq "$want" ] || err "expected $want peer services, rendered: $(echo $peers)"
extra="$(printf '%s\n' "$all" | { grep -vE '^kafka-[0-9]+$' || true; } | tr '\n' ' ')"
case "$case_name" in
  metrics) [ "$extra" = "kafka-exporter kafka-users " ] || err "metrics must add exactly kafka-exporter and kafka-users, got: $extra" ;;
  no-auth) [ -z "$extra" ] || err "auth off must render no users one-shot and no exporter, got: $extra" ;;
  *)       [ "$extra" = "kafka-users " ] || err "expected only the users one-shot beside the peers, got: $extra" ;;
esac

props() { q ".services.\"$1\".command[2]" | sed -n "/<<'PROPS'/,/^PROPS\$/p" | sed '1d;$d'; }
prop() { props "$1" | sed -n "s/^$2=//p"; }
script() { q ".services.\"$1\".command[2]"; }

boots="" ids="" aliases="" vols="" pins="" cids=""
i=0
for s in $peers; do
  i=$((i + 1))
  alias="${rel}-kafka-$i"
  [ "$s" = "kafka-$i" ] || err "peer $i is named $s"
  [ "$(prop "$s" node.id)" = "$i" ] || err "$s: node.id is '$(prop "$s" node.id)', expected $i"
  ids="$ids $(prop "$s" node.id)"
  boots="$boots|$(prop "$s" controller.quorum.bootstrap.servers)"
  [ -z "$(prop "$s" controller.quorum.voters)" ] || err "$s: sets controller.quorum.voters, a STATIC quorum"
  [ "$(prop "$s" controller.quorum.auto.join.enable)" = true ] || err "$s: auto-join is off; a wiped peer would never rejoin the quorum"
  a="$(q ".services.\"$s\".networks.\"kafka-net\".aliases[0]")"
  [ "$a" = "$alias" ] || err "$s: its own alias is '$a', expected $alias"
  aliases="$aliases $a"
  q ".services.\"$s\".networks.\"kafka-net\".aliases[]" | has -x kafka || err "$s: lacks the shared client alias kafka"
  adv="$(prop "$s" advertised.listeners)"
  case "$adv" in "INTERNAL://$alias:9092,CONTROLLER://$alias:9093"*) ;; *) err "$s: advertises '$adv', not its own alias" ;; esac
  [ "$(q ".services.\"$s\".deploy.replicas")" = 1 ] || err "$s: replicas is not 1"
  [ "$(q ".services.\"$s\".deploy.endpoint_mode")" = vip ] || err "$s: endpoint_mode is not vip; dnsrr drops the aliases every peer is addressed by"
  [ "$(q ".services.\"$s\".deploy.update_config.order")" = stop-first ] || err "$s: update order is not stop-first; two tasks would mount one data dir"
  q ".services.\"$s\".deploy.labels[]" | has -x 'com.swarmcli.rollout=sequential' || err "$s: lost com.swarmcli.rollout=sequential; an upgrade would restart every peer at once"
  [ "$(q ".services.\"$s\".healthcheck.test | join(\"|\")")" = 'CMD-SHELL|[ -f /tmp/kafka-waiting ] || nc -z 127.0.0.1 9093' ] \
    || err "$s: the healthcheck is not exactly the controller port or the waiting marker; a client-port check would keep every peer out of DNS on a first install"
  [ -n "$(q ".services.\"$s\".deploy.update_config.monitor // \"\"")" ] || err "$s: no update monitor; peers would restart 5s apart"
  # Formatting: the same cluster id everywhere, --standalone on peer 1 alone, and only
  # on the exact condition that keeps it from forming a second cluster: every other
  # peer ANSWERED empty (a peer that does not answer may hold the data). A peer joins
  # only one that reports formatted AND serves its controller port.
  sc="$(script "$s")"
  cid="$(printf '%s\n' "$sc" | sed -n 's/.*--cluster-id \([^ ]*\) .*/\1/p')"
  printf '%s' "$cid" | has -E '^[A-Za-z0-9_-]{22}$' || err "$s: cluster id '$cid' is not 22 base64url characters"
  cids="$cids $cid"
  # The script's lines without their indentation, which YAML's block scalar shifts.
  scl="$(printf '%s\n' "$sc" | sed 's/^ *//')"
  if [ "$i" -eq 1 ]; then
    printf '%s\n' "$scl" | has -xF "if [ \"\$\$empty\" -eq $((want - 1)) ]; then flag=--standalone; break; fi" \
      || err "peer 1 does not format --standalone exactly when all $((want - 1)) other peers report empty"
    [ "$(printf '%s\n' "$sc" | grep -c 'standalone' || true)" -eq 1 ] || err "peer 1 has more than one way to format --standalone"
  elif printf '%s\n' "$sc" | has 'standalone'; then
    err "$s: can format --standalone; only peer 1 may, or a second cluster forms under the same id"
  fi
  printf '%s\n' "$scl" | has -xF 'empty) empty=$$((empty+1)) ;;' || err "$s: counts something other than an 'empty' answer as an empty peer"
  printf '%s\n' "$scl" | has -xF 'formatted) if nc -z -w 3 "$$p" 9093 2>/dev/null; then serving=$$((serving+1)); fi ;;' \
    || err "$s: counts a formatted peer as serving without its controller port answering"
  printf '%s\n' "$scl" | has -xF 'if [ "$$serving" -gt 0 ]; then flag=--no-initial-controllers; break; fi' || err "$s: cannot join an existing cluster"
  printf '%s\n' "$scl" | has -xF 'rm -f /tmp/kafka-waiting' || err "$s: never clears the waiting marker, so a broken peer would stay healthy"
  # Secrets stay out of the environment.
  env="$(q ".services.\"$s\".environment | keys | join(\" \")")"
  [ "$env" = KAFKA_HEAP_OPTS ] || err "$s: environment is '$env'; only KAFKA_HEAP_OPTS belongs there"
  # Storage and placement.
  v="$(q ".services.\"$s\".volumes // [] | .[]")"
  pin="$(q ".services.\"$s\".deploy.placement.constraints // [] | .[]" | { grep 'node.labels.kafka-' || true; })"
  case "$case_name" in
    ephemeral)
      [ -z "$v" ] || err "$s: ephemeral renders a volume"
      [ "$(q ".services.\"$s\".deploy.placement // \"none\"")" = none ] || err "$s: ephemeral renders a placement block"
      ;;
    unpinned)
      [ "$v" = "kafka-data-$i:/var/lib/kafka/data" ] || err "$s: volume is '$v'"
      [ -z "$pin" ] || err "$s: unpinned still pins to '$pin'"
      ;;
    bind-mount)
      [ "$v" = "/srv/kafka/peer-$i:/var/lib/kafka/data" ] || err "$s: volume is '$v', expected its own host path"
      [ "$pin" = "node.labels.kafka-$i == true" ] || err "$s: pin is '$pin'"
      ;;
    *)
      [ "$v" = "kafka-data-$i:/var/lib/kafka/data" ] || err "$s: volume is '$v', expected kafka-data-$i"
      [ "$pin" = "node.labels.kafka-$i == true" ] || err "$s: pin is '$pin', expected node.labels.kafka-$i == true"
      ;;
  esac
  vols="$vols $v"; pins="$pins $(printf '%s' "$pin" | tr -d ' ')"
  # No peer on the metrics overlay or publishing a port it should not.
  q ".services.\"$s\".networks | keys | .[]" | has -x monitoring && err "$s: a peer joined the monitoring overlay"
  ports="$(q ".services.\"$s\".ports // [] | length")"
  # Auth.
  map="$(prop "$s" listener.security.protocol.map)"
  if [ "$auth" -eq 1 ]; then
    [ "$(printf '%s' "$map" | tr ',' '\n' | grep -vc ':SASL_PLAINTEXT$' || true)" -eq 0 ] || err "$s: a listener is not SASL: $map"
    [ "$(prop "$s" authorizer.class.name)" = org.apache.kafka.metadata.authorizer.StandardAuthorizer ] || err "$s: no authorizer"
    [ "$(prop "$s" super.users)" = User:kafka-internal ] || err "$s: super.users is '$(prop "$s" super.users)', expected only the internal user"
    [ "$(prop "$s" allow.everyone.if.no.acl.found)" = false ] || err "$s: allows everyone when no ACL matches"
    printf '%s\n' "$sc" | has 'cat /run/secrets/kafka_internal_password' || err "$s: does not read the internal password from its secret"
  else
    [ "$(printf '%s' "$map" | tr ',' '\n' | grep -vc ':PLAINTEXT$' || true)" -eq 0 ] || err "$s: auth off but a listener is not PLAINTEXT: $map"
    [ -z "$(prop "$s" authorizer.class.name)" ] || err "$s: auth off still renders an authorizer"
    [ "$(q ".services.\"$s\".secrets // [] | length")" = 0 ] || err "$s: auth off still mounts a secret"
  fi
  # Exposure.
  case "$case_name" in
    published)
      [ "$(q ".services.\"$s\".ports[0].target")/$(q ".services.\"$s\".ports[0].published")/$(q ".services.\"$s\".ports[0].mode")" = "9094/$((19091 + i))/ingress" ] \
        || err "$s: does not publish 9094 as $((19091 + i)) on the ingress mesh"
      case "$adv" in *",EXTERNAL://127.0.0.1:$((19091 + i))") ;; *) err "$s: advertises '$adv', not its published port" ;; esac
      ;;
    traefik)
      [ "$ports" = 0 ] || err "$s: publishes a port in traefik mode"
      q ".services.\"$s\".networks | keys | .[]" | has -x traefik-public || err "$s: is not on the edge's overlay"
      lb="$(q ".services.\"$s\".deploy.labels | join(\" \")")"
      for want_label in 'traefik.enable=true' 'traefik.constraint-label=traefik-public' 'traefik.swarm.network=traefik-public' \
          "traefik.tcp.routers.$alias.rule=HostSNI(\`kafka-$i.e2e.test\`)" "traefik.tcp.routers.$alias.entrypoints=https" \
          "traefik.tcp.routers.$alias.tls=true" "traefik.tcp.services.$alias.loadbalancer.server.port=9094"; do
        printf '%s\n' "$lb" | tr ' ' '\n' | has -xF "$want_label" || err "$s: lacks the label $want_label"
      done
      printf '%s' "$lb" | has certresolver && err "$s: requests a certificate although traefik.certResolver is empty"
      case "$adv" in *",EXTERNAL://kafka-$i.e2e.test:443") ;; *) err "$s: advertises '$adv', not its edge host" ;; esac
      ;;
    *)
      [ "$ports" = 0 ] || err "$s: publishes a port without exposure"
      case "$adv" in *EXTERNAL*) err "$s: advertises an EXTERNAL listener without exposure" ;; esac
      ;;
  esac
  # Extra broker settings land after the chart's own.
  if [ "$case_name" = internal-net ]; then
    for kv in log.retention.hours=72 num.partitions=3 log.retention.bytes=1073741824; do
      props "$s" | has -x "$kv" || err "$s: config did not render '$kv' into server.properties"
    done
  fi
done

distinct() { [ "$(printf '%s\n' $1 | sort -u | grep -c .)" -eq "$(printf '%s\n' $1 | grep -c .)" ]; }
distinct "$ids" || err "two peers share a node.id:$ids"
distinct "$aliases" || err "two peers share an alias:$aliases"
[ "$case_name" = ephemeral ] || distinct "$vols" || err "two peers share a volume:$vols"
[ -z "$(echo $pins)" ] || distinct "$pins" || err "two peers share a node pin"
[ "$(printf '%s\n' $cids | sort -u | grep -c .)" -eq 1 ] || err "the peers format with different cluster ids:$cids"
[ "$(printf '%s\n' "${boots#|}" | tr '|' '\n' | sort -u | grep -c .)" -eq 1 ] || err "the peers bootstrap the quorum from different lists"
b="$(printf '%s' "${boots#|}" | cut -d'|' -f1 | tr ',' '\n')"
for i in $(seq 1 "$want"); do
  [ "$(printf '%s\n' "$b" | grep -cx "${rel}-kafka-$i:9093")" -eq 1 ] || err "the bootstrap list does not name peer $i exactly once"
done
[ "$(printf '%s\n' "$b" | grep -c .)" -eq "$want" ] || err "the bootstrap list names $(printf '%s\n' "$b" | grep -c .) controllers for $want peers"

# The users one-shot: on the cluster overlay only, run to completion, every password from
# a secret file.
if [ "$auth" -eq 1 ]; then
  u=.services.\"kafka-users\"
  [ "$(q "$u.deploy.restart_policy.condition")" = on-failure ] || err "the users one-shot does not run to completion (restart_policy on-failure)"
  [ "$(q "$u.networks | join(\" \")")" = kafka-net ] || err "the users one-shot is not on kafka-net alone"
  us="$(q "$u.command[2]")"
  printf '%s\n' "$us" | has -x 'scram app kafka_app_password' || err "the users one-shot does not create the app user from its secret"
  printf '%s\n' "$us" | has -- '--add-config-file' || err "the users one-shot passes a password on a command line"
  if [ "$case_name" = metrics ]; then
    printf '%s\n' "$us" | has "User:exporter' --operation Describe --topic '\*' --group '\*' --cluster\$" || err "the exporter's user is not limited to Describe"
  else
    printf '%s\n' "$us" | has 'exporter' && err "the users one-shot creates the exporter's user without metrics"
  fi
  [ "$(q '.secrets | keys | join(" ")')" = "$( [ "$case_name" = metrics ] && echo 'kafka_app_password kafka_exporter_password kafka_internal_password' || echo 'kafka_app_password kafka_internal_password')" ] \
    || err "unexpected secrets: $(q '.secrets | keys | join(" ")')"
else
  [ "$(q '.secrets // {} | length')" = 0 ] || err "auth off still declares secrets"
fi

# The exporter: the two discovery labels and nothing else, on exactly the cluster and
# metrics overlays.
if [ "$case_name" = metrics ]; then
  m=.services.\"kafka-exporter\"
  [ "$(q "$m.deploy.labels | join(\" \")")" = "prometheus.io/scrape=true prometheus.io/port=9308" ] \
    || err "exporter deploy labels are '$(q "$m.deploy.labels | join(\" \")")', expected exactly the two discovery labels"
  [ "$(q "$m.networks | join(\" \")")" = "kafka-net monitoring" ] || err "the exporter is not on exactly kafka-net and monitoring"
  mc="$(q "$m.command[0]")"
  printf '%s' "$mc" | has 'SASL_USER_PASSWORD="$$(cat /run/secrets/kafka_exporter_password)"' || err "the exporter does not read its password from its secret"
  printf '%s' "$mc" | has -E -- '--kafka.version=[0-9]+\.[0-9]+\.[0-9]+( |$)' || err "the exporter is not told the Kafka version"
  for i in 1 2 3; do printf '%s' "$mc" | has -F -- "--kafka.server=${rel}-kafka-$i:9092" || err "the exporter does not bootstrap from peer $i"; done
  [ "$(q "$m.environment // {} | length")" = 0 ] || err "the exporter carries an environment; its password belongs in the secret"
fi

# ── refusals and one-off renders (from the default fixture only) ──────────────────────
if [ "$case_name" = default ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.err" "$tmp.values"' EXIT
  render() { "${SWARMCLI:?render-check needs SWARMCLI to render the refusals}" charts template "$@" >"$tmp" 2>"$tmp.err"; }
  refused() {
    local want_msg="$1"; shift
    if render ci "$chart" "$@"; then
      err "rendered with $* — it must be refused"
    elif ! grep -F -- "$want_msg" "$tmp.err" >/dev/null; then
      err "$* failed, but not with \"$want_msg\": $(tr '\n' ' ' <"$tmp.err")"
    fi
  }
  refused 'exposure.mode: published needs auth.enabled' --set exposure.mode=published --set publish.host=h --set auth.enabled=false
  refused 'exposure.mode: published needs publish.host' --set exposure.mode=published
  refused 'leaves no room for 3 brokers' --set exposure.mode=published --set publish.host=h --set publish.basePort=65534
  refused 'needs one host name per peer' --set exposure.mode=traefik --set 'traefik.hosts={a.example,b.example}'
  refused 'lists a host name twice' --set exposure.mode=traefik --set 'traefik.hosts={a.example,b.example,a.example}'
  refused 'persistence.volumePaths has 2 entries' --set 'persistence.volumePaths={/a,/b}'
  refused 'cannot contain' --set persistence.volumePrefix=a/b
  refused 'network.encrypted only applies' --set network.encrypted=true
  refused 'metrics.network must differ' --set metrics.enabled=true --set metrics.network=kafka-net
  refused 'config.listeners is set by the chart' --set config.listeners=PLAINTEXT://:9999
  # --set cannot spell a key with dots in it, so these come from a values file.
  printf 'config:\n  listener.name.internal.x: y\n' >"$tmp.values"
  refused 'config.listener.name.internal.x is set by the chart' -f "$tmp.values"
  printf 'config:\n  ssl.keystore.password: x\n' >"$tmp.values"
  refused 'config.ssl.keystore.password looks like a credential' -f "$tmp.values"
  refused 'names a user twice' --set 'auth.users[0].name=a' --set 'auth.users[0].secretName=s1' --set 'auth.users[1].name=a' --set 'auth.users[1].secretName=s2'
  refused 'must not name "kafka-internal"' --set 'auth.users[0].name=kafka-internal' --set 'auth.users[0].secretName=s1'
  refused 'metrics.username "app"' --set metrics.enabled=true --set metrics.username=app
  refused 'does not start with one' --set metrics.enabled=true --set image.tag=latest-ish
  refused 'needs 4.2 or later' --set image.tag=4.1.2
  refused 'exposure.network must differ' --set exposure.mode=traefik --set 'traefik.hosts={a.example,b.example,c.example}' --set exposure.network=kafka-net
  # The update monitor is the gap between two peers' restarts, healthcheck or not.
  if render ci "$chart" --set healthcheck.enabled=false; then
    [ "$(yq -r '.services."kafka-2".deploy.update_config.monitor // ""' "$tmp")" = 120s ] || err "with the healthcheck off, the update monitor is gone"
  else
    err "healthcheck.enabled=false was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  # A release name with `_` and `.`: the aliases a host name can carry.
  if render my_kafka.x "$chart"; then
    [ "$(yq -r '.services."kafka-1".networks."kafka-net".aliases[0]' "$tmp")" = my-kafka-x-kafka-1 ] \
      || err "release my_kafka.x does not get the alias my-kafka-x-kafka-1: '_' and '.' must become '-'"
    other="$(yq -r '.services."kafka-1".command[2]' "$tmp" | sed -n 's/.*--cluster-id \([^ ]*\) .*/\1/p')"
    [ "$other" != "$(printf '%s' "$cids" | awk '{print $1}')" ] || err "two releases format with the same cluster id"
  else
    err "release my_kafka.x was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  # Stable across renders of the same release: an upgrade must not change it.
  render ci "$chart" && [ "$(yq -r '.services."kafka-1".command[2]' "$tmp" | sed -n 's/.*--cluster-id \([^ ]*\) .*/\1/p')" = "$(printf '%s' "$cids" | awk '{print $1}')" ] \
    || err "the cluster id changes between renders of one release"
fi

exit "$fail"
