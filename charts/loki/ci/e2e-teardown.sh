#!/usr/bin/env bash
#
# e2e teardown for the loki chart. scripts/e2e-test.sh runs this AFTER it uninstalls the
# release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes what ci/e2e-setup.sh created and leaves the shared overlays alone.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

dir="$2"
case="$3"

if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

docker config rm loki-config >/dev/null 2>&1 || true
docker secret rm loki-config >/dev/null 2>&1 || true
# Same reason as the setup hook: the directory lives on the node, not on this host.
if [ "$case" = "bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh \
    "${LOKI_E2E_CURL_IMAGE:-curlimages/curl:latest}" \
    -c 'rm -rf /host-tmp/loki-e2e' >/dev/null 2>&1 || true
fi

exit 0
