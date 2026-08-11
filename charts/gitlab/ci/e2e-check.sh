#!/usr/bin/env bash
#
# e2e smoke check for the gitlab chart. scripts/e2e-test.sh runs this after the release
# converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence already proves a great deal here, and the checks below deliberately do not
# repeat it: GitLab's healthcheck gates task-running, and `gitlab-ctl reconfigure` runs on
# every boot, so a task that reached Running means the whole generated omnibus config
# parsed AND both File.read calls found their mounted secrets. Anything wrong with the
# secret plumbing raises in Ruby and the task never converges.
#
# What convergence does NOT show, and what this asserts:
#   1. the config the chart generated is the config GitLab is RUNNING — the settings could
#      have been silently overridden by the /etc/gitlab/gitlab.rb the image writes into the
#      persisted volume on first boot, which is read after GITLAB_OMNIBUS_CONFIG and wins;
#   2. /dev/shm really is the sized tmpfs — `shm_size` is dropped silently by Swarm, and
#      this chart's long-syntax mount is the workaround, so it needs proving on a real node;
#   3. the SMTP password reached GitLab's config but NOT the container's environment;
#   4. the state that must survive a redeploy is on the persisted volumes.
set -euo pipefail

release="$1"
# SMTP_PW must match ci/e2e-setup.sh; HOST must match ci/minimal-values.yaml. The password is
# deliberately distinctive: the environment assertion below greps for it, and a value like
# "test" also occurs inside HOST, so it would report a leak that is not there.
SMTP_PW='sw4rm-smtp-e2e-pw'
HOST='gitlab.e2e.test'

fail=0
note() { echo "  FAIL: $1"; fail=1; }
ok() { echo "  $1"; }

gl_cid() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_gitlab" | sed -n 1p; }

# Task "Running" already means healthy (the healthcheck gates it), but re-resolve the
# container and run the probe once more: an unhealthy task may have been replaced under us.
ready=0
for _ in $(seq 1 30); do
  cid="$(gl_cid)"
  if [ -n "$cid" ] && docker exec "$cid" /opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10 >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 10
done
if [ "$ready" -ne 1 ]; then
  note "${release}_gitlab never passed gitlab-healthcheck"
  docker service ps "${release}_gitlab" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi
cid="$(gl_cid)"
ok "${release}_gitlab: serving (gitlab-healthcheck OK)"

# 1. The RUNNING configuration, as reconfigure rendered it — not what we asked for. gitlab.yml
#    is generated from the merged config, so it reflects whatever actually won.
railscfg=/var/opt/gitlab/gitlab-rails/etc/gitlab.yml
if docker exec "$cid" grep -E "^ +host: ${HOST}\$" "$railscfg" >/dev/null 2>&1; then
  ok "external_url took effect (gitlab.yml host is ${HOST})"
else
  note "gitlab.yml does not carry host ${HOST} — GITLAB_OMNIBUS_CONFIG was overridden (see /etc/gitlab/gitlab.rb)"
  docker exec "$cid" grep -E "^ +(host|port|https):" "$railscfg" 2>/dev/null | sed 's/^/    /' || true
fi
docker exec "$cid" grep -E '^ +https: true' "$railscfg" >/dev/null 2>&1 \
  || note "gitlab.yml does not have https: true — GitLab would generate http:// clone URLs behind a TLS edge"

# 2. /dev/shm is the sized tmpfs the chart mounts, not Docker's 64 MiB default.
shm_kb="$(docker exec "$cid" sh -c "awk '\$2==\"/dev/shm\"{print \$0}' /proc/mounts" 2>/dev/null || true)"
if grep -F 'size=262144k' <<<"$shm_kb" >/dev/null; then
  ok "/dev/shm is a 256 MiB tmpfs"
else
  note "/dev/shm is not the 256 MiB tmpfs the chart mounts: ${shm_kb:-<no /dev/shm mount>}"
fi

# 3. The SMTP password reached the generated config (so File.read returned the real bytes,
#    not an empty string) but never the container environment. Neither branch echoes it.
if docker exec "$cid" grep -F "\"${SMTP_PW}\"" /var/opt/gitlab/gitlab-rails/etc/smtp_settings.rb >/dev/null 2>&1; then
  ok "smtp_settings.rb carries the secret's real content (File.read worked)"
else
  note "the SMTP password in smtp_settings.rb is not the secret's content — File.read returned something else"
fi
if docker exec "$cid" sh -c "tr '\\0' '\\n' < /proc/1/environ" 2>/dev/null | grep -F "${SMTP_PW}" >/dev/null; then
  note "the SMTP password is present in PID 1's environment — it must only ever be read from /run/secrets"
else
  ok "no credential in PID 1's environment (only the File.read call is)"
fi

# 4. The state a redeploy must not lose is on the persisted volumes: the secrets file that
#    makes encrypted DB columns recoverable, and the SSH host keys.
state_ok=1
for f in /etc/gitlab/gitlab-secrets.json /etc/gitlab/ssh_host_ed25519_key; do
  if ! docker exec "$cid" test -f "$f"; then
    note "$f is missing — it must live on the persisted /etc/gitlab volume"
    state_ok=0
  fi
done
if [ "$state_ok" -eq 1 ]; then
  ok "persisted /etc/gitlab holds gitlab-secrets.json and the SSH host keys"
fi

exit "$fail"
