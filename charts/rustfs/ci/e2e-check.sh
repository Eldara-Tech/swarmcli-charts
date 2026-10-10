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
#   * the console listener exists exactly when console.enabled;
#   * `console-edge`: the console is routed through the traefik chart (its UI, the browser
#     redirect to it, and the signed S3 API it also serves) while the S3 host is not;
#   * `oidc`: the stub provider was discovered, the login redirects to its authorization
#     endpoint with the chart's client id and callback (a spoofed Host cannot move it),
#     and the client secret reached the server's environment but not `docker inspect`;
#   * the raised open-file limit reached the process, and its log reaches `docker service
#     logs` (both are chart settings a render cannot prove the daemon applied).
#
# `buckets` additionally forces a task restart and proves the object survives it and the
# bootstrap passes again over the buckets that now exist (RustFS answers 200 for a bucket
# you already own, as S3 does in us-east-1).
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
  published|console-edge|oidc) console=1 ;;
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

# ── what the chart sets on the process ────────────────────────────────────────────────
cid="$(docker ps -q -f "label=com.docker.swarm.service.name=$svc" | sed -n 1p)"
[ -n "$cid" ] || die "no running container of $svc on this node (the e2e swarm is single-node)"
nofile="$(docker exec "$cid" sh -c 'ulimit -n')"
[ "$nofile" = "65536" ] || die "the open-file limit inside the task is $nofile, expected the chart's 65536"
logs="$(docker service logs --raw "$svc" 2>&1 || true)"
grep -F '"level":' <<<"$logs" >/dev/null || die "no server log line in docker service logs; RustFS is still logging to a file"
echo "  ok: nofile 65536 inside the task, server log on docker service logs"

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

# ── console-edge: the console through the edge, the S3 API not ───────────────────────
if [ "$case" = "console-edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  chost=rustfs-console.e2e.test
  edge_assert_routed "$chost" /rustfs/console/ 200 || die "the console UI is not routed on $chost"
  got="$(docker run --rm --network "$EDGE_NETWORK" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code} %{redirect_url}' \
    --max-time 10 -A 'Mozilla/5.0' --connect-to "$chost:80:${EDGE_TARGET}:80" "http://$chost/" 2>/dev/null || true)"
  [ "$got" = "302 http://$chost/rustfs/console/" ] || die "a browser opening http://$chost/ got '$got', expected a 302 to /rustfs/console/"
  echo "  ok: a browser opening http://$chost/ is redirected to /rustfs/console/"
  # The console host is the whole server: a signed ListBuckets through it succeeds.
  got="$(docker run --rm --network "$EDGE_NETWORK" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 15 \
    --connect-to "$chost:80:${EDGE_TARGET}:80" --aws-sigv4 "$SIG" --user "$KEY:$SECRET" "http://$chost/" 2>/dev/null || true)"
  [ "$got" = "200" ] || die "a signed ListBuckets through $chost returned '$got', expected 200"
  echo "  ok: the console host also answers the signed S3 API"
  edge_assert_unrouted s3.example.com || die "ingress.host is routed although exposure.mode is none"
fi

# ── oidc: the stub provider is loaded and the login goes to it ───────────────────────
if [ "$case" = "oidc" ]; then
  api="http://${svc}:9001/rustfs/admin/v3/oidc"
  got="$(c "$api/providers" 2>/dev/null || true)"
  grep -F '"provider_id":"default"' <<<"$got" >/dev/null \
    || die "the stub provider was not loaded (providers: ${got:-<empty>}); was it reachable at start?"
  echo "  ok: the provider was discovered at start"
  auth='http://rustfs-e2e-idp:8080/realms/e2e/protocol/openid-connect/auth?'
  cb='redirect_uri=https%3A%2F%2Frustfs-console.e2e.test%2Frustfs%2Fadmin%2Fv3%2Foidc%2Fcallback%2Fdefault'
  for host in "${svc}:9001" evil.example; do
    loc="$(c -o /dev/null -w '%{redirect_url}' -H "Host: $host" -H 'X-Forwarded-Proto: http' "$api/authorize/default" 2>/dev/null || true)"
    case "$loc" in "$auth"*) ;; *) die "the login (Host: $host) redirected to '${loc:-<nothing>}', not to the stub's authorization endpoint" ;; esac
    grep -E '[?&]client_id=rustfs-e2e(&|$)' <<<"$loc" >/dev/null || die "the login does not carry client_id=rustfs-e2e: $loc"
    grep -E "[?&]$cb(&|\$)" <<<"$loc" >/dev/null || die "the login (Host: $host) does not carry the callback on console.ingress.host: $loc"
  done
  echo "  ok: the login redirects to the stub with client_id rustfs-e2e and the https://rustfs-console.e2e.test callback, whatever the Host header says"
  # Compared against the secret the task mounts, not a known value: setup keeps a secret left
  # over from an earlier run, which would make a check against the default pass vacuously.
  oidc_secret="$(docker exec "$cid" cat /run/secrets/rustfs-oidc-client-secret 2>/dev/null || true)"
  [ -n "$oidc_secret" ] || die "the task mounts no (or an empty) /run/secrets/rustfs-oidc-client-secret"
  docker exec "$cid" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -Fx "RUSTFS_IDENTITY_OPENID_CLIENT_SECRET=$(cat /run/secrets/rustfs-oidc-client-secret)" >/dev/null' \
    || die "the OIDC client secret did not reach the server's environment"
  if { docker service inspect "$svc"; docker inspect "$cid"; } | grep -F -- "$oidc_secret" >/dev/null; then
    die "the OIDC client secret is visible in docker inspect"
  fi
  echo "  ok: the client secret is in the server's environment and not in docker inspect of the service or task"
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
  # Both tasks' logs are in `docker service logs`: every bucket must be reported ready
  # twice, once by each, and the second time it already existed.
  logs=""
  for _ in $(seq 1 20); do
    logs="$(docker service logs --raw "$svc" 2>&1 || true)"
    done_all=1
    for b in $buckets; do
      [ "$(grep -cE "^bucket $b: ready \(HTTP (200|409)\)$" <<<"$logs" || true)" -ge 2 ] || done_all=""
    done
    [ -n "$done_all" ] && break
    sleep 3
  done
  [ -n "$done_all" ] || die "after the restart the bootstrap did not report every bucket ready again: $(grep '^bucket ' <<<"$logs" | tr '\n' ';')"
  echo "  ok: forced restart kept the object; the bootstrap passed again over the existing buckets"
fi

# ── published: the ports are on the routing mesh ──────────────────────────────────────
if [ "$case" = "published" ]; then
  pub="$(docker service inspect "$svc" --format '{{range .Endpoint.Ports}}{{.TargetPort}}:{{.PublishedPort}} {{end}}')"
  grep -F '9000:19000' <<<"$pub" >/dev/null || die "the S3 port is not published as 19000 (got: $pub)"
  grep -F '9001:19001' <<<"$pub" >/dev/null || die "the console port is not published as 19001 (got: $pub)"
  echo "  ok: S3 and console published on the routing mesh as 19000 / 19001"
fi

echo "  rustfs [$case]: all checks passed"
