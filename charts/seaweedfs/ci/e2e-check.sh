#!/usr/bin/env bash
#
# e2e smoke check for the seaweedfs chart. scripts/e2e-test.sh runs this after the release
# converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# A converged task proves weed started — and an S3 store with no identity starts, converges
# and answers just as happily as one with credentials, while serving every object to
# anyone. So every fixture asserts what the chart is FOR, from a throwaway client on the
# overlay other stacks use (the `edge` fixture: through the traefik chart, path-style):
#
#   * an anonymous request is refused, and so is one signed with the wrong secret;
#   * a SigV4-signed PUT of an object reads back byte-for-byte, and an anonymous GET of
#     that same object is refused;
#   * every bucket the fixture lists was created by the chart's bootstrap;
#   * the unauthenticated master and filer APIs are not reachable from the overlay, and
#     the S3 gateway's gRPC port refuses an identity injected without the signing key.
#
# `buckets` additionally forces a task restart and proves the object survives it and the
# bootstrap treats the buckets that now exist as done.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${SEAWEEDFS_E2E_CURL_IMAGE:-curlimages/curl:latest}"
GRPCURL_IMAGE="${SEAWEEDFS_E2E_GRPCURL_IMAGE:-fullstorydev/grpcurl:v1.9.3}"
KEY="${SEAWEEDFS_E2E_ACCESS_KEY:-e2e-access-key}"
SECRET="${SEAWEEDFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
SIG='aws:amz:us-east-1:s3'

svc="${release}_seaweedfs"
net=seaweedfs-net
base="http://${svc}:8333"
route=()
buckets=""
case "$case" in
  buckets) buckets="runner-cache e2e.second-bucket" ;;
  traefik) buckets="runner-cache" ;;
  ephemeral) buckets="scratch" ;;
  edge)
    buckets="runner-cache"
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
    # Through the edge with the router's Host — via --connect-to rather than a Host header,
    # so the SigV4 signature covers the name the proxy forwards, exactly as a real client's.
    net="$EDGE_NETWORK"
    base="http://s3.e2e.test"
    route=(--connect-to "s3.e2e.test:80:${EDGE_TARGET}:80")
    ;;
esac

# curl from a throwaway container on $net; prints the body (or -w output) to stdout.
c() {
  docker run --rm -i --network "$net" "$CURL_IMAGE" -sS --max-time 15 ${route[@]+"${route[@]}"} "$@"
}
code() { c -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
signed() { c --aws-sigv4 "$SIG" --user "$KEY:$SECRET" "$@"; }
signed_code() { code --aws-sigv4 "$SIG" --user "$KEY:$SECRET" "$@"; }

diagnose() {
  echo "  --- diagnostics ---"
  docker service ps "$svc" --no-trunc 2>/dev/null | sed -n '1,6p' | sed 's/^/    /' || true
  docker service logs --tail 40 "$svc" 2>&1 | sed 's/^/    /' || true
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

got="$(code -X PUT "$base/anonymous-bucket")"
[ "$got" = "403" ] || die "anonymous CreateBucket returned '$got', expected 403"
got="$(code --aws-sigv4 "$SIG" --user "$KEY:wrong-secret" "$base/")"
[ "$got" = "403" ] || die "a request signed with the wrong secret returned '$got', expected 403"
echo "  ok: anonymous CreateBucket and a wrong-secret signature refused (403)"

# ── the listed buckets exist (the bootstrap runs in the background, so allow it time) ─
for b in $buckets; do
  listing=""
  for _ in $(seq 1 30); do
    listing="$(signed "$base/" 2>/dev/null || true)"
    grep -F "<Name>$b</Name>" <<<"$listing" >/dev/null && break
    sleep 2
  done
  grep -F "<Name>$b</Name>" <<<"$listing" >/dev/null || die "bucket $b was never created (ListBuckets: ${listing:-<empty>})"
  echo "  ok: bucket $b created by the chart"
done

# ── authenticated round trip ──────────────────────────────────────────────────────────
bucket="${buckets%% *}"
if [ -z "$bucket" ]; then
  bucket=e2e-check
  got="$(signed_code -X PUT "$base/$bucket")"
  [ "$got" = "200" ] || [ "$got" = "409" ] || die "signed CreateBucket returned '$got'"
fi
payload="seaweedfs e2e $release $case $$ $(date +%s)"
got="$(printf '%s' "$payload" | signed_code -X PUT --data-binary @- "$base/$bucket/dir/object.txt")"
[ "$got" = "200" ] || die "signed PUT returned '$got', expected 200"
back="$(signed "$base/$bucket/dir/object.txt")" || die "signed GET failed"
[ "$back" = "$payload" ] || die "the object read back as '$back', expected '$payload'"
got="$(code "$base/$bucket/dir/object.txt")"
[ "$got" = "403" ] || die "anonymous GET of the object returned '$got', expected 403"
echo "  ok: signed PUT/GET round trip (path-style $base/$bucket/…), anonymous GET refused"

# ── nothing but S3 is reachable from the overlay ──────────────────────────────────────
# Only on the client overlay: the edge fixture's network is traefik-public, where the
# service is reachable too, but one network proves the bind address. With metrics on, the
# monitoring overlay is checked as well: everything Prometheus shares it with reaches the
# service there, and must find S3 authenticated and the internal APIs shut.
probe_nets=seaweedfs-net
[ "$case" = "metrics" ] && probe_nets="seaweedfs-net monitoring"
if [ "$case" != "edge" ]; then
  for n in $probe_nets; do
    got="$(docker run --rm --network "$n" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
      --max-time 5 "http://${svc}:8333/" 2>/dev/null || true)"
    [ "$got" = "403" ] || die "anonymous GET of S3 from $n returned '$got', expected 403"
    for p in 9333 8888 8080; do
      got="$(docker run --rm --network "$n" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
        --max-time 5 "http://${svc}:$p/" 2>/dev/null || true)"
      [ "$got" = "000" ] || die "port $p (unauthenticated master/filer/volume API) answered HTTP $got from $n"
    done
    echo "  ok: from $n, S3 refuses anonymous requests and the master/filer/volume ports refuse connections"

    out="$(docker run --rm --network "$n" "$GRPCURL_IMAGE" -plaintext -max-time 10 \
      -d '{"identity":{"name":"e2e-intruder","credentials":[{"accessKey":"intruderkey","secretKey":"intrudersecret"}],"actions":["Admin"]}}' \
      "${svc}:18333" messaging_pb.SeaweedS3IamCache/PutIdentity 2>&1 || true)"
    grep -F 'Unauthenticated' <<<"$out" >/dev/null \
      || die "the S3 gRPC port did not refuse an unsigned PutIdentity from $n: $out"
  done
  got="$(code --aws-sigv4 "$SIG" --user "intruderkey:intrudersecret" "$base/")"
  [ "$got" = "403" ] || die "the injected identity was accepted (HTTP $got)"
  echo "  ok: gRPC PutIdentity without the signing key refused, and the identity does not work"
fi

# ── metrics: scraped where Prometheus would scrape it ─────────────────────────────────
# From the monitoring overlay, on the port the discovery label names. A listener left on
# loopback, or a label naming another port, converges just as healthily and is only
# caught here. The S3 round trip above has run, so the gateway's request counter must
# already carry it — proof the registry is the live process's, not an empty one.
metrics_ok=""
mport="$(docker service inspect "$svc" --format '{{index .Spec.Labels "prometheus.io/port"}}')"
if [ "$case" != "metrics" ]; then
  [ -z "$mport" ] || die "case $case opted the service in to discovery (prometheus.io/port=$mport) although metrics are off"
else
  [ -n "$mport" ] || die "the service carries no prometheus.io/port deploy label"
  m=""
  for _ in $(seq 1 15); do
    m="$(docker run --rm --network monitoring "$CURL_IMAGE" -sSf --max-time 10 "http://${svc}:${mport}/metrics" 2>&1 || true)"
    grep -E '^SeaweedFS_s3_request_total\{' <<<"$m" >/dev/null && break
    sleep 2
  done
  grep -E '^SeaweedFS_s3_request_total\{' <<<"$m" >/dev/null \
    || die "no SeaweedFS_s3_request_total series on http://${svc}:${mport}/metrics from monitoring (got: $(sed -n 1,3p <<<"$m"))"
  n_series="$(grep -cE '^SeaweedFS_' <<<"$m" || true)"
  echo "  ok: /metrics on monitoring:${mport} serves ${n_series} SeaweedFS_ samples, S3 requests counted"
  metrics_ok=", metrics scraped on monitoring"
fi

# ── restart: data persists, bootstrap is idempotent ───────────────────────────────────
if [ "$case" = "buckets" ]; then
  before="$(docker service ps -q --filter desired-state=running "$svc" | sed -n 1p)"
  docker service update --force --detach "$svc" >/dev/null
  back=""
  for _ in $(seq 1 60); do
    now="$(docker service ps -q --filter desired-state=running "$svc" | sed -n 1p)"
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
      back="$(signed "$base/$bucket/dir/object.txt" 2>/dev/null || true)"
      [ "$back" = "$payload" ] && break
    fi
    sleep 3
  done
  [ "$back" = "$payload" ] || die "after a forced restart the object read back as '${back:-<nothing>}'"
  logs=""
  for _ in $(seq 1 20); do
    logs="$(docker service logs --raw "$svc" 2>&1 || true)"
    [ "$(grep -c 'bucket .*: ready (HTTP 409)' <<<"$logs" || true)" -ge 2 ] && break
    sleep 3
  done
  for b in $buckets; do
    grep -F "bucket $b: ready (HTTP 409)" <<<"$logs" >/dev/null \
      || die "after the restart the bootstrap did not report $b as already existing (409)"
  done
  echo "  ok: forced restart kept the object; the bootstrap found the buckets already there (409)"
fi

# ── published: the port is on the routing mesh ────────────────────────────────────────
if [ "$case" = "published" ]; then
  pub="$(docker service inspect "$svc" --format '{{range .Endpoint.Ports}}{{.TargetPort}}:{{.PublishedPort}} {{end}}')"
  grep -F '8333:18333' <<<"$pub" >/dev/null || die "the S3 port is not published as 18333 (got: $pub)"
  echo "  ok: S3 published on the routing mesh as 18333"
fi

echo "  seaweedfs [$case]: all checks passed${metrics_ok}"
