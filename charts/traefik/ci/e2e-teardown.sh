#!/usr/bin/env bash
#
# e2e teardown for the traefik chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes the traefik-certs node label and — for the certs-bind-mount fixture — the
# host cert-store dir. The shared traefik-public overlay is LEFT in place.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-rm traefik-certs "$node" >/dev/null 2>&1 || true

if [ "$case" = "certs-bind-mount" ]; then
  if [ "$(id -u)" -eq 0 ]; then rm -rf /opt/traefik-certificates 2>/dev/null || true
  else sudo -n rm -rf /opt/traefik-certificates 2>/dev/null || true; fi
fi

exit 0
