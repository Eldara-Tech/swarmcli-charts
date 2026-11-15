#!/usr/bin/env bash
#
# e2e smoke check for the kafka chart. scripts/e2e-test.sh runs this once the release
# has converged:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
#
# Convergence proves little for a cluster: peers that each formed a quorum of their own
# would all report healthy. So this asserts the cluster itself, from inside the peers:
#   - the quorum has a leader and one voter per peer, with distinct directory ids;
#   - a topic with 3 replicas takes an acks=all write through the shared client alias on
#     one peer and reads back through another;
#   - with auth on: the users one-shot finished, and a wrong password is refused;
# and per fixture:
#   metrics    the exporter answers on the monitoring overlay with the cluster's brokers,
#              the topic and the consumer group's lag; its user may Describe and nothing
#              else; the alert rules pass promtool;
#   published  a client outside the overlay writes and reads through the routing-mesh
#              ports each broker advertises;
#   traefik    a client writes and reads over TLS through the traefik edge, routed to each
#              broker by SNI;
#   lifecycle  a peer whose volume is wiped rejoins as a NEW voter and gets its replicas
#              back; the cluster survives a full stop; an upgrade rolls every peer; raising
#              cluster.peers to 5 adds two voters.
#
# Portable to /bin/bash 3.2 (CONTRIBUTING.md § Portability).
set -euo pipefail

rel="$1"; chart="$(cd "$2" && pwd)"; case_="$3"
repo="$(cd "$chart/../.." && pwd)"
fail() { echo "  $*"; exit 1; }
# grep that reads its whole input: `| grep -q` exits at the first match, and under
# pipefail the producer it killed turns that match into a failure (CONTRIBUTING.md).
has() { grep "$@" >/dev/null; }

peers="$(docker stack services "$rel" --format '{{.Name}}' | grep -c -E "^${rel}_kafka-[0-9]+\$" || true)"
[ "$peers" -ge 3 ] || fail "expected at least 3 peer services, found $peers"
auth=1; [ "$case_" = no-auth ] && auth=0
image="$(docker service inspect "${rel}_kafka-1" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed 's/@.*//')"
alias_of() { printf '%s-kafka-%s' "$(printf '%s' "$rel" | tr '_.' '--')" "$1"; }
ctr() { docker ps -q --filter "label=com.docker.swarm.service.name=${rel}_kafka-$1" | sed -n 1p; }
# Client configs, written into a peer's container: the app user, and the same user with
# a wrong password.
props() {  # $1 = password
  if [ "$auth" -eq 1 ]; then
    printf 'security.protocol=SASL_PLAINTEXT\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app" password="%s";\n' "$1"
  fi
}
seed() {  # $1 = peer: write the client configs into its container
  local c; c="$(ctr "$1")"; [ -n "$c" ] || fail "no running container for peer $1"
  props 'app/pass+word==' | docker exec -i "$c" sh -c 'cat > /tmp/e2e-client.properties'
  props 'not-the-password' | docker exec -i "$c" sh -c 'cat > /tmp/e2e-wrong.properties'
}
# kx <peer> <shell>: run a shell line inside a peer, with a small heap for the tools.
kx() { docker exec -e KAFKA_HEAP_OPTS=-Xmx256m "$(ctr "$1")" bash -c "$2"; }
T=/opt/kafka/bin
C="--command-config /tmp/e2e-client.properties"
boot="$(alias_of 1):9092"

# Wait for <seconds> until <shell> succeeds on the host.
waitfor() {
  local t="$1"; shift
  local end=$(( $(date +%s) + t ))
  while ! eval "$*" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep 5
  done
}

# quorum_ok: a leader, one voter per peer, distinct directory ids. Prints the status.
quorum() { kx 1 "$T/kafka-metadata-quorum.sh --bootstrap-server $boot $C describe --status 2>/dev/null"; }
quorum_ok() {
  local s voters ids
  s="$(quorum)" || return 1
  printf '%s\n' "$s" | has -E '^LeaderId: +[1-9]' || return 1
  voters="$(printf '%s\n' "$s" | sed -n 's/^CurrentVoters: *//p')"
  [ "$(printf '%s' "$voters" | grep -oE '"id": [0-9]+' | sort -u | wc -l | tr -d ' ')" -eq "$peers" ] || return 1
  ids="$(printf '%s' "$voters" | grep -oE '"directoryId": "[^"]+"' | sort -u | wc -l | tr -d ' ')"
  [ "$ids" -eq "$peers" ]
}
voter_dir() {  # $1 = node id: the directory id the quorum holds for it
  quorum | sed -n 's/^CurrentVoters: *//p' | grep -oE "\"id\": $1, \"directoryId\": \"[^\"]+\"" | sed 's/.*: "//; s/"$//'
}

for i in $(seq 1 "$peers"); do seed "$i"; done

if [ "$auth" -eq 1 ]; then
  waitfor 300 "docker service ps '${rel}_kafka-users' --format '{{.CurrentState}}' | has '^Complete'" \
    || { docker service logs --tail 60 "${rel}_kafka-users" 2>&1 | sed 's/^/    /'; fail "the users one-shot did not complete"; }
fi

waitfor 300 quorum_ok || { quorum | sed 's/^/    /' || true; fail "the quorum never had a leader and $peers voters with distinct directory ids"; }
leader="$(quorum | sed -n 's/^LeaderId: *//p')"

# A write that needs two replicas in sync, through the shared alias, read back from the
# last peer.
kx 1 "$T/kafka-topics.sh --bootstrap-server kafka:9092 $C --create --if-not-exists --topic e2e-check --partitions 3 --replication-factor 3" >/dev/null
kx 1 "seq 1 30 | $T/kafka-console-producer.sh --bootstrap-server kafka:9092 $C --topic e2e-check --command-property acks=all" >/dev/null
n="$(kx "$peers" "$T/kafka-console-consumer.sh --bootstrap-server $(alias_of "$peers"):9092 $C --topic e2e-check --group e2e-check --from-beginning --max-messages 30 --timeout-ms 60000 2>/dev/null | wc -l" | tr -d ' ')"
[ "$n" -eq 30 ] || fail "read $n of 30 records back from peer $peers"
isr="$(kx 1 "$T/kafka-topics.sh --bootstrap-server $boot $C --describe --topic e2e-check" | grep -c "Isr: [0-9],[0-9],[0-9]" || true)"
[ "$isr" -eq 3 ] || fail "expected 3 partitions with 3 in-sync replicas, found $isr"

if [ "$auth" -eq 1 ]; then
  out="$(kx 1 "timeout 60 $T/kafka-topics.sh --bootstrap-server $boot --command-config /tmp/e2e-wrong.properties --list 2>&1" || true)"
  printf '%s' "$out" | has 'SaslAuthenticationException' || { printf '%s\n' "$out" | tail -5 | sed 's/^/    /'; fail "a wrong password was not refused"; }
fi
summary="quorum of $peers voters (leader $leader), 30 acks=all records across peers"

case "$case_" in
metrics)
  # Where Prometheus scrapes it: the exporter's service name on the monitoring overlay.
  m=""
  for _ in $(seq 1 40); do
    m="$(docker run --rm --network monitoring curlimages/curl:latest -sSf "http://${rel}_kafka-exporter:9308/metrics" 2>/dev/null || true)"
    if printf '%s\n' "$m" | has '^kafka_consumergroup_lag_sum{consumergroup="e2e-check"'; then break; fi
    sleep 5
  done
  printf '%s\n' "$m" | has -x "kafka_brokers $peers" || { docker service logs --tail 30 "${rel}_kafka-exporter" 2>&1 | sed 's/^/    /'; fail "the exporter does not report $peers brokers on the monitoring overlay"; }
  printf '%s\n' "$m" | has -x 'kafka_topic_partitions{topic="e2e-check"} 3' || fail "the exporter does not report the e2e-check topic"
  printf '%s\n' "$m" | has '^kafka_consumergroup_lag_sum{consumergroup="e2e-check"' || fail "the exporter reports no lag for the e2e-check group"
  # KafkaPartitionsOffline reads a partition whose replicas are reported without an offset
  # as offline, so on a healthy cluster, under the exporter user's Describe-only ACLs, every
  # partition must have both.
  nrep="$(printf '%s\n' "$m" | grep -c '^kafka_topic_partition_replicas{' || true)"
  noff="$(printf '%s\n' "$m" | grep -c '^kafka_topic_partition_current_offset{' || true)"
  [ "$nrep" -gt 0 ] && [ "$nrep" -eq "$noff" ] || fail "the exporter reports $nrep partitions but offsets for $noff; KafkaPartitionsOffline would fire on a healthy cluster"
  # The exporter's user may Describe and nothing else.
  printf 'security.protocol=SASL_PLAINTEXT\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="exporter" password="exporter-pw";\n' \
    | docker exec -i "$(ctr 1)" sh -c 'cat > /tmp/e2e-exporter.properties'
  out="$(kx 1 "timeout 60 $T/kafka-topics.sh --bootstrap-server $boot --command-config /tmp/e2e-exporter.properties --create --topic e2e-denied --partitions 1 --replication-factor 1 2>&1" || true)"
  printf '%s' "$out" | has 'AuthorizationException' || { printf '%s\n' "$out" | tail -5 | sed 's/^/    /'; fail "the exporter's user was allowed to create a topic"; }
  # The alert rules the chart ships for operators to load (monitoring/), checked here
  # because nothing deploys them: their logic, under the promtool of the Prometheus the
  # prometheus-stack chart pins.
  prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$repo/charts/prometheus-stack/Chart.yaml")"
  if ! out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}" \
      test rules /chart/ci/kafka-rules-test.yml 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/    /'
    fail "promtool test rules fails on monitoring/kafka-rules.yml"
  fi
  summary="$summary, exporter scraped on monitoring with Describe-only access, alert rules pass promtool"
  ;;
published)
  # Outside the overlay: the node's own network, through the port each broker publishes.
  # The fixture's publish.host is 127.0.0.1, so what the brokers advertise is reachable
  # from here.
  out="$(props 'app/pass+word==' | docker run --rm -i --network host -e KAFKA_HEAP_OPTS=-Xmx256m --entrypoint bash "$image" -c "
    cat > /tmp/c.properties
    seq 1 20 | $T/kafka-console-producer.sh --bootstrap-server 127.0.0.1:19092 --command-config /tmp/c.properties --topic e2e-published --command-property acks=all >/dev/null 2>&1
    $T/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:19093 --command-config /tmp/c.properties --topic e2e-published --from-beginning --max-messages 20 --timeout-ms 60000 2>/dev/null | wc -l" || true)"
  [ "$(printf '%s' "$out" | tr -d ' ')" = 20 ] || fail "read ${out:-nothing} of 20 records through the published ports"
  summary="$summary, 20 records through the published per-broker ports"
  ;;
traefik)
  # Through the edge: TLS to Traefik's default certificate on :443, SNI selecting the
  # broker. The client resolves every broker host to the edge, as public DNS would.
  hosts=""
  for i in $(seq 1 "$peers"); do hosts="$hosts kafka-$i.e2e.test"; done
  out="$(props 'app/pass+word==' | sed 's/SASL_PLAINTEXT/SASL_SSL/' | docker run --rm -i --user 0 --network traefik-public -e KAFKA_HEAP_OPTS=-Xmx256m --entrypoint bash "$image" -c "
    set -e
    cat > /tmp/c.properties
    ip=\$(getent hosts e2e-edge_traefik | cut -d' ' -f1)
    for h in $hosts; do echo \"\$ip \$h\" >> /etc/hosts; done
    keytool -printcert -sslserver kafka-1.e2e.test:443 -rfc > /tmp/edge.pem 2>/dev/null
    keytool -importcert -noprompt -alias edge -file /tmp/edge.pem -keystore /tmp/ts.p12 -storetype PKCS12 -storepass changeit >/dev/null 2>&1
    printf 'ssl.truststore.location=/tmp/ts.p12\nssl.truststore.type=PKCS12\nssl.truststore.password=changeit\nssl.endpoint.identification.algorithm=\n' >> /tmp/c.properties
    seq 1 20 | $T/kafka-console-producer.sh --bootstrap-server kafka-1.e2e.test:443 --command-config /tmp/c.properties --topic e2e-edge --command-property acks=all >/dev/null 2>&1
    $T/kafka-console-consumer.sh --bootstrap-server kafka-$peers.e2e.test:443 --command-config /tmp/c.properties --topic e2e-edge --from-beginning --max-messages 20 --timeout-ms 60000 2>/dev/null | wc -l" || true)"
  [ "$(printf '%s' "$out" | tr -d ' ')" = 20 ] || fail "read ${out:-nothing} of 20 records over TLS through the traefik edge"
  summary="$summary, 20 records over TLS through the traefik edge"
  ;;
lifecycle)
  # 1. Wipe peer 2's volume. It must come back as a NEW voter (a new directory id) rather
  #    than as the old one with an empty log, and get its replicas back.
  old="$(voter_dir 2)"
  docker service scale -d "${rel}_kafka-2=0" >/dev/null
  waitfor 120 "[ -z \"\$(docker ps -aq --filter label=com.docker.swarm.service.name=${rel}_kafka-2)\" ]" || fail "peer 2 did not stop"
  vol="${rel}_kafka-data-2"
  waitfor 60 "docker volume rm '$vol'" || fail "could not remove $vol"
  docker service scale -d "${rel}_kafka-2=1" >/dev/null
  waitfor 300 "[ -n \"\$(docker ps -q --filter label=com.docker.swarm.service.name=${rel}_kafka-2)\" ]" || fail "peer 2 did not restart"
  seed 2
  waitfor 300 "quorum_ok && [ -n \"\$(voter_dir 2)\" ] && [ \"\$(voter_dir 2)\" != '$old' ]" \
    || { quorum | sed 's/^/    /' || true; fail "the wiped peer 2 did not rejoin as a new voter (old directory id $old)"; }
  waitfor 300 "[ \"\$(kx 1 '$T/kafka-topics.sh --bootstrap-server $boot $C --describe --topic e2e-check' | grep -c 'Isr: [0-9],[0-9],[0-9]')\" -eq 3 ]" \
    || fail "the wiped peer 2 did not get its replicas back in sync"
  n="$(kx 2 "$T/kafka-console-consumer.sh --bootstrap-server $(alias_of 2):9092 $C --topic e2e-check --from-beginning --max-messages 30 --timeout-ms 60000 2>/dev/null | wc -l" | tr -d ' ')"
  [ "$n" -eq 30 ] || fail "read $n of 30 records through the rebuilt peer 2"

  # 2. A full stop: every peer down at once, then up again, on their volumes.
  for i in $(seq 1 "$peers"); do docker service scale -d "${rel}_kafka-$i=0" >/dev/null; done
  waitfor 180 "[ -z \"\$(docker ps -q --filter label=com.docker.stack.namespace=$rel --filter name=${rel}_kafka-)\" ]" || fail "the peers did not stop"
  for i in $(seq 1 "$peers"); do docker service scale -d "${rel}_kafka-$i=1" >/dev/null; done
  for i in $(seq 1 "$peers"); do
    waitfor 300 "[ -n \"\$(docker ps -q --filter label=com.docker.swarm.service.name=${rel}_kafka-$i)\" ]" || fail "peer $i did not restart after the full stop"
    seed "$i"
  done
  waitfor 300 quorum_ok || { quorum | sed 's/^/    /' || true; fail "the quorum did not come back after a full stop"; }
  n="$(kx 1 "$T/kafka-console-consumer.sh --bootstrap-server $boot $C --topic e2e-check --from-beginning --max-messages 30 --timeout-ms 60000 2>/dev/null | wc -l" | tr -d ' ')"
  [ "$n" -eq 30 ] || fail "read $n of 30 records after the full stop"

  # 3. An upgrade that changes every peer's spec rolls them one at a time and ends with
  #    the same cluster.
  sc="${SWARMCLI:-$repo/.swarmcli-bin/swarmcli}"
  before=""
  for i in $(seq 1 "$peers"); do before="$before $(docker service inspect "${rel}_kafka-$i" --format '{{.Version.Index}}')"; done
  "$sc" charts upgrade "$rel" "$chart" -f "$chart/ci/lifecycle-values.yaml" --set heap=768m --wait --timeout 15m >/dev/null \
    || fail "the upgrade did not converge"
  i=0
  for v in $before; do
    i=$((i + 1))
    now="$(docker service inspect "${rel}_kafka-$i" --format '{{.Version.Index}}')"
    [ "$now" != "$v" ] || fail "the upgrade left peer $i's spec unchanged"
    docker service inspect "${rel}_kafka-$i" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' | has 'Xmx768m' || fail "peer $i did not take the new heap"
  done
  for i in $(seq 1 "$peers"); do
    waitfor 300 "[ -n \"\$(docker ps -q --filter label=com.docker.swarm.service.name=${rel}_kafka-$i)\" ]" || fail "peer $i is not running after the upgrade"
    seed "$i"
  done
  waitfor 300 quorum_ok || { quorum | sed 's/^/    /' || true; fail "the quorum did not survive the upgrade"; }
  n="$(kx 1 "$T/kafka-console-consumer.sh --bootstrap-server $boot $C --topic e2e-check --from-beginning --max-messages 30 --timeout-ms 60000 2>/dev/null | wc -l" | tr -d ' ')"
  [ "$n" -eq 30 ] || fail "read $n of 30 records after the upgrade"

  # 4. Raising cluster.peers adds peers on empty volumes, which must join the running
  #    quorum by themselves rather than wait for, or form, a cluster of their own.
  "$sc" charts upgrade "$rel" "$chart" -f "$chart/ci/lifecycle-values.yaml" --set cluster.peers=5 --wait --timeout 20m >/dev/null \
    || fail "the upgrade to 5 peers did not converge"
  peers=5
  for i in $(seq 1 "$peers"); do
    waitfor 300 "[ -n \"\$(docker ps -q --filter label=com.docker.swarm.service.name=${rel}_kafka-$i)\" ]" || fail "peer $i is not running after the upgrade to 5 peers"
    seed "$i"
  done
  waitfor 300 quorum_ok || { quorum | sed 's/^/    /' || true; fail "peers 4 and 5 did not join the quorum"; }
  n="$(kx 5 "$T/kafka-console-consumer.sh --bootstrap-server $(alias_of 5):9092 $C --topic e2e-check --from-beginning --max-messages 30 --timeout-ms 60000 2>/dev/null | wc -l" | tr -d ' ')"
  [ "$n" -eq 30 ] || fail "read $n of 30 records through the new peer 5"
  summary="$summary, wiped peer rejoined as a new voter, full stop and rolling upgrade survived, grew to 5 voters"
  ;;
esac

echo "  ok: $summary"
