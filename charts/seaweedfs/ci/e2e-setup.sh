#!/usr/bin/env bash
#
# e2e setup for the seaweedfs chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but does not create: the two credential secrets,
# the admin password and the admin's OIDC client secret, the data node label, the client overlay ci/e2e-check.sh attaches
# to, the bind-mount directory, for `edge`/`admin-edge` the traefik chart as a real edge,
# and for `admin-oauth2` oauth2-proxy's secrets and a stub identity provider. ci/e2e-teardown.sh
# removes everything created here except the overlays.
#
# INVARIANT: the key pair, the admin password and the OIDC client secret below are the
# ones ci/e2e-check.sh signs, logs in and compares with. Each carries a `/` and a `+`, as a
# real base64 secret does.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

dir="$2"
case="$3"

SEAWEEDFS_E2E_ACCESS_KEY="${SEAWEEDFS_E2E_ACCESS_KEY:-e2e-access-key}"
SEAWEEDFS_E2E_SECRET_KEY="${SEAWEEDFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
SEAWEEDFS_E2E_ADMIN_PASSWORD="${SEAWEEDFS_E2E_ADMIN_PASSWORD:-e2e/admin+password0123}"
SEAWEEDFS_E2E_OIDC_CLIENT_SECRET="${SEAWEEDFS_E2E_OIDC_CLIENT_SECRET:-e2e/oidc+client-secret0123}"
SEAWEEDFS_E2E_OAUTH2_CLIENT_SECRET="${SEAWEEDFS_E2E_OAUTH2_CLIENT_SECRET:-e2e/oauth2+client-secret0123}"

docker secret inspect seaweedfs-s3-access-key >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_ACCESS_KEY" | docker secret create seaweedfs-s3-access-key - >/dev/null
docker secret inspect seaweedfs-s3-secret-key >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_SECRET_KEY" | docker secret create seaweedfs-s3-secret-key - >/dev/null
docker secret inspect seaweedfs-admin-password >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_ADMIN_PASSWORD" | docker secret create seaweedfs-admin-password - >/dev/null
docker secret inspect seaweedfs-admin-oidc-client-secret >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_OIDC_CLIENT_SECRET" | docker secret create seaweedfs-admin-oidc-client-secret - >/dev/null

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add seaweedfs-data=true "$node" >/dev/null

# requirements.yaml declares it autoCreate:true; created here as well so it exists before
# ci/e2e-check.sh attaches its client containers to it.
docker network create --driver overlay --attachable seaweedfs-net >/dev/null 2>&1 || true
docker network inspect seaweedfs-net >/dev/null

# The bind source has to exist on the NODE, which on colima / Docker Desktop is a VM, so it
# is created through the daemon rather than with a host mkdir.
if [ "$case" = "bind-mount" ]; then
  [ -n "$node" ] && docker node update --label-add seaweedfs-e2e-node=true "$node" >/dev/null
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh curlimages/curl:latest \
    -c 'mkdir -p /host-tmp/seaweedfs-e2e/data' >/dev/null
fi

if [ "$case" = "edge" ] || [ "$case" = "admin-edge" ]; then
  docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi

# admin-oauth2: oauth2-proxy's two secrets, the cookie secret 32 random bytes as the README
# has it, and the stub provider ci/oauth2-stub-oidc.js on traefik-public, serving TLS with a
# certificate for its service name from a throwaway CA. The proxy trusts that CA through the
# fixture's caSecret, and the stub redeems codes only for the client secret made here.
if [ "$case" = "admin-oauth2" ]; then
  docker secret inspect seaweedfs-admin-oauth2-client-secret >/dev/null 2>&1 \
    || printf '%s' "$SEAWEEDFS_E2E_OAUTH2_CLIENT_SECRET" | docker secret create seaweedfs-admin-oauth2-client-secret - >/dev/null
  docker secret inspect seaweedfs-admin-oauth2-cookie-secret >/dev/null 2>&1 \
    || dd if=/dev/urandom bs=32 count=1 2>/dev/null | docker secret create seaweedfs-admin-oauth2-cookie-secret - >/dev/null
  docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
  if ! docker service inspect seaweedfs-e2e-oidc >/dev/null 2>&1; then
    tls="$(mktemp -d)"
    trap 'rm -rf "$tls"' EXIT
    # A config file rather than -addext, which LibreSSL (macOS) and OpenSSL spell alike.
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=seaweedfs-e2e-ca\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n[srv]\nsubjectAltName=DNS:seaweedfs-e2e-oidc\nextendedKeyUsage=serverAuth\n' >"$tls/x.cnf"
    openssl req -x509 -config "$tls/x.cnf" -newkey rsa:2048 -nodes -days 1 -keyout "$tls/ca.key" -out "$tls/ca.pem" 2>/dev/null
    openssl req -new -newkey rsa:2048 -nodes -subj /CN=seaweedfs-e2e-oidc -keyout "$tls/key.pem" -out "$tls/req.pem" 2>/dev/null
    openssl x509 -req -in "$tls/req.pem" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" -CAcreateserial -days 1 \
      -extfile "$tls/x.cnf" -extensions srv -out "$tls/cert.pem" 2>/dev/null
    for s in ca cert key; do
      docker secret rm "seaweedfs-e2e-oidc-$s" >/dev/null 2>&1 || true
    done
    docker secret create seaweedfs-e2e-oidc-ca "$tls/ca.pem" >/dev/null
    docker secret create seaweedfs-e2e-oidc-cert "$tls/cert.pem" >/dev/null
    docker secret create seaweedfs-e2e-oidc-key "$tls/key.pem" >/dev/null
    docker config rm seaweedfs-e2e-oidc-js >/dev/null 2>&1 || true
    docker config create seaweedfs-e2e-oidc-js "$dir/ci/oauth2-stub-oidc.js" >/dev/null
    docker service create --detach --name seaweedfs-e2e-oidc --network traefik-public \
      --config source=seaweedfs-e2e-oidc-js,target=/stub.js \
      --secret seaweedfs-e2e-oidc-cert --secret seaweedfs-e2e-oidc-key --secret seaweedfs-admin-oauth2-client-secret \
      --env ISSUER=https://seaweedfs-e2e-oidc:8443 --env CLIENT_ID=seaweedfs-admin \
      --env CLIENT_SECRET_SECRET=seaweedfs-admin-oauth2-client-secret \
      node:22-alpine node /stub.js >/dev/null
  fi
  # oauth2-proxy reads the discovery document once, at start, and exits without it.
  up=""
  for _ in $(seq 1 60); do
    if docker run --rm --network traefik-public curlimages/curl:latest -sfk --max-time 5 -o /dev/null \
        https://seaweedfs-e2e-oidc:8443/.well-known/openid-configuration >/dev/null 2>&1; then up=1; break; fi
    sleep 3
  done
  [ -n "$up" ] || { echo "the stub identity provider never answered on traefik-public"; docker service logs --tail 20 seaweedfs-e2e-oidc 2>&1; exit 1; }
fi
