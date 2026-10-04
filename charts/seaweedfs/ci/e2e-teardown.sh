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

if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

docker secret rm seaweedfs-s3-access-key seaweedfs-s3-secret-key >/dev/null 2>&1 || true

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
