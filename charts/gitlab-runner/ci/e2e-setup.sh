#!/usr/bin/env bash
#
# e2e setup for the gitlab-runner chart. scripts/e2e-test.sh runs this BEFORE install:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
#
# It provisions what the chart declares as operator-supplied: the runner authentication
# token secret, the cache credential secrets, and the node label the default node pin
# constrains to. Idempotent — it may run again after a failed case.
#
# The mock GitLab is NOT stood up here: it has to join the release's own overlay
# (`<release>_default`), which does not exist until the stack is deployed, so
# ci/e2e-check.sh creates it and removes it again.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

# The runner authentication token. A real one is a `glrt-…` string from GitLab; the value
# here only has to be something the smoke check can recognise coming back out of the mock.
docker secret inspect gitlab-runner-token >/dev/null 2>&1 \
  || printf 'glrt-e2e-dummy-token' | docker secret create gitlab-runner-token - >/dev/null

# Cache credentials, for the `cache` fixture. Deliberately containing the `/` and `+` that
# real base64 secret keys carry, so the TOML literal-string quoting is exercised.
if [ "$case" = "cache" ]; then
  docker secret inspect gitlab-runner-cache-access-key >/dev/null 2>&1 \
    || printf 'AKIAE2EFAKEKEY' | docker secret create gitlab-runner-cache-access-key - >/dev/null
  docker secret inspect gitlab-runner-cache-secret-key >/dev/null 2>&1 \
    || printf 'wJalr/XUtnFEMI+K7MDENG+bPxRfiCYEXAMPLE' | docker secret create gitlab-runner-cache-secret-key - >/dev/null
fi

# Pin: label this (single-node) swarm's node so the default persistence.nodeLabel
# constraint schedules. Harmless for the ephemeral fixture, which renders no pin.
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add gitlab-runner-data=true "$node" >/dev/null

# The bind-mount fixture also exercises a NON-default persistence.nodeLabel, so the label it
# names has to exist too — without it the task sits Pending on "scheduling constraints not
# satisfied" and the case fails for a reason that has nothing to do with bind mounts.
if [ "$case" = "bind-mount" ]; then
  mkdir -p /tmp/gitlab-runner-e2e/config
  chmod 0777 /tmp/gitlab-runner-e2e/config
  [ -n "$node" ] && docker node update --label-add runner-node=true "$node" >/dev/null
fi

echo "  setup: secrets and node label ready for $release ($case)"
