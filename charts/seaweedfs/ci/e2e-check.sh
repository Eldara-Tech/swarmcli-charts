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
# bootstrap treats the buckets that now exist as done. The admin-* fixtures log in to the
# web UI (`admin-edge`: through the traefik chart, with the S3 host unrouted): a wrong
# password is refused, the right one lists the bucket, and a stopped UI comes back while
# S3 keeps serving from the same task.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${SEAWEEDFS_E2E_CURL_IMAGE:-curlimages/curl:latest}"
GRPCURL_IMAGE="${SEAWEEDFS_E2E_GRPCURL_IMAGE:-fullstorydev/grpcurl:v1.9.3}"
KEY="${SEAWEEDFS_E2E_ACCESS_KEY:-e2e-access-key}"
SECRET="${SEAWEEDFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
ADMIN_PASSWORD="${SEAWEEDFS_E2E_ADMIN_PASSWORD:-e2e/admin+password0123}"
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

# ── nothing but S3 (and the admin UI) is reachable from the overlay ──────────────────
# On the client overlay: the edge fixture's network is traefik-public, where the service
# is reachable too, but one network proves the bind address. admin-edge checks both, and
# the admin's worker gRPC port (23646 + 10000) as well.
if [ "$case" != "edge" ]; then
  overlays=seaweedfs-net
  ports="9333 8888 8080"
  case "$case" in
    admin-edge) overlays="seaweedfs-net traefik-public"; ports="$ports 33646" ;;
    admin-*) ports="$ports 33646" ;;
  esac
  for n in $overlays; do
    for p in $ports; do
      got="$(docker run --rm --network "$n" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
        --max-time 5 "http://${svc}:$p/" 2>/dev/null || true)"
      [ "$got" = "000" ] || die "port $p (an unauthenticated master/filer/volume API or the admin's worker gRPC) answered HTTP $got from $n"
    done
  done
  echo "  ok: ports $ports refuse connections from $overlays"

  out="$(docker run --rm --network seaweedfs-net "$GRPCURL_IMAGE" -plaintext -max-time 10 \
    -d '{"identity":{"name":"e2e-intruder","credentials":[{"accessKey":"intruderkey","secretKey":"intrudersecret"}],"actions":["Admin"]}}' \
    "${svc}:18333" messaging_pb.SeaweedS3IamCache/PutIdentity 2>&1 || true)"
  grep -F 'Unauthenticated' <<<"$out" >/dev/null \
    || die "the S3 gRPC port did not refuse an unsigned PutIdentity: $out"
  got="$(code --aws-sigv4 "$SIG" --user "intruderkey:intrudersecret" "$base/")"
  [ "$got" = "403" ] || die "the injected identity was accepted (HTTP $got)"
  echo "  ok: gRPC PutIdentity without the signing key refused, and the identity does not work"
fi

# ── the admin UI: a login page for anyone, the store only with the password ───────────
case "$case" in
  admin-*)
    anet=seaweedfs-net
    abase="http://${svc}:23646"
    aroute=()
    if [ "$case" = "admin-edge" ]; then
      . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
      anet="$EDGE_NETWORK"
      abase="http://admin.e2e.test"
      aroute=(--connect-to "admin.e2e.test:80:${EDGE_TARGET}:80")
    fi
    # One request; prints the response headers, then the body unless -o sends it away.
    a() { docker run --rm --network "$anet" "$CURL_IMAGE" -sS --max-time 15 -D - ${aroute[@]+"${aroute[@]}"} "$@" 2>/dev/null | tr -d '\r' || true; }
    status() { sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p'; }
    header() { grep -i "^$1:" | sed -n '1s/^[^:]*: *//p'; }
    session() { header Set-Cookie | sed -n 's/^\(admin-session=[^;]*\).*/\1/p'; }

    page=""
    for _ in $(seq 1 30); do
      page="$(a "$abase/login")"
      [ "$(status <<<"$page")" = "200" ] && grep -F 'name="csrf_token"' <<<"$page" >/dev/null && break
      sleep 3
    done
    grep -F 'name="csrf_token"' <<<"$page" >/dev/null \
      || die "the admin UI never served its login page at $abase/login (last HTTP $(status <<<"$page"))"
    got="$(a -o /dev/null "$abase/")"
    [ "$(status <<<"$got")" = "307" ] && [ "$(header Location <<<"$got")" = "/login" ] \
      || die "an unauthenticated GET $abase/ was not sent to /login (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
    echo "  ok: the admin UI serves its login page at $abase/login and sends an unauthenticated request there"

    csrf="$(sed -n 's/.*name="csrf_token" value="\([0-9a-f]*\)".*/\1/p' <<<"$page" | sed -n 1p)"
    jar="$(session <<<"$page")"
    [ -n "$csrf" ] && [ -n "$jar" ] || die "the login page carried no CSRF token or no session cookie"
    login() { a -o /dev/null -H "Cookie: $jar" --data-urlencode "csrf_token=$csrf" --data-urlencode username=admin \
      --data-urlencode "password=$1" "$abase/login"; }
    got="$(login wrong-password)"
    [ "$(status <<<"$got")" = "303" ] && grep -F 'error=Invalid credentials' <<<"$(header Location <<<"$got")" >/dev/null \
      || die "a wrong admin password was not refused (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
    got="$(login "$ADMIN_PASSWORD")"
    [ "$(status <<<"$got")" = "303" ] && [ "$(header Location <<<"$got")" = "/admin" ] \
      || die "the admin password was refused (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
    listing="$(a -H "Cookie: $(session <<<"$got")" "$abase/api/s3/buckets")"
    [ "$(status <<<"$listing")" = "200" ] && grep -F "\"name\":\"$bucket\"" <<<"$listing" >/dev/null \
      || die "the admin session does not list bucket $bucket: $(tail -1 <<<"$listing")"
    echo "  ok: a wrong admin password is refused; the right one opens a session that lists bucket $bucket"

    if [ "$case" = "admin-edge" ]; then
      got="$(docker run --rm --network seaweedfs-net "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://${svc}:23646/metrics" 2>/dev/null || true)"
      [ "$got" = "200" ] || die "/metrics does not answer on the overlay (HTTP $got), so a 404 at the edge would prove nothing"
      got="$(a -o /dev/null "$abase/metrics")"
      [ "$(status <<<"$got")" = "404" ] || die "/metrics, which needs no login, is served through the edge (HTTP $(status <<<"$got"))"
      echo "  ok: /metrics answers on the overlay but not through the edge (404)"
      edge_assert_unrouted s3.e2e.test || die "the S3 API's host is routed although exposure.mode is none"
    fi

    # A stopped UI comes back, and S3 keeps serving from the same task meanwhile.
    task="$(docker service ps -q --filter desired-state=running "$svc" | sed -n 1p)"
    cid="$(docker ps -q --filter "label=com.docker.swarm.service.name=$svc" | sed -n 1p)"
    [ -n "$cid" ] || die "no local container for $svc"
    pid="$(docker exec "$cid" pgrep -f '^weed -logtostderr=true admin ' || true)"
    [ -n "$pid" ] || die "no weed admin process in the task"
    docker exec "$cid" kill "$pid"
    now=""
    for _ in $(seq 1 20); do
      sleep 3
      now="$(docker exec "$cid" pgrep -f '^weed -logtostderr=true admin ' || true)"
      [ -n "$now" ] && [ "$now" != "$pid" ] && [ "$(status <<<"$(a -o /dev/null "$abase/login")")" = "200" ] && break
      now=""
    done
    [ -n "$now" ] || die "weed admin did not come back after it was stopped"
    [ "$(docker service ps -q --filter desired-state=running "$svc" | sed -n 1p)" = "$task" ] && [ "$(code "$base/")" = "403" ] \
      || die "stopping weed admin took S3 down with it"
    echo "  ok: a stopped weed admin is restarted (pid $pid -> $now) while S3 keeps serving from the same task"

    # The password is in weed admin's environment alone: not weed server's (PID 1), no argv.
    # Read as seaweed, their own user: root in `docker exec` lacks the ptrace right to.
    env_of() { docker exec -u seaweed "$cid" cat "/proc/$1/environ" 2>/dev/null | tr '\000' '\n' || true; }
    grep -Fx "WEED_ADMIN_PASSWORD=$ADMIN_PASSWORD" <<<"$(env_of "$now")" >/dev/null \
      || die "weed admin's environment does not hold the password from the secret"
    pid1="$(env_of 1)"
    grep -F 'WEED_JWT_FILER_SIGNING_KEY=' <<<"$pid1" >/dev/null || die "weed server's (PID 1) environment is unreadable"
    if grep -F WEED_ADMIN_PASSWORD <<<"$pid1" >/dev/null; then die "weed server (PID 1) holds WEED_ADMIN_PASSWORD"; fi
    argv="$(docker exec "$cid" ps -o args)"
    grep -F -- '-dataDir=/data/admin -adminUser=admin' <<<"$argv" >/dev/null || die "ps in the task does not show weed admin's whole argv"
    if grep -F -- "$ADMIN_PASSWORD" <<<"$argv" >/dev/null; then die "the admin password is on an argv"; fi
    echo "  ok: the admin password is in weed admin's environment only — not weed server's, not on any argv"
    ;;
esac

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
if [ "$case" = "admin-published" ]; then
  pub="$(docker service inspect "$svc" --format '{{range .Endpoint.Ports}}{{.TargetPort}}:{{.PublishedPort}} {{end}}')"
  [ "$pub" = "23646:24646 " ] || die "the admin UI is not the one port published, as 24646 (got: $pub)"
  echo "  ok: the admin UI published on the routing mesh as 24646"
fi

echo "  seaweedfs [$case]: all checks passed"
