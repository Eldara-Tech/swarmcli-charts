#!/usr/bin/env bash
#
# e2e teardown for the elasticsearch chart. scripts/e2e-test.sh runs this AFTER it uninstalls the
# release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created: the secrets, the node labels, the generated TLS
# files, the bind-mount host dir and the traefik edge. The shared overlays (elasticsearch-net,
# traefik-public) are LEFT in place. Best-effort: every step tolerates already-gone resources.
set -uo pipefail

case="$3"
tls_dir="${E2E_ES_TLS_DIR:-${TMPDIR:-/tmp}/e2e-elasticsearch-tls}"

docker secret rm elasticsearch_elastic_password kibana_system_password kibana_encryption_key \
  elasticsearch_tls_ca elasticsearch_tls_cert elasticsearch_tls_key >/dev/null 2>&1 || true
rm -rf "$tls_dir"

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
# One label per call: a single --label-rm of a missing key fails the whole update.
for n in 1 2 3; do
  [ -n "$node" ] && docker node update --label-rm "elasticsearch-data-$n" "$node" >/dev/null 2>&1 || true
done

# A host path is not removed by `uninstall --purge-volumes`, and a leftover data dir would hand
# the next run a node that already belongs to a cluster.
if [ "$case" = "bind-mount" ]; then
  docker run --rm -v /opt:/opt alpine rm -rf /opt/elasticsearch-data-1 >/dev/null 2>&1 || true
fi

if [ "$case" = "edge" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

exit 0
