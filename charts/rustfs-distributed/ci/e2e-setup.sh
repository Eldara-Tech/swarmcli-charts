#!/usr/bin/env bash
#
# e2e setup for the rustfs-distributed chart. scripts/e2e-test.sh runs this BEFORE
# `swarmcli charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but does not create: the two credential secrets,
# a node label for EVERY peer on the single CI node (rustfs-1 … rustfs-6, so the pinned
# default shape schedules there: not HA, but a real 4-peer erasure-coded cluster), the
# client overlay ci/e2e-check.sh attaches to, the bind-mount directories, for `edge` and
# `console-edge` the traefik chart as a real edge, and for `oidc` the client secret and a
# stub OpenID provider. ci/e2e-teardown.sh removes everything created here except the
# overlays.
#
# INVARIANT: the key pair below is the one ci/e2e-check.sh signs with. The secret key
# carries a `/` and a `+`, as a real base64 key does. The stub provider's issuer is the
# one ci/oidc-values.yaml and ci/e2e-check.sh expect.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

dir="$2"
case="$3"

RUSTFS_E2E_ACCESS_KEY="${RUSTFS_E2E_ACCESS_KEY:-e2e-access-key}"
RUSTFS_E2E_SECRET_KEY="${RUSTFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"

docker secret inspect rustfs-access-key >/dev/null 2>&1 \
  || printf '%s' "$RUSTFS_E2E_ACCESS_KEY" | docker secret create rustfs-access-key - >/dev/null
docker secret inspect rustfs-secret-key >/dev/null 2>&1 \
  || printf '%s' "$RUSTFS_E2E_SECRET_KEY" | docker secret create rustfs-secret-key - >/dev/null

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] || { echo "  FAIL: no swarm node to label"; exit 1; }
labels=()
for n in 1 2 3 4 5 6; do labels+=(--label-add "rustfs-$n=true"); done
docker node update "${labels[@]}" "$node" >/dev/null

# requirements.yaml declares it autoCreate:true; created here as well so it exists before
# ci/e2e-check.sh attaches its client containers to it.
docker network create --driver overlay --attachable rustfs-net >/dev/null 2>&1 || true
docker network inspect rustfs-net >/dev/null

# The bind sources have to exist on the NODE, which on colima / Docker Desktop is a VM, so
# they are created through the daemon rather than with a host mkdir — owned by 10001, the
# uid RustFS runs as, which cannot fix ownership itself.
if [ "$case" = "bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh curlimages/curl:latest \
    -c 'for n in 1 2 3 4; do d=/host-tmp/rustfs-distributed-e2e/$n; mkdir -p "$d" && chown 10001:10001 "$d" && chmod 0750 "$d"; done' >/dev/null
fi

# oidc: busybox httpd serving a discovery document and an empty key set on rustfs-net,
# Running and answering BEFORE install, because every peer discovers its providers once, at
# start, and drops one it cannot reach. Nobody logs in, so no key is needed. The two
# content types are what RustFS checks for.
if [ "$case" = "oidc" ]; then
  docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
  docker secret inspect rustfs-oidc-client-secret >/dev/null 2>&1 \
    || printf '%s' "${RUSTFS_E2E_OIDC_SECRET:-e2e-oidc-client-secret}" | docker secret create rustfs-oidc-client-secret - >/dev/null
  iss=http://rustfs-distributed-e2e-idp:8080/realms/e2e
  discovery="{\"issuer\":\"$iss\",\"authorization_endpoint\":\"$iss/protocol/openid-connect/auth\",\"token_endpoint\":\"$iss/protocol/openid-connect/token\",\"jwks_uri\":\"$iss/protocol/openid-connect/certs.json\",\"response_types_supported\":[\"code\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"RS256\"]}"
  docker service rm rustfs-distributed-e2e-idp >/dev/null 2>&1 || true
  docker service create --detach --name rustfs-distributed-e2e-idp --network rustfs-net --env DISCOVERY="$discovery" \
    busybox:1.37 sh -c 'd=/www/realms/e2e && mkdir -p "$d/.well-known" "$d/protocol/openid-connect" &&
      printf "%s" "$DISCOVERY" > "$d/.well-known/openid-configuration" &&
      printf "{\"keys\":[]}" > "$d/protocol/openid-connect/certs.json" &&
      printf ".well-known/openid-configuration:application/json\n.json:application/json\n" > /etc/httpd.conf &&
      exec httpd -f -v -p 8080 -h /www -c /etc/httpd.conf' >/dev/null
  got=""
  for _ in $(seq 1 40); do
    got="$(docker run --rm --network rustfs-net curlimages/curl:latest -s -o /dev/null -w '%{http_code} %{content_type}' \
      --max-time 5 "$iss/.well-known/openid-configuration" 2>/dev/null || true)"
    [ "$got" = "200 application/json" ] && break
    sleep 3
  done
  [ "$got" = "200 application/json" ] || { echo "  FAIL: the stub OpenID provider never served its discovery document (last: '$got')"; exit 1; }
fi

if [ "$case" = "edge" ] || [ "$case" = "console-edge" ]; then
  docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
