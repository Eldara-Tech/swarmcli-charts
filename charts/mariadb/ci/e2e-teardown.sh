#!/usr/bin/env bash
#
# e2e teardown for the mariadb chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created (the two secrets, the node label, and —
# for the bind-mount fixture — the host dir). The shared mariadb-net overlay is LEFT in
# place. Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"

docker secret rm mariadb_root_password >/dev/null 2>&1 || true
docker secret rm mariadb_password      >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-rm mariadb-data "$node" >/dev/null 2>&1 || true

if [ "$case" = "bind-mount" ]; then
  if [ "$(id -u)" -eq 0 ]; then rm -rf /opt/mariadb-data 2>/dev/null || true
  else sudo -n rm -rf /opt/mariadb-data 2>/dev/null || true; fi
fi

exit 0
