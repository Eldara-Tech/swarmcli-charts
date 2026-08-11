#!/usr/bin/env bash
#
# e2e setup for the gitlab chart. scripts/e2e-test.sh runs this BEFORE `swarmcli charts
# install`, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It provisions the external prerequisites swarmcli validates but never creates:
#   * the two dummy secrets the minimal fixture wires into GitLab's omnibus config;
#   * the persistence node label the data pin needs;
#   * traefik-public (autoCreate:false in requirements.yaml — the operator/traefik chart
#     owns it; here we stand in for them).
# ci/e2e-teardown.sh removes everything created here (leaving the shared overlay).
#
# The secrets matter beyond convergence: GitLab reads them with Ruby's File.read at
# reconfigure time, so if the path or the mount were wrong, reconfigure RAISES and the
# container never becomes healthy. A converged release is therefore the proof that the
# secret plumbing works — which is why the e2e fixture turns both of them on.
#
# Idempotent: safe to re-run after a crashed run (every step tolerates "already exists").
set -euo pipefail

dir="$2"

# Must match ci/e2e-check.sh. Deliberately distinctive strings, not "test": ci/e2e-check.sh
# asserts the SMTP password is ABSENT from PID 1's environment, and a value that also occurs
# inside the hostnames in GITLAB_OMNIBUS_CONFIG would make that assertion fire on itself.
SMTP_PW='sw4rm-smtp-e2e-pw'
ROOT_PW='sw4rm-r00t-e2e-pw'

# Pull the image HERE rather than letting the deploy do it. GitLab CE is several gigabytes
# and E2E_TIMEOUT is the CONVERGENCE budget: a pull inside it spends minutes GitLab needs to
# boot. This hook has no timeout of its own (only the job backstop), so the pull is free.
# The reference is read from the chart so a Renovate bump cannot leave a stale pin here;
# best-effort, since a parse miss only costs us the head start.
repo="$(sed -n '/^image:/,/^[^ ]/p' "$dir/values.yaml" | sed -n 's|^  repository: *||p')"
tag="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$dir/Chart.yaml")"
#
# The elapsed time is REPORTED, not just spent: e2e-test.sh's output reaches the Actions log
# in one flush, so a run shows a single timestamp for the whole fixture and the pull/converge
# split is otherwise unrecoverable. Without this number there is no way to tell a comfortable
# convergence from one sitting just under E2E_TIMEOUT.
if [ -n "$repo" ] && [ -n "$tag" ]; then
  echo "  pre-pulling ${repo}:${tag} (outside the convergence budget)"
  t0=$(date +%s)
  docker pull "${repo}:${tag}" >/dev/null 2>&1 || true
  echo "  pre-pull finished in $(( $(date +%s) - t0 ))s; convergence budget (E2E_TIMEOUT) starts now"
fi

docker secret inspect gitlab_smtp_password >/dev/null 2>&1 \
  || printf '%s' "$SMTP_PW" | docker secret create gitlab_smtp_password - >/dev/null
docker secret inspect gitlab_root_password >/dev/null 2>&1 \
  || printf '%s' "$ROOT_PW" | docker secret create gitlab_root_password - >/dev/null

# Label this (single-node) swarm's node so the persistence.nodeLabel constraint schedules.
node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
[ -n "$node" ] && docker node update --label-add gitlab-data=true "$node" >/dev/null

# Shared ingress overlay the traefik exposure mode and the SSH TCP router attach to.
docker network create --driver overlay --attachable traefik-public >/dev/null 2>&1 || true
