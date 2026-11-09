#!/usr/bin/env bash
#
# e2e teardown for the seaweedfs chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes what ci/e2e-setup.sh created and leaves the overlays alone: removing
# seaweedfs-net here races the next fixture's setup, whose install then finds it gone.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

dir="$2"
case="$3"

if [ "$case" = "edge" ] || [ "$case" = "admin-edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

if [ "$case" = "admin-oauth2" ]; then
  docker service rm seaweedfs-e2e-oidc >/dev/null 2>&1 || true
  # Its secrets stay in use until its container is gone.
  for _ in $(seq 1 30); do
    [ -z "$(docker ps -q --filter label=com.docker.swarm.service.name=seaweedfs-e2e-oidc)" ] && break
    sleep 1
  done
  docker config rm seaweedfs-e2e-oidc-js >/dev/null 2>&1 || true
fi

docker secret rm seaweedfs-s3-access-key seaweedfs-s3-secret-key seaweedfs-admin-password \
  seaweedfs-admin-oidc-client-secret seaweedfs-admin-oauth2-client-secret seaweedfs-admin-oauth2-cookie-secret \
  seaweedfs-e2e-oidc-ca seaweedfs-e2e-oidc-cert seaweedfs-e2e-oidc-key >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  docker node update --label-rm seaweedfs-data "$node" >/dev/null 2>&1 || true
  docker node update --label-rm seaweedfs-e2e-node "$node" >/dev/null 2>&1 || true
fi

if [ "$case" = "bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh curlimages/curl:latest \
    -c 'rm -rf /host-tmp/seaweedfs-e2e' >/dev/null 2>&1 || true
fi

exit 0
