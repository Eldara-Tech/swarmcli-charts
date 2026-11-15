#!/usr/bin/env bash
#
# e2e smoke check for the elasticsearch chart. scripts/e2e-test.sh runs this after the release
# converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case name
# Exit 0 = healthy, non-zero = failure.
#
# Convergence proves little here. A node is healthy as soon as its REST API answers, a 401
# included, so three nodes that each formed a cluster of one converge exactly like a cluster of
# three; Kibana is healthy while it still serves "not ready yet"; and kibana-setup completing says
# nothing about whether the password it set is the one Kibana logs in with. So, from a throwaway
# client on the release's overlay, the way an application connects:
#   * an anonymous request is refused (401): security is on;
#   * `elastic` authenticates with the secret's value minus its trailing newline;
#   * `kibana_system` authenticates with ITS secret's value — a password with " and \ in it —
#     which proves kibana-setup built a correct request body and stripped the newline;
#   * the cluster reports the fixture's node count, all with one elected master, and a document
#     written through node 1 is read back through the last node;
#   * in a cluster, every node recorded that it joined (later starts then leave
#     cluster.initial_master_nodes out);
#   * with tls.http, the REST API's certificate verifies against the CA, name included;
#   * Kibana reports itself available, which needs it logged in to Elasticsearch;
#   * published: both ports answer on the host; edge: Kibana is routed through the traefik chart.
set -euo pipefail

release="$1"
case="$3"
tls_dir="${E2E_ES_TLS_DIR:-${TMPDIR:-/tmp}/e2e-elasticsearch-tls}"
elastic_pw='e2e-elastic-pw'
kibana_pw='e2e-"kibana"\pw'
# The harness dumps service logs only when an install does not converge; a smoke failure here
# usually lives in kibana-setup or Kibana, so print theirs before giving up.
fail() {
  echo "  elasticsearch [$case]: $*"
  for svc in kibana-setup kibana; do
    if [ -n "$(docker service ls -q -f "name=${release}_$svc")" ]; then
      echo "      --- docker service logs ${release}_$svc (tail 40) ---"
      docker service logs --tail 40 "${release}_$svc" 2>&1 | sed 's/^/      /' || true
    fi
  done
  exit 1
}

want=1
case "$case" in cluster|cluster-transport-tls) want=3 ;; esac
tls_http=0
case "$case" in tls|cluster) tls_http=1 ;; esac
kibana=1
[ "$case" = "kibana-disabled" ] && kibana=0

cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_elasticsearch-1" | sed -n 1p)"
[ -n "$cid" ] || fail "${release}_elasticsearch-1 container not found"
image="$(docker inspect -f '{{.Config.Image}}' "$cid")"
nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$cid")"
net="$(grep -vx ingress <<<"$nets" | sed -n 1p || true)"
[ -n "$net" ] || fail "no overlay attached (networks: $nets)"

# curl from the node image (already pulled) on the overlay. With tls.http it verifies the chain
# AND the name: the certificate's SAN is the shared alias `elasticsearch`, so --connect-to dials
# the node's service while curl checks the certificate against that name.
client() {
  local node="$1"; shift
  if [ "$tls_http" = 1 ]; then
    docker run --rm --network "$net" -v "$tls_dir/ca.crt:/tmp/ca.crt:ro" --entrypoint curl "$image" \
      -sS --max-time 20 --cacert /tmp/ca.crt --connect-to "elasticsearch:9200:${release}_${node}:9200" "$@"
  else
    docker run --rm --network "$net" --entrypoint curl "$image" -sS --max-time 20 "$@"
  fi
}
url() { if [ "$tls_http" = 1 ]; then echo "https://elasticsearch:9200$2"; else echo "http://${release}_$1:9200$2"; fi; }

# Security is on: no credentials, no answer.
code="$(client elasticsearch-1 -o /dev/null -w '%{http_code}' "$(url elasticsearch-1 /)")"
[ "$code" = 401 ] || fail "an anonymous request got HTTP $code, not 401"

# The cluster forms. A first start takes a while (a node waits 30s for a master before it opens
# its REST API, and DNS publishes it only once it is healthy), so wait for the node count.
health=""
for _ in $(seq 1 36); do
  health="$(client elasticsearch-1 -u "elastic:$elastic_pw" "$(url elasticsearch-1 '/_cluster/health?wait_for_status=yellow&timeout=5s')" 2>&1 || true)"
  if grep -q "\"number_of_nodes\":$want," <<<"$health" && grep -qE '"status":"(green|yellow)"' <<<"$health"; then
    break
  fi
  sleep 5
done
grep -q "\"number_of_nodes\":$want," <<<"$health" || fail "the cluster did not reach $want node(s): $health"
grep -qE '"status":"(green|yellow)"' <<<"$health" || fail "the cluster is not green/yellow: $health"

masters="$(client elasticsearch-1 -u "elastic:$elastic_pw" "$(url elasticsearch-1 '/_cat/nodes?h=name,master')")"
[ "$(grep -c '\*' <<<"$masters")" = 1 ] || fail "expected exactly one elected master: $masters"
for n in $(seq 1 "$want"); do
  grep -q "^elasticsearch-$n " <<<"$masters" || fail "elasticsearch-$n is not in the cluster: $masters"
done

# kibana_system has the password kibana-setup set from its secret.
if [ "$kibana" = 1 ]; then
  who=""
  for _ in $(seq 1 24); do
    who="$(client elasticsearch-1 -u "kibana_system:$kibana_pw" "$(url elasticsearch-1 '/_security/_authenticate?filter_path=username')" 2>&1 || true)"
    [ "$who" = '{"username":"kibana_system"}' ] && break
    sleep 5
  done
  [ "$who" = '{"username":"kibana_system"}' ] || fail "kibana_system does not authenticate with its secret's value: $who"
fi

# A write through the first node is read back through the last.
last="elasticsearch-$want"
client elasticsearch-1 -u "elastic:$elastic_pw" -o /dev/null -f -X PUT -H 'Content-Type: application/json' \
  -d '{"v":"e2e-ok"}' "$(url elasticsearch-1 '/e2e-smoke/_doc/1?refresh=true')" || fail "the write through elasticsearch-1 failed"
got="$(client "$last" -u "elastic:$elastic_pw" "$(url "$last" '/e2e-smoke/_doc/1?filter_path=_source.v')")"
[ "$got" = '{"_source":{"v":"e2e-ok"}}' ] || fail "reading the document back through $last returned: $got"

if [ "$want" -gt 1 ]; then
  for n in $(seq 1 "$want"); do
    c="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_elasticsearch-$n" | sed -n 1p)"
    ok=0
    for _ in $(seq 1 12); do
      if docker exec "$c" test -e /usr/share/elasticsearch/data/.swarmcli-joined; then ok=1; break; fi
      sleep 5
    done
    [ "$ok" = 1 ] || fail "elasticsearch-$n never recorded that it joined the cluster"
  done
fi

if [ "$kibana" = 1 ]; then
  # Anonymous /api/status reports only the overall level, which is "available" once Kibana has
  # logged in to Elasticsearch and set up its indices.
  status=""
  for _ in $(seq 1 60); do
    status="$(docker run --rm --network "$net" --entrypoint curl "$image" -sS --max-time 10 \
      "http://${release}_kibana:5601/api/status" 2>&1 || true)"
    grep -qF '"overall":{"level":"available"}' <<<"$status" && break
    sleep 5
  done
  grep -qF '"overall":{"level":"available"}' <<<"$status" || fail "Kibana is not available: $status"
elif [ -n "$(docker service ls -q -f "name=${release}_kibana")" ]; then
  fail "a Kibana service exists although kibana.enabled is false"
fi

if [ "$case" = "published" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:19200/ || true)"
  [ "$code" = 401 ] || fail "the published REST API (19200) answered $code, not 401"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:15601/api/status || true)"
  [ "$code" = 200 ] || fail "the published Kibana (15601) answered $code, not 200"
fi

if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed kibana.e2e.test /api/status 200 || exit 1
  edge_assert_unrouted no-such-host.invalid || exit 1
fi

echo "  elasticsearch [$case]: $want node(s), auth enforced, kibana_system set$([ "$kibana" = 1 ] && echo ', Kibana available')"
