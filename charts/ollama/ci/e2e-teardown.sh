#!/usr/bin/env bash
#
# e2e teardown for the ollama chart. scripts/e2e-test.sh runs this AFTER the release is
# uninstalled (best-effort; errors ignored):
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created, and leaves the shared traefik-public
# overlay in place.
set -euo pipefail

dir="$2"
case="$3"

# Drop the persistence pin label.
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-rm ollama-data "$node" >/dev/null 2>&1 || true

# bind-mount fixture: remove the host dir.
[ "$case" = "bind-mount" ] && rm -rf /tmp/ollama-e2e 2>/dev/null || true

# edge fixture: tear down the traefik edge (leaves the shared traefik-public overlay).
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_down
fi

exit 0
