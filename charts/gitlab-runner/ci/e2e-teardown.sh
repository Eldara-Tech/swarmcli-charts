#!/usr/bin/env bash
#
# e2e teardown for the gitlab-runner chart. scripts/e2e-test.sh runs this AFTER the release
# is uninstalled:
#   $1 = release name   $2 = chart directory   $3 = fixture case
# Best-effort: every step is allowed to fail so one missing object cannot mask another.
# Note the missing `-e` — this must keep going.
set -uo pipefail

release="$1"
case="${3:-}"

# The mock is normally removed by ci/e2e-check.sh; this catches the case where the check
# failed half way through and left it behind.
docker service rm mock-gitlab >/dev/null 2>&1
docker config rm gitlab-runner-mock-js >/dev/null 2>&1

docker secret rm gitlab-runner-token >/dev/null 2>&1
docker secret rm gitlab-runner-cache-access-key >/dev/null 2>&1
docker secret rm gitlab-runner-cache-secret-key >/dev/null 2>&1

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-rm gitlab-runner-data "$node" >/dev/null 2>&1

if [ "$case" = "bind-mount" ]; then
  rm -rf /tmp/gitlab-runner-e2e/config
  [ -n "$node" ] && docker node update --label-rm runner-node "$node" >/dev/null 2>&1
fi

exit 0
