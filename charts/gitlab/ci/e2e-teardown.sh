#!/usr/bin/env bash
#
# e2e teardown for the gitlab chart. scripts/e2e-test.sh runs this AFTER the release is
# uninstalled (best-effort; errors ignored):
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created — the two secrets and the persistence
# node label — and LEAVES the shared traefik-public overlay (other releases use it).
#
# GitLab's volumes are NOT removed here: `swarmcli charts uninstall` tears the stack down
# and Swarm collects the stack-scoped named volumes with it. A stray host path cannot exist
# either — no gitlab fixture in the e2e matrix uses persistence.*Path.
set -uo pipefail

docker secret rm gitlab_smtp_password >/dev/null 2>&1 || true
docker secret rm gitlab_root_password >/dev/null 2>&1 || true

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-rm gitlab-data "$node" >/dev/null 2>&1 || true

exit 0
