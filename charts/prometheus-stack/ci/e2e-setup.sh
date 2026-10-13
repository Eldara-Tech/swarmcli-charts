#!/usr/bin/env bash
#
# e2e setup for the prometheus-stack chart. scripts/e2e-test.sh runs this BEFORE
# `swarmcli charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but never creates. ci/e2e-teardown.sh removes
# everything created here except the shared overlays.
#
# Idempotent: safe to re-run after a crashed run (every step tolerates "already exists").
set -euo pipefail

release="$1"
dir="$2"
case="$3"

CURL_IMAGE="${PROMSTACK_E2E_CURL_IMAGE:-curlimages/curl:latest}"
TWIN_IMAGE="${PROMSTACK_E2E_TWIN_IMAGE:-busybox:1.37}"

secret() {  # secret <name> <value>
  docker secret inspect "$1" >/dev/null 2>&1 || printf '%s' "$2" | docker secret create "$1" - >/dev/null
}

# Both Grafana secrets are required by requirements.yaml, so the pre-flight refuses every
# fixture without them. The password is the one ci/e2e-check.sh logs in with.
secret grafana_admin_password "e2e-admin-password"
secret grafana_secret_key "e2e-secret-key-0123456789abcdefghijklmnop"

# The data pin for the three stateful services. Harmless for ephemeral (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add prometheus-stack-data=true "$node" >/dev/null

# `monitoring` is autoCreate:true, but the discovery twins below attach to it before the
# install would create it. traefik-public is autoCreate:false and every fixture but
# minimal and published routes Grafana, so the pre-flight needs it to exist; created for
# all of them, as the operator's edge would have.
docker network create --driver overlay --attachable monitoring >/dev/null 2>&1 || true
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true

case "$case" in
  bind-mount)
    # Created THROUGH THE DAEMON: a bind source must exist on the NODE, and on a Docker-in-VM
    # host (colima, Docker Desktop) the node is the VM, not this machine. Owned by the users
    # the images run as: 65534 for Prometheus and Alertmanager, 472 for Grafana.
    docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh "$CURL_IMAGE" -c '
      b=/host-tmp/prometheus-stack-e2e
      mkdir -p $b/prometheus $b/alertmanager $b/grafana
      chown 65534:65534 $b/prometheus $b/alertmanager
      chown 472:0 $b/grafana' >/dev/null
    ;;
  edge)
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
    edge_up
    ;;
  discovery)
    # A labelled and an unlabelled twin on `monitoring`, and a third labelled service on an
    # overlay only prometheus.extraNetworks brings Prometheus onto. Each serves one sample
    # at /metrics with no Content-Type, which also exercises fallback_scrape_protocol.
    docker network create --driver overlay --attachable prometheus-stack-e2e-extra >/dev/null 2>&1 || true
    serve='mkdir -p /tmp/www && printf "e2e_up 1\n" > /tmp/www/metrics && exec httpd -f -p 8080 -h /tmp/www'
    twin() {  # twin <name> <network> [label args...]
      local name="$1" net="$2"; shift 2
      docker service rm "$name" >/dev/null 2>&1 || true
      docker service create --detach --name "$name" --network "$net" "$@" \
        "$TWIN_IMAGE" sh -c "$serve" >/dev/null
    }
    twin "${release}-labelled" monitoring \
      --label prometheus.io/scrape=true --label prometheus.io/port=8080 --label prometheus.io/job=e2e-labelled
    twin "${release}-unlabelled" monitoring
    twin "${release}-extra" prometheus-stack-e2e-extra \
      --label prometheus.io/scrape=true --label prometheus.io/port=8080 --label prometheus.io/job=e2e-extra
    ;;
  alertmanager-config)
    # The receiver's url_file. Nothing listens there; the check reads the loaded config.
    secret prometheus-stack-e2e-webhook "http://127.0.0.1:9/e2e-webhook"
    ;;
  extras)
    secret prometheus-stack-e2e-smtp "e2e-smtp-password"
    ;;
esac
