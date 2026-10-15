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
# S3 keeps serving from the same task. `oidc` stands up a stub identity provider and proves
# both grants work, through Bearer tokens and STS, and that what they do not grant is refused.
# `admin-oidc` runs the Enterprise image: the same login checks through the chart's
# forwarder, then the UI's OIDC button against a stub provider. `admin-oauth2` signs in through
# oauth2-proxy at a stub provider that issues real tokens: an allowed user reaches the UI's own
# password login and gets in with the password, an outsider is refused, and the UI cannot be
# reached around the proxy from the edge's overlay.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${SEAWEEDFS_E2E_CURL_IMAGE:-curlimages/curl:latest}"
GRPCURL_IMAGE="${SEAWEEDFS_E2E_GRPCURL_IMAGE:-fullstorydev/grpcurl:v1.9.3}"
KEY="${SEAWEEDFS_E2E_ACCESS_KEY:-e2e-access-key}"
SECRET="${SEAWEEDFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
ADMIN_PASSWORD="${SEAWEEDFS_E2E_ADMIN_PASSWORD:-e2e/admin+password0123}"
OIDC_CLIENT_SECRET="${SEAWEEDFS_E2E_OIDC_CLIENT_SECRET:-e2e/oidc+client-secret0123}"
SIG='aws:amz:us-east-1:s3'

svc="${release}_seaweedfs"
net=seaweedfs-net
# The alias the chart adds on seaweedfs-net, which Java clients need: their URI parser rejects
# the '_' in $svc. scripts/e2e-test.sh names releases [a-z0-9-] only, so it needs no mapping.
base="http://${release}-seaweedfs:8333"
route=()
buckets=""
case "$case" in
  buckets) buckets="runner-cache e2e.second-bucket" ;;
  traefik) buckets="runner-cache" ;;
  ephemeral) buckets="scratch" ;;
  oidc) buckets="idp runner-cache reports" ;;
  admin-oidc) buckets="idp" ;;
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
# the admin's worker gRPC port (23646 + 10000) as well; on the Enterprise image also the
# UI's own port (23646 + 1), which only the forwarder may reach. With metrics on, the
# monitoring overlay is checked as well: everything Prometheus shares it with reaches the
# service there, and must find S3 authenticated and the internal APIs shut.
if [ "$case" != "edge" ]; then
  overlays=seaweedfs-net
  ports="9333 8888 8080"
  case "$case" in
    admin-edge) overlays="seaweedfs-net traefik-public"; ports="$ports 33646" ;;
    admin-oidc) ports="$ports 33646 23647" ;;
    admin-*) ports="$ports 33646" ;;
    metrics) overlays="seaweedfs-net monitoring" ;;
  esac
  # curl exits 7 only when the connection is refused: a listening gRPC port gives no HTTP
  # code either, so the code alone cannot tell the two apart.
  refused() { local rc=0; docker run --rm --network "$1" "$CURL_IMAGE" -s -o /dev/null --max-time 5 "http://${svc}:$2/" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
  for n in $overlays; do
    got="$(docker run --rm --network "$n" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
      --max-time 5 "http://${svc}:8333/" 2>/dev/null || true)"
    [ "$got" = "403" ] || die "anonymous GET of S3 from $n returned '$got', expected 403"
    for p in $ports; do
      rc="$(refused "$n" "$p")"
      [ "$rc" = "7" ] || die "port $p (an unauthenticated master/filer/volume API or the admin's worker gRPC) did not refuse a connection from $n (curl exit $rc)"
    done
  done
  rc="$(refused seaweedfs-net 18333)"
  [ "$rc" != "7" ] || die "curl reports the S3 gRPC port, which listens on every interface, as refused too — the check above proves nothing"
  echo "  ok: from $overlays, S3 refuses anonymous requests and ports $ports refuse connections (the listening S3 gRPC port does not: curl exit $rc)"

  for n in $overlays; do

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
    login() { local pw="$1"; shift; a -o /dev/null "$@" -H "Cookie: $jar" --data-urlencode "csrf_token=$csrf" \
      --data-urlencode username=admin --data-urlencode "password=$pw" "$abase/login"; }
    got="$(login wrong-password)"
    [ "$(status <<<"$got")" = "303" ] && grep -F 'error=Invalid credentials' <<<"$(header Location <<<"$got")" >/dev/null \
      || die "a wrong admin password was not refused (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
    # As a browser submits the login form; the wrong-password POST above carried no such header.
    got="$(login "$ADMIN_PASSWORD" -H 'Sec-Fetch-Site: same-origin')"
    [ "$(status <<<"$got")" = "303" ] && [ "$(header Location <<<"$got")" = "/admin" ] \
      || die "the admin password was refused (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
    sess="$(session <<<"$got")"
    listing="$(a -H "Cookie: $sess" "$abase/api/s3/buckets")"
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

      # The edge refuses a write a browser marks as from another site; a same-origin one passes.
      mk() { a -o /dev/null -X POST -H "Cookie: $sess" -H 'Content-Type: application/json' -H "Sec-Fetch-Site: $1" \
        --data "{\"username\":\"$2\",\"actions\":[\"Admin\"]}" "$abase/api/users"; }
      # Names unique to this run: the store may outlive a run, and a name it already has
      # would fail with 500 rather than prove anything.
      u="e2e-write-$$-$(date +%s)"
      got="$(mk same-site "$u-site")"
      [ "$(status <<<"$got")" = "404" ] || die "a same-site POST /api/users was not refused at the edge (HTTP $(status <<<"$got"))"
      got="$(mk same-origin "$u-origin")"
      [ "$(status <<<"$got")" = "201" ] || die "a same-origin POST /api/users did not create the user (HTTP $(status <<<"$got"))"
      users="$(a -H "Cookie: $sess" "$abase/api/users")"
      grep -F "\"username\":\"$u-origin\"" <<<"$users" >/dev/null || die "the same-origin user is not listed: $(tail -1 <<<"$users")"
      if grep -F "$u-site" <<<"$users" >/dev/null; then die "the same-site POST created its user anyway"; fi
      echo "  ok: a write marked Sec-Fetch-Site: same-site is refused at the edge (404, no user); same-origin creates one (201)"

      # The edge sandboxes the stored-file routes only, an image opened inline included.
      obj="e2e image $u"
      got="$(printf '%s' "$obj" | signed_code -X PUT -H 'Content-Type: image/png' --data-binary @- "$base/$bucket/$u.png")"
      [ "$got" = "200" ] || die "signed PUT of the image returned '$got'"
      got="$(a -H "Cookie: $sess" -H 'Sec-Fetch-Site: cross-site' "$abase/api/files/download?path=/buckets/$bucket/$u.png&inline=true")"
      [ "$(status <<<"$got")" = "200" ] && [ "$(sed '1,/^$/d' <<<"$got")" = "$obj" ] \
        || die "the image does not download through the edge (HTTP $(status <<<"$got"))"
      [ "$(header Content-Disposition <<<"$got" | cut -d';' -f1)" = "inline" ] \
        || die "the image is not served inline ('$(header Content-Disposition <<<"$got")'), so this check proves nothing"
      [ "$(header Content-Security-Policy <<<"$got")" = "sandbox" ] \
        || die "the inline image carries no 'Content-Security-Policy: sandbox' (got '$(header Content-Security-Policy <<<"$got")')"
      got="$(a -o /dev/null -H "Cookie: $sess" "$abase/admin")"
      [ "$(status <<<"$got")" = "200" ] && [ -z "$(header Content-Security-Policy <<<"$got")" ] \
        || die "the dashboard is not served unsandboxed (HTTP $(status <<<"$got"), CSP '$(header Content-Security-Policy <<<"$got")')"
      echo "  ok: an uploaded image downloads inline through the edge under 'Content-Security-Policy: sandbox'; the dashboard has no CSP"

      # Traefik matches the escaped path and weed admin the decoded one, so a route spelled
      # with %2F would miss the sandboxed router and still reach the file: the edge refuses it.
      enc="/api%2Ffiles/download?path=/buckets/$bucket/$u.png&inline=true"
      got="$(docker run --rm --network seaweedfs-net "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Cookie: $sess" "http://${svc}:23646$enc" 2>/dev/null || true)"
      [ "$got" = "200" ] || die "weed admin does not serve the file at a path with %2F on the overlay (HTTP $got), so a 404 at the edge would prove nothing"
      got="$(a -o /dev/null -H "Cookie: $sess" "$abase$enc")"
      [ "$(status <<<"$got")" = "404" ] || die "a path with an encoded slash reached the UI through the edge (HTTP $(status <<<"$got"))"
      echo "  ok: weed admin serves the file at /api%2Ffiles/download on the overlay, and the edge refuses that path (404)"
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
    [ "$(status <<<"$(a -o /dev/null -H "Cookie: $sess" "$abase/api/s3/buckets")")" = "200" ] \
      || die "a restart of weed admin alone logged its session out"
    echo "  ok: a stopped weed admin is restarted (pid $pid -> $now), its session intact, while S3 keeps serving from the same task"

    # The password is in weed admin's environment alone: not weed server's (PID 1), no argv.
    # Read as seaweed, their own user: root in `docker exec` lacks the ptrace right to.
    env_of() { docker exec -u seaweed "$cid" cat "/proc/$1/environ" 2>/dev/null | tr '\000' '\n' || true; }
    aenv="$(env_of "$now")"
    grep -Fx "WEED_ADMIN_PASSWORD=$ADMIN_PASSWORD" <<<"$aenv" >/dev/null \
      || die "weed admin's environment does not hold the password from the secret"
    grep -Fx 'GODEBUG=fips140=on' <<<"$aenv" >/dev/null || die "weed admin does not run with GODEBUG=fips140=on, as weed server does"
    pid1="$(env_of 1)"
    grep -F 'WEED_JWT_FILER_SIGNING_KEY=' <<<"$pid1" >/dev/null || die "weed server's (PID 1) environment is unreadable"
    if grep -F WEED_ADMIN_PASSWORD <<<"$pid1" >/dev/null; then die "weed server (PID 1) holds WEED_ADMIN_PASSWORD"; fi
    argv="$(docker exec "$cid" ps -o args)"
    grep -F -- '-dataDir=/data/admin -adminUser=admin' <<<"$argv" >/dev/null || die "ps in the task does not show weed admin's whole argv"
    if grep -F -- "$ADMIN_PASSWORD" <<<"$argv" >/dev/null; then die "the admin password is on an argv"; fi
    echo "  ok: the admin password is in weed admin's environment only — not weed server's, not on any argv"

    # admin.oidc: the store serves the provider's discovery document, as in the `oidc` case.
    # weed admin reads it once, at start, so it is restarted once the document is in place;
    # then the login page offers OIDC, and its button sends the browser to the provider with
    # the fixture's client and callback.
    if [ "$case" = "admin-oidc" ]; then
      iss='http://127.0.0.1:8888/buckets/idp'
      if grep -F 'href="/login/oidc"' <<<"$(a "$abase/login")" >/dev/null; then
        die "the login page offers OIDC before the provider's discovery document exists, so the check below would prove nothing"
      fi
      got="$(printf '{"issuer":"%s","authorization_endpoint":"%s/authorize","token_endpoint":"%s/token","jwks_uri":"%s/jwks","response_types_supported":["code"],"subject_types_supported":["public"],"id_token_signing_alg_values_supported":["RS256"]}' \
        "$iss" "$iss" "$iss" "$iss" | signed_code -X PUT --data-binary @- "$base/idp/.well-known/openid-configuration")"
      [ "$got" = "200" ] || die "uploading the stub discovery document returned '$got'"
      docker exec "$cid" kill "$now"
      new=""
      for _ in $(seq 1 20); do
        sleep 3
        new="$(docker exec "$cid" pgrep -f '^weed -logtostderr=true admin ' || true)"
        [ -n "$new" ] && [ "$new" != "$now" ] && grep -F 'href="/login/oidc"' <<<"$(a "$abase/login")" >/dev/null && break
        new=""
      done
      [ -n "$new" ] || die "with the discovery document in place, a restarted weed admin still offers no OIDC login"
      got="$(a -o /dev/null "$abase/login/oidc")"
      loc="$(header Location <<<"$got")"
      [ "$(status <<<"$got")" = "303" ] && [ "${loc%%\?*}" = "$iss/authorize" ] \
        && grep -F 'client_id=seaweedfs-admin&' <<<"$loc&" >/dev/null \
        && grep -F 'redirect_uri=https%3A%2F%2Fseaweedfs-admin.example.com%2Flogin%2Foidc%2Fcallback&' <<<"$loc&" >/dev/null \
        || die "the OIDC button does not send the browser to the provider with the client and callback (HTTP $(status <<<"$got"), Location '$loc')"
      echo "  ok: the login page offers OIDC once the provider is up; the button sends the browser to $iss/authorize with the client and the browserUrl callback"
      grep -Fx "WEED_ADMIN_OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET" <<<"$(env_of "$new")" >/dev/null \
        || die "weed admin's environment does not hold the OIDC client secret from the secret"
      if grep -F WEED_ADMIN_OIDC_CLIENT_SECRET <<<"$(env_of 1)" >/dev/null; then die "weed server (PID 1) holds WEED_ADMIN_OIDC_CLIENT_SECRET"; fi
      if grep -F -- "$OIDC_CLIENT_SECRET" <<<"$(docker exec "$cid" ps -o args)" >/dev/null; then die "the OIDC client secret is on an argv"; fi
      echo "  ok: the OIDC client secret is in weed admin's environment only — not weed server's, not on any argv"
    fi

    # A new task deletes the session key, so a redeploy — a password change included — logs
    # everyone out: the old cookie no longer decodes and the dashboard sends it to /login.
    # That redirect comes from weed admin itself, so it is up and refusing, not down.
    if [ "$case" = "admin-published" ]; then
      [ "$(status <<<"$(a -o /dev/null -H "Cookie: $sess" "$abase/admin")")" = "200" ] \
        || die "the admin session does not open the dashboard before the task restart"
      docker service update --force --detach "$svc" >/dev/null
      got=""
      for _ in $(seq 1 60); do
        sleep 3
        [ "$(docker service ps -q --filter desired-state=running "$svc" | sed -n 1p)" != "$task" ] || continue
        got="$(a -o /dev/null -H "Cookie: $sess" "$abase/admin")"
        [ -n "$(status <<<"$got")" ] && break
      done
      [ "$(status <<<"$got")" = "307" ] && [ "$(header Location <<<"$got" | cut -d'?' -f1)" = "/login" ] \
        || die "after a task restart the old admin session got HTTP $(status <<<"$got") ('$(header Location <<<"$got")'), expected a redirect to /login"
      echo "  ok: after a task restart the old admin session is sent back to /login"
    fi
    ;;
esac

# ── admin.oauth2: a sign-in at the stub provider, through the proxy ───────────────────
# The e2e edge has no TLS, which admin.oauth2 requires, so requests go to the proxy on
# traefik-public carrying the Host and X-Forwarded-Proto that Traefik would set. Its cookies
# are Secure and the hop is plain HTTP, so they are carried by hand. The browser's leg to
# the stub takes -k: what it proves is the proxy's trust in the stub, which the proxy checks.
if [ "$case" = "admin-oauth2" ]; then
  proxy="http://${release}_oauth2-proxy:4180"
  o() { docker run --rm --network traefik-public "$CURL_IMAGE" -sS --max-time 15 -D - \
    -H 'Host: admin.e2e.test' -H 'X-Forwarded-Proto: https' "$@" 2>/dev/null | tr -d '\r' || true; }
  cookie() { grep -i '^set-cookie:' | sed -n "s/^[^:]*: *\($1=[^;]*\).*/\1/p" | sed -n 1p; }

  # The UI joins neither traefik-public nor any network but its own and admin-oauth2.
  rc=0
  docker run --rm --network traefik-public "$CURL_IMAGE" -s -o /dev/null --max-time 5 "http://${svc}:23646/" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "6" ] || [ "$rc" = "7" ] || die "the UI answered on traefik-public around the proxy (curl exit $rc)"
  got=""
  for _ in $(seq 1 30); do
    got="$(o -o /dev/null "$proxy/")"
    [ "$(status <<<"$got")" = "403" ] && break
    sleep 3
  done
  [ "$(status <<<"$got")" = "403" ] || die "an anonymous request to the proxy was not refused with its sign-in page (HTTP $(status <<<"$got"))"
  echo "  ok: the UI is unreachable on traefik-public, and the proxy refuses an anonymous request there (403)"

  # One sign-in as stub user $1, the way a browser follows it; prints the proxy's session
  # cookie, or nothing when the proxy refused the user.
  signin() {
    local start loc csrf back
    start="$(o -o /dev/null "$proxy/oauth2/start?rd=%2F")"
    loc="$(header Location <<<"$start")"
    csrf="$(cookie _oauth2_proxy_csrf <<<"$start")"
    [ "$(status <<<"$start")" = "302" ] && [ "${loc%%\?*}" = "https://seaweedfs-e2e-oidc:8443/authorize" ] && [ -n "$csrf" ] \
      || die "the proxy's sign-in did not send the browser to the stub's /authorize (HTTP $(status <<<"$start"), Location '$loc')"
    for want in client_id=seaweedfs-admin redirect_uri=https%3A%2F%2Fadmin.e2e.test%2Foauth2%2Fcallback \
                code_challenge_method=S256 scope=openid+email+profile; do
      grep -F "&$want&" <<<"&${loc#*\?}&" >/dev/null || die "the sign-in redirect lacks $want: $loc"
    done
    back="$(docker run --rm --network traefik-public "$CURL_IMAGE" -sSk --max-time 15 -D - -o /dev/null "$loc&user=$1" 2>/dev/null \
      | tr -d '\r' | header Location)"
    [ "${back%%\?*}" = "https://admin.e2e.test/oauth2/callback" ] || die "the stub did not send $1 back to the callback: '$back'"
    o -o /dev/null -H "Cookie: $csrf" "$proxy/oauth2/callback?${back#*\?}" | cookie _oauth2_proxy
  }

  [ -z "$(signin outsider)" ] || die "a user in no allowed group got a session"
  sess="$(signin admin)"
  [ -n "$sess" ] || die "a member of storage-admins got no session: the code was not redeemed (the client secret or the CA did not reach the proxy?)"
  echo "  ok: the sign-in goes to the stub with the client, the callback, PKCE S256 and the scope; an outsider is refused, a member of storage-admins gets a session"

  # Signed in, the proxy hands over to the UI, which still asks for its password.
  got="$(o -o /dev/null -H "Cookie: $sess" "$proxy/")"
  [ "$(status <<<"$got")" = "307" ] && [ "$(header Location <<<"$got")" = "/login" ] \
    || die "a signed-in request was not handed to the UI's own login (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
  page="$(o -H "Cookie: $sess" "$proxy/login")"
  ptok="$(sed -n 's/.*name="csrf_token" value="\([0-9a-f]*\)".*/\1/p' <<<"$page" | sed -n 1p)"
  ajar="$(session <<<"$page")"
  [ -n "$ptok" ] && [ -n "$ajar" ] || die "the UI's login page did not come through the proxy"
  got="$(o -o /dev/null -H "Cookie: $sess; $ajar" -H 'Sec-Fetch-Site: same-origin' --data-urlencode "csrf_token=$ptok" \
    --data-urlencode username=admin --data-urlencode "password=$ADMIN_PASSWORD" "$proxy/login")"
  [ "$(status <<<"$got")" = "303" ] && [ "$(header Location <<<"$got")" = "/admin" ] \
    || die "the admin password was refused through the proxy (HTTP $(status <<<"$got"), Location '$(header Location <<<"$got")')"
  asess="$(session <<<"$got")"
  listing="$(o -H "Cookie: $sess; $asess" "$proxy/api/s3/buckets")"
  [ "$(status <<<"$listing")" = "200" ] || die "the two sessions do not list the buckets through the proxy (HTTP $(status <<<"$listing"))"
  [ "$(status <<<"$(o -o /dev/null -H "Cookie: $asess" "$proxy/api/s3/buckets")")" = "403" ] \
    || die "the UI's session alone passed the proxy, without a sign-in"
  echo "  ok: through the proxy a member of storage-admins reaches the UI's password login, logs in, and lists buckets; the UI's session alone does not pass"
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

  # The alert rules the chart ships for operators to load (monitoring/), checked here
  # because nothing deploys them: their logic, under the promtool of a pinned Prometheus.
  # The image follows prometheus-stack's appVersion, which Renovate keeps current.
  chart="$(cd "$dir" && pwd)"
  prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart/../prometheus-stack/Chart.yaml")"
  promtool_image="${SEAWEEDFS_E2E_PROMTOOL_IMAGE:-prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}}"
  out="$(docker run --rm --entrypoint promtool -v "$chart:/chart:ro" "$promtool_image" \
    test rules /chart/ci/seaweedfs-rules-test.yml 2>&1)" \
    || die "promtool test rules fails on monitoring/seaweedfs-rules.yml: $out"
  echo "  ok: the alert rules pass promtool"
  metrics_ok="$metrics_ok, alert rules pass promtool"
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

# ── oidc: a stub identity provider, then each grant and each refusal ──────────────────
# The provider is a key pair made for this run plus the store's own filer: a discovery
# document and the JWKS go into the `idp` bucket, which the filer serves on the loopback
# address the fixture names as issuer, and the tokens are signed here with the key. The JWKS
# sits at a path only the discovery document names, so a working token proves discovery.
# SeaweedFS carries on without OIDC when its config is unusable, so every refusal below is
# paired with a grant that works.
if [ "$case" = "oidc" ]; then
  iss='http://127.0.0.1:8888/buckets/idp'
  role='arn:aws:iam::role/oidc'
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  openssl genrsa -out "$tmp/idp.key" 2048 2>/dev/null
  mod="$(openssl rsa -in "$tmp/idp.key" -noout -modulus | sed 's/^Modulus=//')"
  # shellcheck disable=SC2059 # the format IS the data: the modulus as \xHH escapes
  n="$(printf "$(sed 's/../\\x&/g' <<<"$mod")" | b64url)"
  got="$(printf '{"issuer":"%s","jwks_uri":"%s/keys/e2e-jwks.json"}' "$iss" "$iss" \
    | signed_code -X PUT --data-binary @- "$base/idp/.well-known/openid-configuration")"
  [ "$got" = "200" ] || die "uploading the stub discovery document returned '$got'"
  got="$(printf '{"keys":[{"kty":"RSA","kid":"e2e","use":"sig","alg":"RS256","n":"%s","e":"AQAB"}]}' "$n" \
    | signed_code -X PUT --data-binary @- "$base/idp/keys/e2e-jwks.json")"
  [ "$got" = "200" ] || die "uploading the stub JWKS returned '$got'"
  # token <aud as JSON> <azp> <groups as a JSON array>
  token() {
    local h p now
    now="$(date +%s)"
    h="$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"e2e"}' | b64url)"
    p="$(printf '{"iss":"%s","aud":%s,"azp":"%s","sub":"e2e-user","groups":%s,"iat":%s,"exp":%s}' \
      "$iss" "$1" "$2" "$3" "$now" "$((now + 900))" | b64url)"
    printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$tmp/idp.key" | b64url)"
  }
  # The writer's token has Keycloak's access-token shape: aud ["account"], the client in azp.
  writer="$(token '["account"]' seaweedfs-s3 '["ci-cache"]')"
  reader="$(token '"seaweedfs-s3"' seaweedfs-s3 '["auditors"]')"
  nogroup="$(token '"seaweedfs-s3"' seaweedfs-s3 '[]')"
  wrongaud="$(token '"other"' other '["ci-cache"]')"
  bearer() { local t="$1"; shift; code -H "Authorization: Bearer $t" "$@"; }
  obj="$base/runner-cache/oidc/object.txt"

  # Bearer. The first request also makes SeaweedFS fetch the JWKS, so it gets a few tries.
  got=""
  for _ in $(seq 1 10); do
    got="$(printf '%s' "$payload" | bearer "$writer" -X PUT --data-binary @- "$obj")"
    [ "$got" = "200" ] && break
    sleep 2
  done
  [ "$got" = "200" ] || die "a ci-cache token's PUT to runner-cache returned '$got', expected 200 (is the IAM file loaded?)"
  back="$(c -H "Authorization: Bearer $writer" "$obj")" || die "a ci-cache token's GET failed"
  [ "$back" = "$payload" ] || die "the ci-cache token read back '$back', expected '$payload'"
  got="$(bearer "$reader" "$obj")"
  [ "$got" = "200" ] || die "an auditors token's GET returned '$got', expected 200 (readonly on every bucket)"
  echo "  ok: Bearer grants work: ci-cache reads and writes runner-cache, auditors read it"
  got="$(printf x | bearer "$reader" -X PUT --data-binary @- "$obj")"
  [ "$got" = "403" ] || die "an auditors token's PUT returned '$got', expected 403 (its grant is readonly)"
  got="$(printf x | bearer "$writer" -X PUT --data-binary @- "$base/reports/oidc.txt")"
  [ "$got" = "403" ] || die "a ci-cache token's PUT to reports returned '$got', expected 403 (its grant is runner-cache only)"
  got="$(printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::runner-cache/*"}]}' \
    | bearer "$writer" -X PUT --data-binary @- "$base/runner-cache?policy")"
  [ "$got" = "403" ] || die "a ci-cache token's PutBucketPolicy returned '$got', expected 403"
  got="$(bearer "$nogroup" "$obj")"
  [ "$got" = "403" ] || die "a token in no granted group got '$got', expected 403"
  got="$(bearer "$wrongaud" "$obj")"
  [ "$got" = "403" ] || die "a token for another client got '$got', expected 403"
  echo "  ok: Bearer refusals: readonly PUT, other bucket, PutBucketPolicy, no granted group, other client (403)"
  # The embedded IAM API would answer ListAccessKeys with every identity's key id, the
  # admin's included; with it off the request is an unknown action.
  no_key_list() {
    grep -F '<Code>InvalidAction</Code>' <<<"$2" >/dev/null && ! grep -F -e "$KEY" -e 'ListAccessKeysResponse' <<<"$2" >/dev/null \
      || die "ListAccessKeys with $1 was not refused as an unknown action: ${2:-<empty>}"
  }
  for who in writer reader; do
    if [ "$who" = "writer" ]; then t="$writer"; else t="$reader"; fi
    no_key_list "the $who's Bearer token" "$(c -X POST -H "Authorization: Bearer $t" --data Action=ListAccessKeys "$base/" 2>/dev/null || true)"
  done
  echo "  ok: Bearer tokens cannot list access keys (InvalidAction, no admin key id)"

  # STS. The caller names the role, so the trust policy is all that stands in the way.
  sts() {
    c -X POST "$base/" --data-urlencode Action=AssumeRoleWithWebIdentity --data-urlencode Version=2011-06-15 \
      --data-urlencode "RoleArn=$role" --data-urlencode RoleSessionName=e2e --data-urlencode "WebIdentityToken=$1" 2>/dev/null || true
  }
  field() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" <<<"$2"; }
  out="$(sts "$nogroup")"
  grep -F '<Code>AccessDenied</Code>' <<<"$out" >/dev/null && [ -z "$(field AccessKeyId "$out")" ] \
    || die "a token in no granted group was not refused the role: $out"
  echo "  ok: STS refuses the role to a token in no granted group (AccessDenied)"
  for who in writer reader; do
    if [ "$who" = "writer" ]; then t="$writer"; want=200; else t="$reader"; want=403; fi
    out="$(sts "$t")"
    ak="$(field AccessKeyId "$out")"; sk="$(field SecretAccessKey "$out")"; st="$(field SessionToken "$out")"
    [ -n "$ak" ] && [ -n "$sk" ] && [ -n "$st" ] || die "STS gave the $who token no credentials: $out"
    got="$(code --aws-sigv4 "$SIG" --user "$ak:$sk" -H "X-Amz-Security-Token: $st" "$obj")"
    [ "$got" = "200" ] || die "the $who's STS credentials got '$got' reading runner-cache, expected 200"
    got="$(printf x | code --aws-sigv4 "$SIG" --user "$ak:$sk" -H "X-Amz-Security-Token: $st" -X PUT --data-binary @- "$base/runner-cache/oidc/sts.txt")"
    [ "$got" = "$want" ] || die "the $who's STS credentials got '$got' writing runner-cache, expected $want"
    no_key_list "the $who's STS credentials" "$(c -X POST --aws-sigv4 "aws:amz:us-east-1:iam" --user "$ak:$sk" -H "X-Amz-Security-Token: $st" \
      --data Action=ListAccessKeys "$base/" 2>/dev/null || true)"
  done
  echo "  ok: STS credentials carry each token's grants: ci-cache writes, auditors only read, neither lists keys"
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

echo "  seaweedfs [$case]: all checks passed${metrics_ok}"
