#!/usr/bin/env bash
#
# e2e setup for the rustfs chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but does not create: the two credential secrets,
# the data node label, the client overlay ci/e2e-check.sh attaches to, the bind-mount
# directory, and for `edge` the traefik chart as a real edge. ci/e2e-teardown.sh removes
# everything created here except the overlays.
#
# INVARIANT: the key pair below is the one ci/e2e-check.sh signs with. The secret key
# carries a `/` and a `+`, as a real base64 key does.
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
[ -n "$node" ] && docker node update --label-add rustfs-data=true "$node" >/dev/null

# requirements.yaml declares it autoCreate:true; created here as well so it exists before
# ci/e2e-check.sh attaches its client containers to it.
docker network create --driver overlay --attachable rustfs-net >/dev/null 2>&1 || true
docker network inspect rustfs-net >/dev/null

# The bind source has to exist on the NODE, which on colima / Docker Desktop is a VM, so it
# is created through the daemon rather than with a host mkdir — owned by 10001, the uid
# RustFS runs as, which cannot fix ownership itself.
if [ "$case" = "bind-mount" ]; then
  [ -n "$node" ] && docker node update --label-add rustfs-e2e-node=true "$node" >/dev/null
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh curlimages/curl:latest \
    -c 'mkdir -p /host-tmp/rustfs-e2e/data && chown 10001:10001 /host-tmp/rustfs-e2e/data && chmod 0750 /host-tmp/rustfs-e2e/data' >/dev/null
fi

if [ "$case" = "edge" ]; then
  docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
