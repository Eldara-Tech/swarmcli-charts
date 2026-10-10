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
# bootstrap treats the buckets that now exist as done. `oidc` stands up a stub identity
# provider and proves both grants work, through Bearer tokens and STS, and that what they do
# not grant is refused.
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
  oidc) buckets="idp runner-cache reports" ;;
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
# service is reachable too, but one network proves the bind address.
if [ "$case" != "edge" ]; then
  for p in 9333 8888 8080; do
    got="$(docker run --rm --network seaweedfs-net "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' \
      --max-time 5 "http://${svc}:$p/" 2>/dev/null || true)"
    [ "$got" = "000" ] || die "port $p (unauthenticated master/filer/volume API) answered HTTP $got from the overlay"
  done
  echo "  ok: master/filer/volume ports refuse connections from the overlay"

  out="$(docker run --rm --network seaweedfs-net "$GRPCURL_IMAGE" -plaintext -max-time 10 \
    -d '{"identity":{"name":"e2e-intruder","credentials":[{"accessKey":"intruderkey","secretKey":"intrudersecret"}],"actions":["Admin"]}}' \
    "${svc}:18333" messaging_pb.SeaweedS3IamCache/PutIdentity 2>&1 || true)"
  grep -F 'Unauthenticated' <<<"$out" >/dev/null \
    || die "the S3 gRPC port did not refuse an unsigned PutIdentity: $out"
  got="$(code --aws-sigv4 "$SIG" --user "intruderkey:intrudersecret" "$base/")"
  [ "$got" = "403" ] || die "the injected identity was accepted (HTTP $got)"
  echo "  ok: gRPC PutIdentity without the signing key refused, and the identity does not work"
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

echo "  seaweedfs [$case]: all checks passed"
