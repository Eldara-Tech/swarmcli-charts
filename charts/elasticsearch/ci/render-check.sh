#!/usr/bin/env bash
#
# Structural assertions on the RENDERED stack that `docker compose config` cannot make.
# scripts/test-charts.sh runs this per fixture, after the render:
#   $1 = rendered stack file   $2 = fixture case name
#
# Every one of these has a plausible template bug that still renders as valid compose:
#   * a node reusing another node's volume, node label or node.name silently gives two nodes one
#     identity or one data dir;
#   * a seed list or initial master list missing a node leaves it unable to find, or vote in,
#     the cluster — and a single-node render carrying an initial master list fails to start;
#   * the elastic password mounted 0444, which the image's ELASTIC_PASSWORD_FILE refuses, or the
#     TLS files mounted outside the config directory, which Elasticsearch refuses to read;
#   * a secret in Kibana's environment, which kibana-docker turns into a visible argv flag;
#   * Kibana dialing a Swarm service name: `<release>_<svc>` has an underscore, which
#     Elasticsearch's TLS refuses as a server name, so it works over http and fails over https;
#   * a cluster node without the sequential-rollout label, so an upgrade stops every node at once;
#   * an ingress-mode port on a cluster, accepted by compose and refused by the daemon.
#
# Deliberately free of bash 4 builtins (no mapfile): macOS /bin/bash is 3.2.
set -euo pipefail

f="${1:?usage: render-check.sh <rendered-file> <case>}"
case_name="${2:-}"
release="${RELEASE:-ci}"
fail=0
err() { echo "   RENDER-CHECK FAIL [$case_name]: $*" >&2; fail=1; }
count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

want=1
case "$case_name" in
  cluster|cluster-transport-tls|unpinned) want=3 ;;
  five-nodes) want=5 ;;
esac
kibana=1
[ "$case_name" = "kibana-disabled" ] && kibana=0
persist=1
[ "$case_name" = "ephemeral" ] && persist=0
pinned=$persist
[ "$case_name" = "unpinned" ] && pinned=0

all="$(yq -r '.services | keys | .[]' "$f")"
nodes="$(printf '%s\n' "$all" | { grep -E '^elasticsearch-[0-9]+$' || true; })"
[ "$(count "$nodes")" -eq "$want" ] || err "expected $want node services, rendered: $(echo "$nodes" | tr '\n' ' ')"

if [ "$kibana" = 1 ]; then
  grep -qx kibana <<<"$all" || err "no kibana service"
  grep -qx kibana-setup <<<"$all" || err "no kibana-setup service"
elif grep -qE '^kibana' <<<"$all"; then
  err "kibana services are rendered with kibana.enabled false"
fi

seen_vol=""; seen_label=""; i=0
for s in $nodes; do
  i=$((i + 1))
  [ "$s" = "elasticsearch-$i" ] || err "node $i is named $s (yq sorts keys; the numbering has a gap)"
  q=".services.\"$s\""
  [ "$(yq -r "$q.deploy.replicas" "$f")" = "1" ] || err "$s: replicas is not 1 — two tasks would share one data dir"
  [ "$(yq -r "$q.deploy.endpoint_mode" "$f")" = "vip" ] || err "$s: endpoint_mode is not vip — dnsrr drops the client alias"
  [ "$(yq -r "$q.environment.\"node.name\"" "$f")" = "$s" ] || err "$s: node.name is not $s"
  [ "$(yq -r "$q.hostname" "$f")" = "$s" ] || err "$s: hostname is not $s (the wrapper reads its address for it from /etc/hosts)"
  # Its own underscore-free alias, the name Kibana and the setup job dial over TLS.
  grep -qxF "${release}-$s" <<<"$(yq -r "$q.networks[].aliases // [] | .[]" "$f")" \
    || err "$s: lacks its network alias ${release}-$s"

  # The elastic password: root:root 0440 (288), or ELASTIC_PASSWORD_FILE refuses to start.
  pw="$(yq -r "$q.environment.ELASTIC_PASSWORD_FILE" "$f")"
  [ "$(yq -r "$q.secrets[] | select(\"/run/secrets/\" + .target == \"$pw\") | .mode" "$f")" = "288" ] \
    || err "$s: the secret behind ELASTIC_PASSWORD_FILE ($pw) is not mounted 0440"
  # TLS files only from inside the config directory.
  for k in $(yq -r "$q.environment | keys | .[] | select(test(\"^xpack.security.*ssl.(key|certificate|certificate_authorities)$\"))" "$f"); do
    p="$(yq -r "$q.environment.\"$k\"" "$f")"
    case "$p" in /usr/share/elasticsearch/config/*) ;; *) err "$s: $k=$p is outside the config directory, which Elasticsearch refuses to read" ;; esac
    [ "$(yq -r "$q.secrets[] | select(.target == \"$p\") | .target" "$f")" = "$p" ] || err "$s: $k=$p is not a mounted secret"
  done

  if [ "$persist" = 1 ]; then
    vol="$(yq -r "$q.volumes[0]" "$f" | cut -d: -f1)"
    case " $seen_vol " in *" $vol "*) err "$s: volume $vol is shared with another node" ;; esac
    seen_vol="$seen_vol $vol"
  elif [ "$(yq -r "$q.volumes // [] | length" "$f")" != "0" ]; then
    err "$s: persistence is off but a volume is mounted"
  fi
  label="$(yq -r "$q.deploy.placement.constraints // [] | .[] | select(test(\"^node.labels.\"))" "$f")"
  if [ "$pinned" = 1 ]; then
    [ "$label" = "node.labels.elasticsearch-data-$i == true" ] || err "$s: pin is '$label', expected its own label elasticsearch-data-$i"
    case " $seen_label " in *" $label "*) err "$s: shares its node label with another node" ;; esac
    seen_label="$seen_label $label"
  elif [ -n "$label" ]; then
    err "$s: pinned ($label) although this fixture renders no pin"
  fi
  if [ "$case_name" = "unpinned" ]; then
    grep -qx 'node.role == worker' <<<"$(yq -r "$q.deploy.placement.constraints[]" "$f")" || err "$s: lost placement.constraints"
  fi

  if [ "$want" -gt 1 ]; then
    seeds="$(yq -r "$q.environment.\"discovery.seed_hosts\"" "$f")"
    cmd="$(yq -r "$q.command[2]" "$f")"
    masters="$(sed -n 's/.*cluster.initial_master_nodes=\([^"]*\)".*/\1/p' <<<"$cmd")"
    j=0; want_seeds=""; want_masters=""
    while [ "$j" -lt "$want" ]; do
      j=$((j + 1))
      want_seeds="$want_seeds${want_seeds:+,}tasks.${release}_elasticsearch-$j"
      want_masters="$want_masters${want_masters:+,}elasticsearch-$j"
    done
    [ "$seeds" = "$want_seeds" ] || err "$s: discovery.seed_hosts is '$seeds', expected '$want_seeds'"
    [ "$masters" = "$want_masters" ] || err "$s: initial master list is '$masters', expected '$want_masters'"
    grep -qF 'network.publish_host=$$SELF_ADDR' <<<"$cmd" || err "$s: does not advertise the address it read from /etc/hosts"
    [ "$(yq -r "$q.environment.\"discovery.type\" // \"\"" "$f")" = "" ] || err "$s: a cluster node runs discovery.type single-node"
    [ "$(yq -r "$q.environment.\"xpack.security.transport.ssl.enabled\"" "$f")" = "true" ] || err "$s: a cluster node without transport TLS"
    grep -qxF 'com.swarmcli.rollout=sequential' <<<"$(yq -r "$q.deploy.labels // [] | .[]" "$f")" \
      || err "$s: lost com.swarmcli.rollout=sequential; an upgrade would restart every node at once"
    for m in $(yq -r "$q.ports // [] | .[].mode" "$f"); do
      [ "$m" = "host" ] || err "$s: a cluster node publishes in $m mode; several services cannot share an ingress port"
    done
  else
    [ "$(yq -r "$q.environment.\"discovery.type\"" "$f")" = "single-node" ] || err "$s: one node without discovery.type single-node"
    if grep -q 'initial_master_nodes' <<<"$(yq -r "$q | tojson" "$f")"; then
      err "$s: a single-node render sets cluster.initial_master_nodes, which single-node discovery refuses"
    fi
  fi
done

if [ "$kibana" = 1 ]; then
  # Kibana's secrets go through its keystore, never its environment: kibana-docker turns every
  # known variable into a --flag, readable in the process list.
  envkeys="$(yq -r '.services.kibana.environment | keys | .[]' "$f")"
  if grep -qiE 'PASSWORD|ENCRYPTIONKEY$' <<<"$envkeys"; then
    err "kibana carries a secret in its environment: $(grep -iE 'PASSWORD|ENCRYPTIONKEY$' <<<"$envkeys" | tr '\n' ' ')"
  fi
  for k in elasticsearch.password xpack.encryptedSavedObjects.encryptionKey; do
    if [ "$case_name" = "settings" ] && [ "$k" != elasticsearch.password ]; then continue; fi
    grep -qF -- "$k" <<<"$(yq -r '.services.kibana.command[2]' "$f")" || err "kibana does not load $k into its keystore"
  done
  # One Kibana host per node, by its stack-qualified service name.
  hosts="$(yq -r '.services.kibana.environment.ELASTICSEARCH_HOSTS' "$f")"
  [ "$(yq -r '.services.kibana.environment.ELASTICSEARCH_HOSTS | from_json | length' "$f")" = "$want" ] \
    || err "ELASTICSEARCH_HOSTS has not one entry per node: $hosts"
  # Never a Swarm service name: its underscore is not a legal host name, and Elasticsearch's TLS
  # refuses it as the SNI server name, so over https every request would fail.
  for h in $(yq -r '.services.kibana.environment.ELASTICSEARCH_HOSTS | from_json | .[]' "$f") \
           $(yq -r '.services."kibana-setup".environment.ES_HOSTS' "$f"); do
    case "$h" in
      *_*) err "Kibana or kibana-setup dials $h, a name with an underscore, which TLS refuses" ;;
      *://"${release}"-elasticsearch-[0-9]*:9200) ;;
      *) err "Kibana or kibana-setup dials $h, not a node alias" ;;
    esac
  done
  # The setup job tries the same hosts Kibana uses.
  [ "$(yq -r '.services."kibana-setup".environment.ES_HOSTS' "$f" | tr ' ' '\n' | wc -l | tr -d ' ')" = "$want" ] \
    || err "kibana-setup does not try every node"
  [ "$(yq -r '.services."kibana-setup".deploy.restart_policy.condition' "$f")" = "on-failure" ] \
    || err "kibana-setup is not a one-shot (restart_policy on-failure)"
  # Routed only in traefik mode, and with the constraint label the traefik chart filters on.
  labels="$(yq -r '.services.kibana.deploy.labels // [] | .[]' "$f")"
  mode=traefik
  case "$case_name" in cluster|cluster-transport-tls|tls|settings) mode=none ;; published) mode=published ;; esac
  if [ "$mode" = traefik ]; then
    grep -qxF 'traefik.constraint-label=traefik-public' <<<"$labels" || err "kibana lacks traefik.constraint-label"
    grep -qxF 'traefik.swarm.network=traefik-public' <<<"$labels" || err "kibana lacks traefik.swarm.network"
    if [ "$case_name" = "edge" ]; then
      grep -q 'middlewares=' <<<"$labels" && err "tls:false still renders the https-redirect middleware"
      [ "$(yq -r '.services.kibana.environment.XPACK_SECURITY_SECURECOOKIES // ""' "$f")" = "" ] \
        || err "a plain-HTTP public URL still marks Kibana's cookie Secure"
    fi
  elif grep -q '^traefik\.' <<<"$labels"; then
    err "kibana carries Traefik labels in $mode mode"
  fi
fi

# Nothing is published unless the fixture asks for it.
if [ "$case_name" != "published" ]; then
  [ "$(yq -r '[.services[].ports // [] | .[]] | length' "$f")" = "0" ] || err "a port is published by default"
fi

exit "$fail"
