#!/usr/bin/env bash
#
# e2e smoke check for the rustfs chart. scripts/e2e-test.sh runs this after the release
# converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# A converged task proves rustfs started — and RustFS starts, converges and answers just
# as happily with its public default credentials. So every fixture asserts what the chart
# is FOR, from a throwaway client on the overlay other stacks use (the `edge` fixture:
# through the traefik chart, path-style):
#
#   * an anonymous request is refused, and so are requests signed with the wrong secret
#     and with the public default rustfsadmin pair;
#   * a SigV4-signed PUT of an object reads back byte-for-byte, and an anonymous GET of
#     that same object is refused;
#   * every bucket the fixture lists was created by the chart's bootstrap;
#   * the console listener exists exactly when console.enabled.
#
# `buckets` additionally forces a task restart and proves the object survives it and the
# bootstrap treats the buckets that now exist as done.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${RUSTFS_E2E_CURL_IMAGE:-curlimages/curl:latest}"
KEY="${RUSTFS_E2E_ACCESS_KEY:-e2e-access-key}"
SECRET="${RUSTFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
SIG='aws:amz:us-east-1:s3'

svc="${release}_rustfs"
net=rustfs-net
base="http://${svc}:9000"
route=()
buckets=""
console=""
case "$case" in
  buckets) buckets="runner-cache e2e.second-bucket" ;;
  traefik) buckets="runner-cache"; console=1 ;;
  ephemeral) buckets="scratch" ;;
  published) console=1 ;;
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
got="$(code --aws-sigv4 "$SIG" --user "rustfsadmin:rustfsadmin" "$base/")"
[ "$got" = "403" ] || die "the public default rustfsadmin pair returned '$got', expected 403"
echo "  ok: anonymous CreateBucket, a wrong-secret signature and the default rustfsadmin pair refused (403)"

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
payload="rustfs e2e $release $case $$ $(date +%s)"
got="$(printf '%s' "$payload" | signed_code -X PUT --data-binary @- "$base/$bucket/dir/object.txt")"
[ "$got" = "200" ] || die "signed PUT returned '$got', expected 200"
back="$(signed "$base/$bucket/dir/object.txt")" || die "signed GET failed"
[ "$back" = "$payload" ] || die "the object read back as '$back', expected '$payload'"
got="$(code "$base/$bucket/dir/object.txt")"
[ "$got" = "403" ] || die "anonymous GET of the object returned '$got', expected 403"
echo "  ok: signed PUT/GET round trip (path-style $base/$bucket/…), anonymous GET refused"

# ── the console listener: there exactly when console.enabled ──────────────────────────
if [ "$case" != "edge" ]; then
  got="$(docker run --rm --network rustfs-net "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
    --max-time 5 "http://${svc}:9001/rustfs/console/" 2>/dev/null || true)"
  if [ -n "$console" ]; then
    [ "$got" = "200" ] || die "console.enabled but the console UI on :9001 returned '$got', expected 200"
    got="$(docker run --rm --network rustfs-net "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
      --max-time 5 "http://${svc}:9001/" 2>/dev/null || true)"
    [ "$got" = "403" ] || [ "$got" = "302" ] || die "anonymous GET / on the console listener returned '$got'"
    echo "  ok: console UI served on :9001"
  else
    [ "$got" = "000" ] || die "console.enabled is off but :9001 answered HTTP $got"
    echo "  ok: no console listener on :9001"
  fi
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

# ── published: the ports are on the routing mesh ──────────────────────────────────────
if [ "$case" = "published" ]; then
  pub="$(docker service inspect "$svc" --format '{{range .Endpoint.Ports}}{{.TargetPort}}:{{.PublishedPort}} {{end}}')"
  grep -F '9000:19000' <<<"$pub" >/dev/null || die "the S3 port is not published as 19000 (got: $pub)"
  grep -F '9001:19001' <<<"$pub" >/dev/null || die "the console port is not published as 19001 (got: $pub)"
  echo "  ok: S3 and console published on the routing mesh as 19000 / 19001"
fi

echo "  rustfs [$case]: all checks passed"
