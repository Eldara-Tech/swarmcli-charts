#!/usr/bin/env bash
#
# e2e setup for the harbor chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It creates what the operator would (README, Prerequisites), with dummy values:
#   * the ten Swarm secrets, the secret key at exactly 16 bytes and the CSRF key at 32, and
#     the registry's htpasswd line hashed by httpd's htpasswd from the same password;
#   * a throwaway PostgreSQL, harbor-e2e-db, on an overlay of its own, waiting until it
#     accepts TCP connections (the e2e fixtures point database.* at it);
#   * for `oidc`, a stub OpenID provider on that overlay, the one network core shares with it:
#     a discovery document is all Harbor fetches before redirecting a login.
# ci/e2e-teardown.sh removes everything created here except the overlay.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

case="$3"
DBPW='e2e-db-password'
REGPW='e2e-registry-password'
dbnet=harbor-e2e-db-net

secret() {  # $1 name, content on stdin
  if docker secret inspect "$1" >/dev/null 2>&1; then cat >/dev/null; else docker secret create "$1" - >/dev/null; fi
}
printf '%s' "$DBPW" | secret harbor-db-password
printf '%s' 'e2e-admin-Passw0rd' | secret harbor-admin-password
printf '%s' 'e2ecoresecret016' | secret harbor-core-secret
printf '%s' 'e2ejobsecret0016' | secret harbor-jobservice-secret
printf '%s' 'e2eregistryhttp1' | secret harbor-registry-http-secret
printf '%s' 'e2ecsrfkey0123456789abcdef012345' | secret harbor-csrf-key
printf '%s' 'e2esecretkey0016' | secret harbor-secret-key
printf '%s' "$REGPW" | secret harbor-registry-password
if ! docker secret inspect harbor-token-key >/dev/null 2>&1; then
  # PKCS#1, the only format Harbor's token signer reads: OpenSSL 3 needs -traditional,
  # LibreSSL (macOS) writes it by default and knows no such flag.
  key="$(openssl genrsa -traditional 2048 2>/dev/null || openssl genrsa 2048 2>/dev/null)"
  case "$key" in "-----BEGIN RSA PRIVATE KEY-----"*) ;; *) echo "  FAIL: openssl wrote no PKCS#1 RSA key"; exit 1 ;; esac
  printf '%s\n' "$key" | secret harbor-token-key
fi
if ! docker secret inspect harbor-registry-htpasswd >/dev/null 2>&1; then
  line="$(docker run --rm httpd:2.4-alpine htpasswd -nbB harbor_registry_user "$REGPW" | sed -n 1p)"
  case "$line" in harbor_registry_user:\$2*) ;; *) echo "  FAIL: htpasswd produced no bcrypt line ('$line')"; exit 1 ;; esac
  printf '%s\n' "$line" | secret harbor-registry-htpasswd
fi
if [ "$case" = "oidc" ]; then
  printf '%s' 'e2e-oidc-client-secret' | secret harbor-oidc-client-secret
fi

docker network create --driver overlay --attachable "$dbnet" >/dev/null 2>&1 || true

docker service rm harbor-e2e-db >/dev/null 2>&1 || true
docker service create --detach --name harbor-e2e-db --network "$dbnet" \
  --env POSTGRES_DB=harbor --env POSTGRES_USER=harbor --env POSTGRES_PASSWORD="$DBPW" \
  postgres:18 >/dev/null
# pg_isready against 127.0.0.1 (TCP), not the unix socket: during first init the entrypoint
# runs a temporary server on the socket only, which would report ready while initdb runs.
ready=0
for _ in $(seq 1 60); do
  cid="$(docker ps -q -f label=com.docker.swarm.service.name=harbor-e2e-db | sed -n 1p)"
  if [ -n "$cid" ] && docker exec "$cid" pg_isready -h 127.0.0.1 -U harbor -d harbor >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 3
done
[ "$ready" = 1 ] || { echo "  FAIL: harbor-e2e-db never accepted connections"; docker service ps --no-trunc harbor-e2e-db; exit 1; }

if [ "$case" = "oidc" ]; then
  iss=http://harbor-e2e-idp:8080/realms/e2e
  discovery="{\"issuer\":\"$iss\",\"authorization_endpoint\":\"$iss/protocol/openid-connect/auth\",\"token_endpoint\":\"$iss/protocol/openid-connect/token\",\"jwks_uri\":\"$iss/protocol/openid-connect/certs.json\",\"response_types_supported\":[\"code\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"RS256\"]}"
  docker service rm harbor-e2e-idp >/dev/null 2>&1 || true
  docker service create --detach --name harbor-e2e-idp --network "$dbnet" --env DISCOVERY="$discovery" \
    busybox:1.37 sh -c 'd=/www/realms/e2e && mkdir -p "$d/.well-known" "$d/protocol/openid-connect" &&
      printf "%s" "$DISCOVERY" > "$d/.well-known/openid-configuration" &&
      printf "{\"keys\":[]}" > "$d/protocol/openid-connect/certs.json" &&
      printf ".well-known/openid-configuration:application/json\n.json:application/json\n" > /etc/httpd.conf &&
      exec httpd -f -v -p 8080 -h /www -c /etc/httpd.conf' >/dev/null
  got=""
  for _ in $(seq 1 40); do
    got="$(docker run --rm --network "$dbnet" curlimages/curl:latest -s -o /dev/null -w '%{http_code}' \
      --max-time 5 "$iss/.well-known/openid-configuration" 2>/dev/null || true)"
    [ "$got" = "200" ] && break
    sleep 3
  done
  [ "$got" = "200" ] || { echo "  FAIL: the stub OpenID provider never served its discovery document (last: '$got')"; exit 1; }
fi
