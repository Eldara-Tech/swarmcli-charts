#!/usr/bin/env bash
#
# e2e teardown for the prometheus-stack chart. scripts/e2e-test.sh runs this AFTER it
# uninstalls the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes what ci/e2e-setup.sh created and leaves the shared overlays (monitoring,
# traefik-public) alone. Best-effort: every step tolerates already-gone resources.
set -uo pipefail

release="$1"
dir="$2"
case="$3"

if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

if [ "$case" = "discovery" ]; then
  for svc in labelled unlabelled extra; do
    docker service rm "${release}-$svc" >/dev/null 2>&1 || true
  done
  # The overlay can linger "in use" for a moment after its last service detaches.
  for _ in $(seq 1 10); do
    docker network rm prometheus-stack-e2e-extra >/dev/null 2>&1 && break
    docker network inspect prometheus-stack-e2e-extra >/dev/null 2>&1 || break
    sleep 1
  done
fi

for s in grafana_admin_password grafana_secret_key prometheus-stack-e2e-webhook prometheus-stack-e2e-smtp; do
  docker secret rm "$s" >/dev/null 2>&1 || true
done

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-rm prometheus-stack-data "$node" >/dev/null 2>&1 || true

# Same reason as the setup hook: the directory lives on the node, not on this host.
if [ "$case" = "bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh \
    "${PROMSTACK_E2E_CURL_IMAGE:-curlimages/curl:latest}" \
    -c 'rm -rf /host-tmp/prometheus-stack-e2e' >/dev/null 2>&1 || true
fi

exit 0
