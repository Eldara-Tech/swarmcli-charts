#!/usr/bin/env bash
#
# e2e teardown for the swarmcli-cd chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created. Best-effort: every step tolerates
# already-gone resources.
set -uo pipefail

dir="$2"
case="$3"

docker secret rm swarmcli-cd-token       >/dev/null 2>&1 || true
docker config rm swarmcli-cd-applications >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | head -1)"
[ -n "$node" ] && docker node update --label-rm swarmcli-cd-data "$node" >/dev/null 2>&1 || true

case "$case" in
  # An EXTERNAL volume is not `uninstall --purge-volumes`' to remove — it was created here.
  dir)
    docker volume rm gitops-appset >/dev/null 2>&1 || true
    ;;
  edge)
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh" 2>/dev/null && edge_down >/dev/null 2>&1
    ;;
esac

exit 0
