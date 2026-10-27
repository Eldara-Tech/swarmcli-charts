#!/usr/bin/env bash
#
# e2e teardown for the postgres-patroni chart. scripts/e2e-test.sh runs this AFTER it
# uninstalls the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created (the three secrets and the five node
# labels, and the bind-mount fixture's host directories). The shared postgres-patroni-net overlay is LEFT in place, like the other
# charts' hooks. Best-effort: every step tolerates already-gone resources.
set -uo pipefail

for s in superuser replication restapi; do
  docker secret rm "postgres_patroni_${s}_password" >/dev/null 2>&1 || true
done

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  for i in 1 2 3 4 5; do
    docker node update --label-rm "postgres-patroni-$i" "$node" >/dev/null 2>&1 || true
  done
fi

if [ "${3:-}" = bind-mount ]; then
  docker run --rm -v /opt:/opt alpine rm -rf /opt/postgres-patroni >/dev/null 2>&1 || true
fi

exit 0
