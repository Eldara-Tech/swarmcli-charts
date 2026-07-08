#!/usr/bin/env bash
#
# e2e setup for the traefik chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# The chart pins Traefik to the node holding its ACME cert volume via
# node.labels.traefik-certs == true, so that label must exist or the task never
# schedules. For the certs-bind-mount fixture it also pre-creates the host cert-store
# dir. traefik-public is autoCreate:true (swarmcli creates it) and no secret is needed.
# ci/e2e-teardown.sh removes everything created here. (See charts/redis/ci/e2e-setup.sh
# for the shared shape.)
#
# Idempotent: safe to re-run after a crashed run.
set -euo pipefail

case="$3"

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-add traefik-certs=true "$node" >/dev/null

# certs-bind-mount fixture only: pre-create the host ACME store dir (0700 is the
# conventional mode for the store; traefik runs as root so no chown is needed).
if [ "$case" = "certs-bind-mount" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    install -d -m 0700 /opt/traefik-certificates 2>/dev/null || true
  else
    sudo -n install -d -m 0700 /opt/traefik-certificates 2>/dev/null \
      || mkdir -p /opt/traefik-certificates 2>/dev/null || true
  fi
fi

# --- routing fixture only: stand up two whoami backends on traefik-public — one correctly
# labelled (discovered -> 200) and one MISSING only the constraint label (never discovered
# -> 404). ci/e2e-check.sh asserts both; ci/e2e-teardown.sh removes them (issue #63). -----
if [ "$case" = "routing" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_whoami_up whoami-ok  whoami-ok.e2e.test  true
  edge_whoami_up whoami-bad whoami-bad.e2e.test false
fi
