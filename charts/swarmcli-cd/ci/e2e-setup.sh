#!/usr/bin/env bash
#
# e2e setup for the swarmcli-cd chart. scripts/e2e-test.sh runs this BEFORE `swarmcli
# charts install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates: the admin
# token secret, the applications Docker config, the persistence node label — plus, per
# fixture, the external app-set volume (dir) and a real Traefik edge (edge).
# ci/e2e-teardown.sh removes everything created here.
#
# The applications file declares ONE application because the controller REFUSES to start
# on an empty set ("no applications declared"), and declares it `automated: false` so it
# is reconciled and reported but never deployed — this run is about the chart, not about
# whether a swarm can be converged. It points at this repository, which is public, so no
# git credential is needed.
#
# The token is a fixed dummy: ci/e2e-check.sh has to present it to the API, and a random
# one would have to be smuggled between the two hooks.
#
# Idempotent: safe to re-run after a crashed run (every create tolerates "already exists").
set -euo pipefail

dir="$2"
case="$3"

E2E_TOKEN="${E2E_CD_TOKEN:-e2e-swarmcli-cd-admin-token}"

docker secret inspect swarmcli-cd-token >/dev/null 2>&1 \
  || printf '%s' "$E2E_TOKEN" | docker secret create swarmcli-cd-token - >/dev/null

docker config inspect swarmcli-cd-applications >/dev/null 2>&1 || \
  printf '%s\n' \
    'apiVersion: v1' \
    'applications:' \
    '  - name: e2e-whoami' \
    '    source:' \
    '      repoURL: https://github.com/Eldara-Tech/swarmcli-charts.git' \
    '      revision: main' \
    '      chart:' \
    '        path: ./charts/whoami' \
    '    syncPolicy:' \
    '      automated: false' \
  | docker config create swarmcli-cd-applications - >/dev/null

# Pin: label this (single-node) swarm's node so node.labels.swarmcli-cd-data == true
# schedules. Harmless for the ephemeral fixture (no pin rendered).
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-add swarmcli-cd-data=true "$node" >/dev/null

case "$case" in
  # dir mode reads an EXTERNAL volume something outside the stack publishes onto. Nothing
  # writes into it here, which is the point: the controller must come up and stay healthy
  # while the app set has not arrived yet, retrying rather than crash-looping.
  dir)
    docker volume create gitops-appset >/dev/null 2>&1 || true
    ;;
  # edge: stand up the in-repo traefik chart as a real edge (issue #63). The shared overlay
  # is declared autoCreate:false here — the edge proxy owns it — so create it before either
  # install needs it.
  edge)
    docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
    edge_up || exit 1
    ;;
esac
