#!/usr/bin/env bash
#
# e2e setup for the seaweedfs chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but does not create: the two credential secrets
# and the admin password, the data node label, the client overlay ci/e2e-check.sh attaches
# to, the bind-mount directory, and for `edge`/`admin-edge` the traefik chart as a real
# edge. ci/e2e-teardown.sh removes everything created here except the overlays.
#
# INVARIANT: the key pair and the admin password below are the ones ci/e2e-check.sh signs
# and logs in with. Both secrets carry a `/` and a `+`, as a real base64 one does.
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

dir="$2"
case="$3"

SEAWEEDFS_E2E_ACCESS_KEY="${SEAWEEDFS_E2E_ACCESS_KEY:-e2e-access-key}"
SEAWEEDFS_E2E_SECRET_KEY="${SEAWEEDFS_E2E_SECRET_KEY:-e2e/secret+key0123456789abcdef}"
SEAWEEDFS_E2E_ADMIN_PASSWORD="${SEAWEEDFS_E2E_ADMIN_PASSWORD:-e2e/admin+password0123}"

docker secret inspect seaweedfs-s3-access-key >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_ACCESS_KEY" | docker secret create seaweedfs-s3-access-key - >/dev/null
docker secret inspect seaweedfs-s3-secret-key >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_SECRET_KEY" | docker secret create seaweedfs-s3-secret-key - >/dev/null
docker secret inspect seaweedfs-admin-password >/dev/null 2>&1 \
  || printf '%s' "$SEAWEEDFS_E2E_ADMIN_PASSWORD" | docker secret create seaweedfs-admin-password - >/dev/null

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
