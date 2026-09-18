#!/usr/bin/env bash
#
# e2e teardown for the mariadb-galera chart. scripts/e2e-test.sh runs this AFTER it
# uninstalls the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created (the two secrets and the five peer
# node labels). The shared mariadb-galera-net overlay is LEFT in place, like the
# other charts' hooks. Best-effort: every step tolerates already-gone resources.
set -uo pipefail

docker secret rm mariadb_galera_root_password >/dev/null 2>&1 || true
docker secret rm mariadb_galera_password      >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  for i in 1 2 3 4 5; do
    docker node update --label-rm "mariadb-galera-$i" "$node" >/dev/null 2>&1 || true
  done
fi

exit 0
