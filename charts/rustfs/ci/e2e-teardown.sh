#!/usr/bin/env bash
#
# e2e teardown for the rustfs chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes what ci/e2e-setup.sh created and leaves the overlays alone: removing
# rustfs-net here races the next fixture's setup, whose install then finds it gone.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

dir="$2"
case="$3"
c="${case#distributed-}"

if [ "$c" = "edge" ] || [ "$c" = "console-edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

if [ "$c" = "oidc" ]; then
  docker service rm rustfs-e2e-idp >/dev/null 2>&1 || true
  docker secret rm rustfs-oidc-client-secret >/dev/null 2>&1 || true
fi

docker secret rm rustfs-access-key rustfs-secret-key >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  # The labels this mode's setup added, one at a time: --label-rm fails as a whole when any
  # one label is already gone.
  case "$case" in
    distributed-*) labels="rustfs-1 rustfs-2 rustfs-3 rustfs-4 rustfs-5 rustfs-6" ;;
    bind-mount) labels="rustfs-data rustfs-e2e-node" ;;
    *) labels="rustfs-data" ;;
  esac
  for l in $labels; do
    docker node update --label-rm "$l" "$node" >/dev/null 2>&1 || true
  done
fi

if [ "$case" = "bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh curlimages/curl:latest \
    -c 'rm -rf /host-tmp/rustfs-e2e' >/dev/null 2>&1 || true
fi
if [ "$case" = "distributed-bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh curlimages/curl:latest \
    -c 'rm -rf /host-tmp/rustfs-distributed-e2e' >/dev/null 2>&1 || true
fi

exit 0
