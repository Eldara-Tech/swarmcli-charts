#!/usr/bin/env bash
#
# e2e smoke check for the rustfs chart in distributed mode. ci/e2e-check.sh hands every
# distributed-* case here, as $3 without the prefix. scripts/e2e-test.sh runs it after the
# release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence is a weak signal twice over here. Four peers converge just as happily on
# RustFS's public default credentials, and four peers that each formed a one-drive store of
# their own report healthy too. So every fixture asserts what the chart is FOR, from a
# throwaway client on the overlay other stacks use (the `edge` fixture: through the traefik
# chart, path-style):
#
#   * every peer reports ONE erasure set of all four drives with every peer online (the
#     admin API), answers /health/ready, and reports the cluster healthy (/minio/health/cluster);
#   * an anonymous request is refused, and so are requests signed with the wrong secret
#     and with the public default rustfsadmin pair;
#   * an object written through the client path (the shared alias, or the edge) reads back
#     byte-for-byte through every peer, and an anonymous GET of it is refused;
#   * every bucket the fixture lists was created by peer 1's bootstrap and is seen by every
#     peer;
#   * the console listener exists exactly when console.enabled;
#   * `edge`: Traefik merged the peers' identical routers into one service that balances
#     over all four, and the signed round trip works through it;
#   * `console-edge`: the console is routed through the traefik chart, its sticky cookie
#     keeps a browser on one peer, and the S3 host is not routed;
#   * `oidc`: every peer discovered the stub provider under the chart's default label, the
#     login redirects to its authorization endpoint with the chart's client id and callback
#     (a spoofed Host cannot move it), and the client secret reached the server's
#     environment but not `docker inspect`;
#   * the raised open-file limit reached each peer, and its log reaches `docker service logs`;
#   * `metrics`: the collector serves, on the monitoring overlay, every RustFS metric the
#     alert rules and the dashboard read, from all four peers; no peer is on that overlay
#     or dumps metrics into its log, and the alert rules pass promtool. Elsewhere there is
#     no collector.
#   * `bind-mount`: each peer's drive is the host directory its volumePaths entry names.
#
# `buckets` additionally forces peer 1's task to restart and proves the object survives and
# the bootstrap passes again over the buckets that now exist. `lifecycle` drives
# `swarmcli charts upgrade` itself: an upgrade rolling every peer one at a time while a
# client keeps writing, then every peer stopped together and started again.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${RUSTFS_E2E_CURL_IMAGE:-curlimages/curl:latest}"
KEY="${RUSTFS_E2E_ACCESS_KEY:-e2e-access-key}"
SECRET="${RUSTFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
SIG='aws:amz:us-east-1:s3'
PEERS="1 2 3 4"

# The aliases the chart adds on rustfs-net: <release>-rustfs on every peer, and
# <release>-rustfs-<n> on peer n. scripts/e2e-test.sh names releases [a-z0-9-] only, so
# they need no mapping.
alias="${release}-rustfs"
svc() { echo "${release}_rustfs-$1"; }
net=rustfs-net
base="http://${alias}:9000"
route=()
buckets=""
console=""
case "$case" in
  buckets) buckets="runner-cache e2e.second-bucket" ;;
  traefik) buckets="runner-cache"; console=1 ;;
  ephemeral) buckets="scratch" ;;
  lifecycle) buckets="lifecycle" ;;
  published|console-edge|oidc) console=1 ;;
  edge)
    buckets="runner-cache"
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
    # Through the edge with the router's Host — via --connect-to rather than a Host header,
    # so the SigV4 signature covers the name the proxy forwards, exactly as a real client's.
    net="$EDGE_NETWORK"
    base="http://s3-cluster.e2e.test"
    route=(--connect-to "s3-cluster.e2e.test:80:${EDGE_TARGET}:80")
    ;;
esac

# curl from a throwaway container on $net (the client's path); prints the body (or -w output).
c() {
  docker run --rm -i --network "$net" "$CURL_IMAGE" -sS --max-time 15 ${route[@]+"${route[@]}"} "$@"
}
code() { c -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
signed() { c --aws-sigv4 "$SIG" --user "$KEY:$SECRET" "$@"; }
signed_code() { code --aws-sigv4 "$SIG" --user "$KEY:$SECRET" "$@"; }
# The same on rustfs-net, where every peer has an alias of its own, whatever $net is.
cr() { docker run --rm -i --network rustfs-net "$CURL_IMAGE" -sS --max-time 15 "$@"; }
cr_code() { cr -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
cr_signed() { cr --aws-sigv4 "$SIG" --user "$KEY:$SECRET" "$@"; }
cid_of() { docker ps -q -f "label=com.docker.swarm.service.name=$(svc "$1")" | sed -n 1p; }

diagnose() {
  echo "  --- diagnostics ---"
  for n in $PEERS; do
    docker service ps "$(svc "$n")" --no-trunc 2>/dev/null | sed -n '1,4p' | sed 's/^/    /' || true
    docker service logs --tail 15 "$(svc "$n")" 2>&1 | sed 's/^/    /' || true
  done
}
die() { echo "  FAIL: $*"; diagnose; exit 1; }

# ── the store answers at all (the edge may still be discovering it) ────────────────────
got=""
for _ in $(seq 1 30); do
  got="$(code "$base/")"
  [ "$got" = "403" ] && break
  sleep 3
done
[ "$got" = "403" ] || die "anonymous GET $base/ returned '$got', expected 403 (auth must be enforced)"
echo "  ok: anonymous ListBuckets refused (403)"

# Peers pass their liveness check before the cluster serves: before write quorum, and before
# each peer has loaded IAM, a request is answered 503 (README § Connecting: clients retry).
# With short health windows, as in `lifecycle`, the checks below can start in that gap, so
# wait for write quorum and for every peer's /health/ready, which covers IAM, first.
ready=""; last=""
for _ in $(seq 1 40); do
  ready=1; last="$(code "$base/minio/health/cluster")"
  [ "$last" = "200" ] || ready=""
  for n in $PEERS; do
    r="$(cr_code "http://${alias}-$n:9000/health/ready")"
    [ "$r" = "200" ] || { ready=""; last="$last, peer $n ready $r"; }
  done
  [ -n "$ready" ] && break
  sleep 3
done
[ -n "$ready" ] || die "the cluster did not serve within 2 minutes: health/cluster and per-peer health/ready answered '$last'"

got="$(code -X PUT "$base/anonymous-bucket")"
[ "$got" = "403" ] || die "anonymous CreateBucket returned '$got', expected 403"
got="$(code --aws-sigv4 "$SIG" --user "$KEY:wrong-secret" "$base/")"
[ "$got" = "403" ] || die "a request signed with the wrong secret returned '$got', expected 403"
got="$(code --aws-sigv4 "$SIG" --user "rustfsadmin:rustfsadmin" "$base/")"
[ "$got" = "403" ] || die "the public default rustfsadmin pair returned '$got', expected 403"
echo "  ok: anonymous CreateBucket, a wrong-secret signature and the default rustfsadmin pair refused (403)"

# ── one cluster, not four stores ──────────────────────────────────────────────────────
# The admin API's view, from every peer: one erasure set of 4 drives, every peer online with
# its drive. Four standalone stores would each report a set of 1 and one server. A peer that
# has just started may still list another as initializing.
want_servers="$(for n in $PEERS; do printf '%s-%s:9000\n' "$alias" "$n"; done | sort)"
for n in $PEERS; do
  got=""; servers=""
  for _ in $(seq 1 30); do
    info="$(cr_signed "http://${alias}-$n:9000/rustfs/admin/v3/info" 2>/dev/null || true)"
    got="$(jq -r '.info.backend | [.backendType, (.totalSets | tostring), (.totalDrivesPerSet | tostring), (.onlineDisks | tostring)] | join(" ")' <<<"$info" 2>/dev/null || true)"
    servers="$(jq -r '.info.servers[] | select(.state == "online") | .endpoint' <<<"$info" 2>/dev/null | sort || true)"
    [ "$got" = 'Erasure [1] [4] 4' ] && [ "$servers" = "$want_servers" ] && break
    sleep 3
  done
  [ "$got" = 'Erasure [1] [4] 4' ] && [ "$servers" = "$want_servers" ] \
    || die "peer $n's admin info reports backend '$got' and online servers '$(echo $servers)'; expected 'Erasure [1] [4] 4' and all four peers"
done
echo "  ok: every peer reports one erasure set of 4 drives, all 4 peers online"
for n in $PEERS; do
  got=""
  for _ in $(seq 1 30); do
    got="$(cr_code "http://${alias}-$n:9000/health/ready")/$(cr_code "http://${alias}-$n:9000/minio/health/cluster")"
    [ "$got" = "200/200" ] && break
    sleep 3
  done
  [ "$got" = "200/200" ] || die "peer $n answered /health/ready and /minio/health/cluster with '$got', expected 200/200"
done
echo "  ok: every peer is ready at ${alias}-<n> and reports the cluster healthy"

# ── the listed buckets exist (the bootstrap runs in the background, so allow it time) ─
for b in $buckets; do
  for n in $PEERS; do
    listing=""
    for _ in $(seq 1 30); do
      listing="$(cr_signed "http://${alias}-$n:9000/" 2>/dev/null || true)"
      grep -F "<Name>$b</Name>" <<<"$listing" >/dev/null && break
      sleep 2
    done
    grep -F "<Name>$b</Name>" <<<"$listing" >/dev/null || die "peer $n does not list bucket $b (ListBuckets: ${listing:-<empty>})"
  done
  echo "  ok: bucket $b created by the chart and listed by every peer"
done

# ── authenticated round trip, written through the client path, read through every peer ─
bucket="${buckets%% *}"
if [ -z "$bucket" ]; then
  bucket=e2e-check
  got="$(signed_code -X PUT "$base/$bucket")"
  [ "$got" = "200" ] || [ "$got" = "409" ] || die "signed CreateBucket returned '$got'"
fi
payload="rustfs-distributed e2e $release $case $$ $(date +%s)"
got="$(printf '%s' "$payload" | signed_code -X PUT --data-binary @- "$base/$bucket/dir/object.txt")"
[ "$got" = "200" ] || die "signed PUT returned '$got', expected 200"
back="$(signed "$base/$bucket/dir/object.txt")" || die "signed GET failed"
[ "$back" = "$payload" ] || die "the object read back as '$back', expected '$payload'"
for n in $PEERS; do
  back="$(cr_signed "http://${alias}-$n:9000/$bucket/dir/object.txt" 2>/dev/null || true)"
  [ "$back" = "$payload" ] || die "the object read back through peer $n as '$back', expected '$payload'"
done
got="$(code "$base/$bucket/dir/object.txt")"
[ "$got" = "403" ] || die "anonymous GET of the object returned '$got', expected 403"
echo "  ok: signed PUT through $base/$bucket/…, read back byte-for-byte through every peer; anonymous GET refused"

# ── what the chart sets on each process ───────────────────────────────────────────────
for n in $PEERS; do
  cid="$(cid_of "$n")"
  [ -n "$cid" ] || die "no running container of $(svc "$n") on this node (the e2e swarm is single-node)"
  nofile="$(docker exec "$cid" sh -c 'ulimit -n')"
  [ "$nofile" = "65536" ] || die "the open-file limit inside peer $n is $nofile, expected the chart's 65536"
  logs="$(docker service logs --raw "$(svc "$n")" 2>&1 || true)"
  grep -F '"level":' <<<"$logs" >/dev/null || die "no server log line from peer $n in docker service logs; RustFS is still logging to a file"
done
echo "  ok: nofile 65536 inside every peer, every peer's log on docker service logs"

# ── metrics: scraped where Prometheus would scrape it ─────────────────────────────────
# From the monitoring overlay, on the port the discovery label names. The peers push every
# 30 seconds, and the per-bucket series wait for the first data-usage scan. Every name the
# rules and the dashboard read is checked, so a renamed metric fails here rather than in a
# panel, and every peer must be among the reporters.
metrics_ok=""
msvc="${release}_rustfs-distributed-metrics"
if [ "$case" != "metrics" ]; then
  if docker service inspect "$msvc" >/dev/null 2>&1; then die "case $case created $msvc although metrics are off"; fi
else
  mport="$(docker service inspect "$msvc" --format '{{index .Spec.Labels "prometheus.io/port"}}')"
  [ "$mport" = "8889" ] || die "$msvc carries prometheus.io/port='$mport', expected 8889"
  mon="$dir/monitoring"
  # The distributed group of the rules only, which alone reads the erasure-set series.
  group="$(awk '/^  - name: /{ g = $3 } g == "rustfs-distributed"' "$mon/rustfs-rules.yml" | grep -v -E '^[[:space:]]*(#|summary:|description:)' || true)"
  grep -F 'rustfs_cluster_erasure_set_' <<<"$group" >/dev/null || die "monitoring/rustfs-rules.yml has no group 'rustfs-distributed' reading the erasure-set series; the extraction is broken"
  want="$( { printf '%s\n' "$group"; grep -F '"expr"' "$mon/rustfs-dashboard.json"; } \
    | grep -oE 'rustfs_[a-z0-9_]+' | sed -E 's/_(bucket|sum|count)$//' | sort -u)"
  [ "$(wc -l <<<"$want")" -ge 15 ] || die "found only $(wc -l <<<"$want") metric names in monitoring/; the extraction is broken"
  m=""; missing="$want"; servers=""
  for _ in $(seq 1 60); do
    m="$(docker run --rm --network monitoring "$CURL_IMAGE" -sSf --max-time 10 "http://${msvc}:${mport}/metrics" 2>&1 || true)"
    have="$(grep -oE '^rustfs_[a-z0-9_]+' <<<"$m" | sed -E 's/_(bucket|sum|count)$//' | sort -u || true)"
    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))"
    servers="$(grep -E '^rustfs_system_process_uptime_seconds\{' <<<"$m" | grep -oE 'server="[^"]*"' | sort -u | tr '\n' ' ' || true)"
    [ -z "$missing" ] && [ "$servers" = "server=\"${alias}-1:9000\" server=\"${alias}-2:9000\" server=\"${alias}-3:9000\" server=\"${alias}-4:9000\" " ] && break
    sleep 5
  done
  [ -z "$missing" ] || die "the collector on monitoring:${mport} does not serve $(tr '\n' ' ' <<<"$missing")(got: $(sed -n 1,3p <<<"$m"))"
  [ "$servers" = "server=\"${alias}-1:9000\" server=\"${alias}-2:9000\" server=\"${alias}-3:9000\" server=\"${alias}-4:9000\" " ] \
    || die "the collector's process series name the peers ${servers:-<none>}, expected all four by alias"
  # A PUT, which only the round trip sends: the healthchecks' GETs are counted too, so a 2xx
  # or GET count would pass on them alone.
  grep -E '^rustfs_http_server_requests_total\{.*method="PUT".*\} [1-9]' <<<"$m" >/dev/null \
    || die "the collector does not count the round trip's PUTs"
  echo "  ok: the collector on monitoring:${mport} serves all $(wc -l <<<"$want" | tr -d ' ') RustFS metrics the rules and the dashboard read, from all four peers, and counts the round trip's PUTs"
  for n in $PEERS; do
    # By service name, which resolves on every network the service joins.
    got="$(docker run --rm --network monitoring "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$(svc "$n"):9000/" 2>/dev/null || true)"
    [ "$got" = "000" ] || die "peer $n's S3 port answers HTTP $got from the monitoring overlay; no peer may join it"
    logs="$(docker service logs --raw "$(svc "$n")" 2>&1 || true)"
    if grep -F 'rustfs_system_process_uptime_seconds' <<<"$logs" >/dev/null; then
      die "peer $n dumps its metrics into docker service logs: it is exporting to stdout as well as to the collector"
    fi
  done
  echo "  ok: no peer is on monitoring, and none dumps metrics into its log"
  metrics_ok=", metrics scraped on monitoring"

  # The alert rules the chart ships for operators to load (monitoring/), checked here
  # because nothing deploys them: their logic, under the promtool of a pinned Prometheus.
  # The image follows prometheus-stack's appVersion, which Renovate keeps current.
  chart="$(cd "$dir" && pwd)"
  prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart/../prometheus-stack/Chart.yaml")"
  promtool_image="${RUSTFS_E2E_PROMTOOL_IMAGE:-prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}}"
  out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "$promtool_image" \
    test rules /chart/ci/rustfs-distributed-rules-test.yml 2>&1)" \
    || die "promtool test rules fails on monitoring/rustfs-rules.yml's distributed group: $out"
  echo "  ok: the alert rules pass promtool"
  metrics_ok="$metrics_ok, alert rules pass promtool"
fi

# ── the console listener: there exactly when console.enabled ──────────────────────────
for n in $PEERS; do
  got="$(cr_code "http://${alias}-$n:9001/rustfs/console/")"
  if [ -n "$console" ]; then
    [ "$got" = "200" ] || die "console.enabled but peer $n's console UI on :9001 returned '$got', expected 200"
  else
    [ "$got" = "000" ] || die "console.enabled is off but peer $n's :9001 answered HTTP $got"
  fi
done
if [ -n "$console" ]; then echo "  ok: console UI served on :9001 by every peer"; else echo "  ok: no console listener on :9001"; fi

# Distinct upstream addresses the edge's access log shows for one router's requests whose
# path carries the marker $2: Traefik's common log format has the request line, then ends
# with "<router>" "<upstream URL>" <duration>ms. The log is written asynchronously.
upstreams() {
  sleep 3
  docker service logs --raw "$EDGE_TARGET" 2>&1 | grep -F "$2" | grep -F "\"$1@swarm\"" \
    | grep -oE '"http://[0-9.]+:[0-9]+"' | sort -u | wc -l | tr -d ' ' || true
}

# ── edge: one Traefik service over every peer ─────────────────────────────────────────
if [ "$case" = "edge" ]; then
  # Keys that do not exist, so each GET is a 404 whose path names this check.
  mark="balance-$$"
  for i in $(seq 1 24); do signed -o /dev/null "$base/$bucket/$mark-$i" || die "a signed GET through the edge failed"; done
  got="$(upstreams "${release}-http" "$mark-")"
  [ "$got" = "4" ] || die "the edge sent 24 requests to $got distinct peers, expected all 4: Traefik did not merge the peers' identical routers into one service"
  echo "  ok: Traefik merged the four peers' routers into one service and balanced 24 requests over all four"
fi

# ── console-edge: the console through the edge, a browser kept on one peer ───────────
if [ "$case" = "console-edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  chost=rustfs-cluster-console.e2e.test
  edge_assert_routed "$chost" /rustfs/console/ 200 || die "the console UI is not routed on $chost"
  ec() { docker run --rm --network "$EDGE_NETWORK" "$CURL_IMAGE" -sS --max-time 10 --connect-to "$chost:80:${EDGE_TARGET}:80" "$@"; }
  cookie="$(ec -o /dev/null -D - "http://$chost/rustfs/console/" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' | sed -n 1p)"
  [ -n "$cookie" ] || die "the console route sets no sticky cookie"
  for _ in $(seq 1 12); do ec -o /dev/null -H "Cookie: $cookie" "http://$chost/rustfs/console/?sticky=$$" || die "a console request with the sticky cookie failed"; done
  got="$(upstreams "${release}-console-http" "?sticky=$$ ")"
  [ "$got" = "1" ] || die "12 console requests carrying the sticky cookie reached $got peers, expected 1: a single sign-on would fail"
  for _ in $(seq 1 16); do ec -o /dev/null "http://$chost/rustfs/console/?free=$$" || die "a console request without a cookie failed"; done
  got="$(upstreams "${release}-console-http" "?free=$$ ")"
  [ "$got" -gt 1 ] || die "16 console requests without a cookie all reached one peer: the console is not balanced over the peers"
  echo "  ok: the console is routed on $chost, balanced over the peers, and its sticky cookie keeps a browser on one"
  edge_assert_unrouted s3.example.com || die "ingress.host is routed although exposure.mode is none"
fi

# ── oidc: every peer loaded the stub provider, and the login goes to it ──────────────
if [ "$case" = "oidc" ]; then
  for n in $PEERS; do
    got="$(cr "http://${alias}-$n:9001/rustfs/admin/v3/oidc/providers" 2>/dev/null || true)"
    grep -F '"provider_id":"default"' <<<"$got" >/dev/null \
      || die "peer $n did not load the stub provider (providers: ${got:-<empty>}); was it reachable at start?"
    grep -F '"display_name":"SSO"' <<<"$got" >/dev/null \
      || die "peer $n's provider label is not the chart's default console.oidc.displayName, SSO (providers: $got)"
  done
  echo "  ok: every peer discovered the provider at start, labelled SSO"
  api="http://${alias}-1:9001/rustfs/admin/v3/oidc"
  auth='http://rustfs-e2e-idp:8080/realms/e2e/protocol/openid-connect/auth?'
  cb='redirect_uri=https%3A%2F%2Frustfs-cluster-console.e2e.test%2Frustfs%2Fadmin%2Fv3%2Foidc%2Fcallback%2Fdefault'
  for host in "${alias}-1:9001" evil.example; do
    loc="$(cr -o /dev/null -w '%{redirect_url}' -H "Host: $host" -H 'X-Forwarded-Proto: http' "$api/authorize/default" 2>/dev/null || true)"
    case "$loc" in "$auth"*) ;; *) die "the login (Host: $host) redirected to '${loc:-<nothing>}', not to the stub's authorization endpoint" ;; esac
    grep -E '[?&]client_id=rustfs-e2e(&|$)' <<<"$loc" >/dev/null || die "the login does not carry client_id=rustfs-e2e: $loc"
    grep -E "[?&]$cb(&|\$)" <<<"$loc" >/dev/null || die "the login (Host: $host) does not carry the callback on console.ingress.host: $loc"
  done
  echo "  ok: the login redirects to the stub with client_id rustfs-e2e and the https://rustfs-cluster-console.e2e.test callback, whatever the Host header says"
  # Compared against the secret the task mounts, not a known value: setup keeps a secret left
  # over from an earlier run, which would make a check against the default pass vacuously.
  for n in $PEERS; do
    cid="$(cid_of "$n")"
    oidc_secret="$(docker exec "$cid" cat /run/secrets/rustfs-oidc-client-secret 2>/dev/null || true)"
    [ -n "$oidc_secret" ] || die "peer $n mounts no (or an empty) /run/secrets/rustfs-oidc-client-secret"
    docker exec "$cid" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -Fx "RUSTFS_IDENTITY_OPENID_CLIENT_SECRET=$(cat /run/secrets/rustfs-oidc-client-secret)" >/dev/null' \
      || die "the OIDC client secret did not reach peer $n's environment"
    if { docker service inspect "$(svc "$n")"; docker inspect "$cid"; } | grep -F -- "$oidc_secret" >/dev/null; then
      die "the OIDC client secret is visible in docker inspect of peer $n"
    fi
  done
  echo "  ok: the client secret is in every peer's environment and not in docker inspect of any service or task"
fi

# ── bind-mount: each drive is its peer's host directory ───────────────────────────────
if [ "$case" = "bind-mount" ]; then
  for n in $PEERS; do
    # As root: the directory is 10001's, mode 0750.
    docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh "$CURL_IMAGE" \
      -c "test -s /host-tmp/rustfs-distributed-e2e/$n/.rustfs.sys/format.json" \
      || die "peer $n's host directory /tmp/rustfs-distributed-e2e/$n holds no .rustfs.sys/format.json: its drive is not there"
  done
  echo "  ok: every peer formatted its drive in the host directory its volumePaths entry names"
fi

# ── buckets: peer 1 restarts, data persists, bootstrap is idempotent ──────────────────
if [ "$case" = "buckets" ]; then
  before="$(docker service ps -q --filter desired-state=running "$(svc 1)" | sed -n 1p)"
  docker service update --force --detach "$(svc 1)" >/dev/null
  back=""
  for _ in $(seq 1 60); do
    now="$(docker service ps -q --filter desired-state=running "$(svc 1)" | sed -n 1p)"
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
      back="$(cr_signed "http://${alias}-1:9000/$bucket/dir/object.txt" 2>/dev/null || true)"
      [ "$back" = "$payload" ] && break
    fi
    sleep 3
  done
  [ "$back" = "$payload" ] || die "after a forced restart of peer 1 the object read back through it as '${back:-<nothing>}'"
  # Both tasks' logs are in `docker service logs`: every bucket must be reported ready
  # twice, once by each, and the second time it already existed.
  logs=""
  for _ in $(seq 1 20); do
    logs="$(docker service logs --raw "$(svc 1)" 2>&1 || true)"
    done_all=1
    for b in $buckets; do
      [ "$(grep -cE "^bucket $b: ready \(HTTP (200|409)\)$" <<<"$logs" || true)" -ge 2 ] || done_all=""
    done
    [ -n "$done_all" ] && break
    sleep 3
  done
  [ -n "$done_all" ] || die "after the restart the bootstrap did not report every bucket ready again: $(grep '^bucket ' <<<"$logs" | tr '\n' ';')"
  for n in 2 3 4; do
    if docker service logs --raw "$(svc "$n")" 2>&1 | grep -E '^bucket ' >/dev/null; then
      die "peer $n ran the bucket bootstrap; only peer 1 does"
    fi
  done
  echo "  ok: forced restart of peer 1 kept the object; its bootstrap passed again over the existing buckets, and no other peer ran one"
fi

# ── lifecycle: an upgrade rolling every peer under writes, then a full stop ───────────
# Runs `swarmcli charts upgrade` itself, so it needs $SWARMCLI, as scripts/e2e-test.sh
# exports it.
if [ "$case" = "lifecycle" ]; then
  SWARMCLI="${SWARMCLI:-swarmcli}"
  chart="$(cd "$dir" && pwd)"
  task_of() { docker service ps -q --filter desired-state=running "$(svc "$1")" | sed -n 1p; }
  tmp="$(mktemp -d)"
  writer="${release}-writer"
  trap 'docker rm -f "$writer" >/dev/null 2>&1 || true; kill "${sampler:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT

  # A client writing once a second through the shared alias, retrying as the README tells
  # clients to: the alias stops resolving to a peer once its task is gone, but a connection
  # already on its way there fails. Each line is "<n> <final HTTP code>".
  docker rm -f "$writer" >/dev/null 2>&1 || true
  docker run -d --name "$writer" --network rustfs-net --entrypoint sh "$CURL_IMAGE" -c \
    "i=0; while :; do i=\$((i+1)); printf x | curl -s -o /dev/null -w \"\$i %{http_code}\\n\" --max-time 10 \
      --retry 5 --retry-all-errors --retry-delay 1 --aws-sigv4 '$SIG' --user '$KEY:$SECRET' \
      -X PUT --data-binary @- 'http://${alias}:9000/$bucket/w/'\$i; sleep 1; done" >/dev/null
  # Whether any peer reports the cluster writable, every 2 seconds: "-" when none does.
  (
    while :; do
      ok=-
      for n in $PEERS; do
        [ "$(cr_code "http://${alias}-$n:9000/minio/health/cluster")" = 200 ] && { ok=$n; break; }
      done
      echo "$ok" >>"$tmp/cluster"
      sleep 2
    done
  ) &
  sampler=$!

  before_tasks="$(for n in $PEERS; do task_of "$n"; done)"
  extra="$tmp/roll.yaml"
  printf 'extraEnv:\n  E2E_ROLL: "%s"\n' "$(date +%s)" >"$extra"
  "$SWARMCLI" charts upgrade "$release" "$chart" -f "$chart/ci/distributed-lifecycle-values.yaml" -f "$extra" --wait --timeout 10m >/dev/null \
    || die "the all-peer upgrade did not roll out"
  now_tasks="$(for n in $PEERS; do task_of "$n"; done)"
  [ "$(printf '%s\n' $now_tasks | wc -l | tr -d ' ')" = "4" ] \
    && [ -z "$(comm -12 <(printf '%s\n' $before_tasks | sort) <(printf '%s\n' $now_tasks | sort))" ] \
    || die "the upgrade did not give every peer a new task (before: $(echo $before_tasks); after: $(echo $now_tasks))"
  sleep 4
  kill "$sampler"; wait "$sampler" 2>/dev/null || true; sampler=""
  docker stop -t 2 "$writer" >/dev/null 2>&1 || true
  if grep -x -- - "$tmp/cluster" >/dev/null; then
    die "no peer reported the cluster writable at $(grep -cx -- - "$tmp/cluster") of $(wc -l <"$tmp/cluster" | tr -d ' ') samples during the upgrade; the peers did not roll one at a time"
  fi
  writes="$(docker logs "$writer" 2>&1 || true)"
  total="$(grep -cE '^[0-9]+ [0-9]{3}$' <<<"$writes" || true)"
  failed="$(grep -E '^[0-9]+ [0-9]{3}$' <<<"$writes" | grep -vcE ' 200$' || true)"
  [ "$total" -ge 30 ] || die "the writer finished only $total writes during the upgrade: $(tail -3 <<<"$writes" | tr '\n' ';')"
  [ "$failed" = "0" ] || die "$failed of $total writes failed during the upgrade, even with retries: $(grep -vE ' 200$' <<<"$writes" | sed -n 1,5p | tr '\n' ';')"
  echo "  ok: the upgrade gave every peer a new task while the cluster stayed writable at every sample, and all $total writes succeeded"
  # Quorum alone does not tell one at a time from all at once on a cluster this small. The
  # order does: one at a time, each new task starts only after the one before has outlived
  # its 20s monitor window; all at once, they start within seconds of each other.
  prev=""
  for t in $(for task in $now_tasks; do docker inspect --format '{{.CreatedAt.Unix}}' "$task"; done | sort -n); do
    if [ -n "$prev" ] && [ $((t - prev)) -lt 15 ]; then
      die "two peers' new tasks started $((t - prev))s apart; the upgrade did not wait out a monitor window between them"
    fi
    prev="$t"
  done
  echo "  ok: the peers' new tasks started one monitor window apart, in sequence"

  # Every peer stopped together, as after a power cut, and started again: no peer can reach
  # any other while they start, which is exactly what a peer-independent healthcheck and an
  # explicit local endpoint are for.
  for n in $PEERS; do docker service scale --detach "$(svc "$n")=0" >/dev/null; done
  for _ in $(seq 1 30); do
    [ -z "$(for n in $PEERS; do docker ps -q -f "label=com.docker.swarm.service.name=$(svc "$n")"; done)" ] && break
    sleep 2
  done
  [ -z "$(for n in $PEERS; do docker ps -q -f "label=com.docker.swarm.service.name=$(svc "$n")"; done)" ] || die "the peers did not stop"
  for n in $PEERS; do docker service scale --detach "$(svc "$n")=1" >/dev/null; done
  got=""
  for _ in $(seq 1 60); do
    got="$(cr_code "$base/minio/health/cluster")"
    [ "$got" = "200" ] && break
    sleep 3
  done
  [ "$got" = "200" ] || die "after every peer stopped and started, the cluster never reported healthy (last: '$got')"
  for n in $PEERS; do
    back=""
    for _ in $(seq 1 20); do
      back="$(cr_signed "http://${alias}-$n:9000/$bucket/dir/object.txt" 2>/dev/null || true)"
      [ "$back" = "$payload" ] && break
      sleep 3
    done
    [ "$back" = "$payload" ] || die "after the full stop the object read back through peer $n as '${back:-<nothing>}'"
  done
  echo "  ok: after every peer stopped together and started again, the cluster formed by itself and every peer serves the object"
fi

echo "  rustfs distributed [$case]: all checks passed${metrics_ok}"
