#!/usr/bin/env bash
#
# e2e teardown for the mongodb chart. scripts/e2e-test.sh runs this AFTER it uninstalls the
# release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created (the secrets, the node label, and — for the
# bind-mount fixture — the host dir's contents). The shared mongodb-net overlay is LEFT in place.
# Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"

docker secret rm mongodb_root_password mongodb_password mongodb_keyfile >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-rm mongodb-data "$node" >/dev/null 2>&1 || true

# Empty the host datadir via a throwaway root container (matches e2e-setup.sh): a host path is not
# removed by `uninstall --purge-volumes`, and on a reused runner a leftover datadir would make the
# next run skip the image's first init — no users would be created. Best-effort.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt/mongodb-data:/data alpine \
    sh -c 'rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null' >/dev/null 2>&1 || true
fi

exit 0
