#!/usr/bin/env bash
#
# e2e teardown for the redis chart. scripts/e2e-test.sh runs this AFTER it uninstalls the
# release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created (the auth secret, the node label, and —
# for the bind-mount fixture — the host dir). The shared redis-net overlay is LEFT in
# place (swarmcli auto-created it; other releases may share it).
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"

docker secret rm redis_password >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-rm redis-data "$node" >/dev/null 2>&1 || true

if [ "$case" = "bind-mount" ]; then
  if [ "$(id -u)" -eq 0 ]; then rm -rf /opt/redis-data 2>/dev/null || true
  else sudo -n rm -rf /opt/redis-data 2>/dev/null || true; fi
fi

exit 0
