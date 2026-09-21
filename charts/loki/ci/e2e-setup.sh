#!/usr/bin/env bash
#
# e2e setup for the loki chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions what swarmcli validates but does not create. Loki has no auth and no
# secrets of its own, so the only universal prerequisite is the data-node label.
# ci/e2e-teardown.sh removes everything created here.
#
# Idempotent: safe to re-run after a crashed run (every step tolerates "already exists").
set -euo pipefail

dir="$2"
case="$3"

# Pin: label this (single-node) swarm's node so the persistence.nodeLabel constraint
# schedules. Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add loki-data=true "$node" >/dev/null

# The overlay the none/traefik modes attach to. requirements.yaml declares it
# autoCreate:true, so swarmcli would create it — created here as well so the network
# exists before ci/e2e-check.sh attaches its curl container to it.
docker network create --driver overlay --attachable monitoring >/dev/null 2>&1 || true

# --- bind-mount fixture: the directory the fixture bind-mounts. Created THROUGH THE
# DAEMON rather than with a plain mkdir, because a bind source has to exist on the NODE:
# on a Docker-in-VM host (colima, Docker Desktop) the node is the VM and a directory this
# hook creates on the host is simply not there, which the daemon reports as "bind source
# path does not exist". Mounting the node's /tmp into a throwaway container and creating
# the subdirectory inside it works the same way on a Linux runner and on a laptop.
# Root, and 0777, because the Loki image runs as UID 10001 and this hook does not. ------
if [ "$case" = "bind-mount" ]; then
  docker run --rm --user 0:0 -v /tmp:/host-tmp --entrypoint sh \
    "${LOKI_E2E_CURL_IMAGE:-curlimages/curl:latest}" \
    -c 'mkdir -p /host-tmp/loki-e2e/data && chmod -R 0777 /host-tmp/loki-e2e' >/dev/null
fi

# --- external-config / external-secret fixtures: the operator-supplied configuration the
# chart mounts instead of its own. The chart's shipped file IS a complete Loki config, so
# it stands in for the operator's here — what is under test is the mount and the
# -config.file wiring, not the file's contents. ----------------------------------------
if [ "$case" = "external-config" ]; then
  docker config inspect loki-config >/dev/null 2>&1 \
    || docker config create loki-config "$dir/files/loki-config.yaml" >/dev/null
fi
if [ "$case" = "external-secret" ]; then
  docker secret inspect loki-config >/dev/null 2>&1 \
    || docker secret create loki-config "$dir/files/loki-config.yaml" >/dev/null
fi

# --- edge fixture: stand up the traefik chart as a REAL edge on traefik-public, so
# ci/e2e-check.sh can prove a request routes THROUGH it to Loki — and is refused by the
# basic-auth middleware without credentials (shared helper). ---------------------------
if [ "$case" = "edge" ]; then
  docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_up
fi
