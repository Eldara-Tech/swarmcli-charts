#!/usr/bin/env bash
#
# Render-time assertions for the gitlab chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# Only one fixture converges in e2e (GitLab is a multi-gigabyte monolith), so these checks
# carry most of the chart's coverage. They assert what `docker compose config` cannot:
#   1. the omnibus config the chart generates contains no literal `$` — it lands in the
#      compose manifest, which docker interpolates before deploying, so one `$` here would
#      silently mangle GitLab's configuration;
#   2. the settings that make GitLab boot at all behind a proxy are present in EVERY render
#      (letsencrypt off above all: left on, its ACME challenge fails and reconfigure with it);
#   3. external_url matches the exposure mode, including the published port;
#   4. exposure.mode / ssh.mode render the edge surface they promise, and the SSH port GitLab
#      ADVERTISES tracks the port actually routed;
#   5. persistence toggles the three volumes and the node pin together;
#   6. /dev/shm is a sized tmpfs expressed the one way Swarm honours;
#   7. no password is ever in the manifest — only the File.read call that fetches it.
set -euo pipefail

out="$1"
case="${2:-}"

fail=0
note() { echo "   FAIL: $1"; fail=1; }

# Hard failure, never a skip (a skipped check is indistinguishable from a passing one).
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -i mikefarah >/dev/null; then
  echo "   FAIL: mikefarah yq v4 is required by the gitlab render checks but was not found" >&2
  exit 1
fi

# No check below pipes into `grep -q`: under the `pipefail` above that makes a check
# that DID match report "no match". Match with `| grep … >/dev/null`; a here-string
# (`grep -q … <<<"$x"`) is fine — no pipe, no SIGPIPE. scripts/lint.sh has the why.

rb="$(yq -r '.services.gitlab.environment.GITLAB_OMNIBUS_CONFIG' "$out")"
[ "$rb" != "null" ] || { echo "   FAIL: no GITLAB_OMNIBUS_CONFIG rendered" >&2; exit 1; }
labels="$(yq -r '.services.gitlab.deploy.labels // [] | .[]' "$out")"
mounts="$(yq -r '.services.gitlab.volumes // [] | .[]' "$out")"

# 1. The chart's own Ruby must be `$`-free. Operator content (config.extraRb) is appended
#    after this marker and is theirs to escape as `$$`, so it is excluded deliberately.
generated="$(awk '/^# --- config.extraRb ---$/{exit} {print}' <<<"$rb")"
if grep -F '$' <<<"$generated" >/dev/null; then
  note "the generated omnibus config contains a literal \$ — docker interpolates the manifest before deploying, so it would not reach GitLab intact"
fi

# 2. Invariants in every render. Without listen_https=false + listen_port the bundled nginx
#    tries to serve TLS it has no certificate for; without letsencrypt=false GitLab tries to
#    issue one over a port Traefik owns and `gitlab-ctl reconfigure` fails on every boot.
for setting in "nginx['listen_https'] = false" "letsencrypt['enable'] = false"; do
  grep -F "$setting" <<<"$generated" >/dev/null || note "missing required setting: $setting"
done
port="$(yq -r '.services.gitlab.environment.GITLAB_OMNIBUS_CONFIG' "$out" \
  | sed -n "s/^nginx\['listen_port'\] = //p")"
svcport="$(yq -r '[.services.gitlab.deploy.labels // [] | .[] | select(test("traefik\.http\.services\..*\.loadbalancer\.server\.port"))] | length' "$out")"
[ -n "$port" ] || note "nginx['listen_port'] is not set"

# 3. external_url — the scheme follows the proxied TLS setting, and a direct publish must
#    carry its port or every clone URL and redirect GitLab emits is unreachable.
url="$(sed -n 's/^external_url "\(.*\)"$/\1/p' <<<"$generated")"
case "$case" in
  published)
    [ "$url" = "http://gitlab.example.com:8080" ] || note "published: external_url is '$url', expected the published port in it" ;;
  tls-off)
    [ "$url" = "http://gitlab.example.com" ] || note "tls-off: external_url is '$url', expected an http:// URL" ;;
  minimal)
    [ "$url" = "https://gitlab.e2e.test" ] || note "minimal: external_url is '$url'" ;;
  *)
    [ "$url" = "https://gitlab.example.com" ] || note "$case: external_url is '$url', expected https://gitlab.example.com" ;;
esac

# 4a. exposure.mode: Traefik labels XOR a published HTTP port XOR neither.
http_ports="$(yq -r '[.services.gitlab.ports // [] | .[] | select(.target == 80)] | length' "$out")"
case "$case" in
  published)
    grep -q 'traefik.enable=true' <<<"$labels" && note "published mode rendered Traefik labels"
    [ "$http_ports" = "1" ] || note "published mode did not publish the HTTP port"
    ;;
  none)
    grep -q 'traefik.http.routers' <<<"$labels" && note "none mode rendered Traefik HTTP routers"
    [ "$http_ports" = "0" ] || note "none mode published an HTTP port (it must not)"
    ;;
  *)  # traefik, the default everywhere else
    grep -q 'traefik.enable=true' <<<"$labels" || note "traefik mode did not render traefik.enable"
    grep -q 'traefik.constraint-label=' <<<"$labels" \
      || note "traefik mode did not render the constraint-label (the swarm provider would never discover it)"
    grep -q 'traefik.swarm.network=' <<<"$labels" \
      || note "traefik mode did not render traefik.swarm.network (the docker-provider key resolves the wrong overlay IP on a multi-network service)"
    [ "$http_ports" = "0" ] || note "traefik mode published an HTTP port directly (it must route through the edge)"
    [ "$svcport" = "1" ] || note "traefik mode did not render exactly one loadbalancer.server.port"
    # The router must point at the port the bundled nginx actually listens on. Anchored:
    # unanchored, port=80 also matches port=8080.
    grep -Eq "traefik\.http\.services\..+\.loadbalancer\.server\.port=$port\$" <<<"$labels" \
      || note "the Traefik service port does not match nginx['listen_port'] = $port"
    ;;
esac

# 4b. ssh.mode: a TCP router XOR a published :22 XOR neither — and gitlab_shell_ssh_port,
#     which is what users are TOLD to use, must name the port that is actually routed.
ssh_ports="$(yq -r '[.services.gitlab.ports // [] | .[] | select(.target == 22)] | length' "$out")"
advertised="$(sed -n "s/^gitlab_rails\['gitlab_shell_ssh_port'\] = //p" <<<"$generated")"
case "$case" in
  published)
    [ "$ssh_ports" = "1" ] || note "ssh.mode published did not publish container port 22"
    [ "$(yq -r '[.services.gitlab.ports // [] | .[] | select(.target == 22) | .published] | .[0]' "$out")" = "$advertised" ] \
      || note "the published SSH port and gitlab_shell_ssh_port disagree — clone URLs would name an unreachable port"
    grep -q 'traefik.tcp.routers' <<<"$labels" && note "ssh.mode published also rendered a TCP router"
    ;;
  none)
    [ "$ssh_ports" = "0" ] || note "ssh.mode none published port 22"
    grep -q 'traefik.tcp' <<<"$labels" && note "ssh.mode none rendered TCP router labels"
    [ -z "$advertised" ] || note "ssh.mode none still advertises gitlab_shell_ssh_port=$advertised"
    ;;
  *)  # traefik
    [ "$ssh_ports" = "0" ] || note "ssh.mode traefik published port 22 directly (it must route through the edge)"
    # The router/service name is release-derived (traefik.routerName), so match its shape.
    # Every pattern is $-anchored: unanchored, port=22 also matches a wrong port=2222.
    grep -Eq 'traefik\.tcp\.routers\..+-ssh\.rule=HostSNI\(`\*`\)$' <<<"$labels" \
      || note "ssh.mode traefik did not render the HostSNI(\`*\`) TCP rule (raw SSH has no SNI to match)"
    grep -Eq 'traefik\.tcp\.routers\..+-ssh\.entrypoints=gitlab-ssh$' <<<"$labels" \
      || note "ssh.mode traefik did not bind the TCP router to the ssh.entrypoint"
    # sshd is pinned to 22 inside the image; routing anywhere else cannot work.
    grep -Eq 'traefik\.tcp\.services\..+-ssh\.loadbalancer\.server\.port=22$' <<<"$labels" \
      || note "the SSH TCP service must target container port 22 (the image's sshd_config hard-codes it)"
    [ -n "$advertised" ] || note "ssh.mode traefik did not set gitlab_shell_ssh_port"
    ;;
esac

# 5. persistence: the three state directories and the data pin travel together.
pin="$(yq -r '[.services.gitlab.deploy.placement.constraints // [] | .[] | select(test("node.labels"))] | length' "$out")"
state_mounts="$(grep -cE ':(/etc/gitlab|/var/opt/gitlab|/var/log/gitlab)$' <<<"$mounts" || true)"
case "$case" in
  ephemeral)
    [ "$pin" = "0" ] || note "ephemeral (persistence off) still rendered a node pin"
    [ "$state_mounts" = "0" ] || note "ephemeral (persistence off) still mounted state directories"
    [ "$(yq -r '.volumes // {} | length' "$out")" = "0" ] || note "ephemeral rendered top-level named volumes"
    ;;
  no-nodepin)
    [ "$pin" = "0" ] || note "no-nodepin (nodeLabel: \"\") still rendered a node.labels pin"
    [ "$state_mounts" = "3" ] || note "no-nodepin dropped a state volume (only the pin should go), got $state_mounts"
    ;;
  bind-mount)
    [ "$pin" = "1" ] || note "expected exactly one node.labels data pin, got $pin"
    [ "$state_mounts" = "3" ] || note "expected all three state directories mounted, got $state_mounts"
    [ "$(yq -r '.volumes // {} | length' "$out")" = "0" ] \
      || note "bind-mount rendered named volumes alongside the host paths (the *Path values must suppress them)"
    grep -E '^/[^:]+:' <<<"$mounts" >/dev/null || note "bind-mount fixture rendered no host-path mount"
    ;;
  *)
    [ "$pin" = "1" ] || note "expected exactly one node.labels data pin, got $pin"
    [ "$state_mounts" = "3" ] || note "expected all three state directories mounted, got $state_mounts"
    [ "$(yq -r '.volumes // {} | length' "$out")" = "3" ] || note "expected three named volumes"
    ;;
esac

# 6. /dev/shm. `shm_size` is dropped silently by `docker stack deploy` and the v3.9 schema
#    types tmpfs.size as an INTEGER — "256m" passes `docker compose config` (a different
#    parser) and then fails at deploy, so assert both the shape and the type.
shm="$(yq -r '[.services.gitlab.volumes // [] | .[] | select((. | tag) == "!!map") | select(.target == "/dev/shm")] | .[0]' "$out")"
[ "$shm" != "null" ] || note "no /dev/shm tmpfs mount rendered (GitLab needs >= 256 MiB or Puma/Sidekiq fail with 'unmapped file')"
if [ "$shm" != "null" ]; then
  [ "$(yq -r '.type' <<<"$shm")" = "tmpfs" ] || note "/dev/shm mount is not type tmpfs"
  if [ "$(yq -r '.tmpfs.size | tag' <<<"$shm")" = "!!int" ]; then
    [ "$(yq -r '.tmpfs.size' <<<"$shm")" -ge 268435456 ] || note "/dev/shm is smaller than the 256 MiB GitLab needs"
  else
    note "/dev/shm tmpfs.size is not an integer — the compose v3.9 schema rejects a unit suffix at deploy time"
  fi
fi
grep -F 'shm_size' "$out" >/dev/null && note "shm_size is set — docker stack deploy drops it silently; use the tmpfs mount"

# 7. Credentials. Every password-shaped setting must be a File.read of a mounted secret, and
#    every secret the service mounts must be declared external (a chart never creates one).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -F 'File.read("/run/secrets/' <<<"$line" >/dev/null \
    || note "a password setting is not read from a mounted secret: ${line%%=*}"
done <<<"$(grep -E "^gitlab_rails\['(smtp_password|initial_root_password)'\]" <<<"$generated" || true)"

svc_secrets="$(yq -r '.services.gitlab.secrets // [] | .[]' "$out")"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ "$(yq -r ".secrets.\"$s\".external // false" "$out")" = "true" ] \
    || note "secret $s is mounted but not declared external"
  grep -F "File.read(\"/run/secrets/$s\")" <<<"$generated" >/dev/null \
    || note "secret $s is mounted but never read by the omnibus config"
done <<<"$svc_secrets"

case "$case" in
  smtp|minimal)
    grep -F "gitlab_rails['smtp_password']" <<<"$generated" >/dev/null || note "$case: SMTP password setting missing" ;;
  smtp-noauth)
    grep -F "gitlab_rails['smtp_password']" <<<"$generated" >/dev/null \
      && note "authentication: none must not reference a password secret"
    [ -z "$svc_secrets" ] || note "smtp-noauth mounted a secret it does not need" ;;
  root-password)
    grep -F "gitlab_rails['initial_root_password']" <<<"$generated" >/dev/null \
      || note "root-password fixture did not seed initial_root_password" ;;
esac

# 8. Rollout safety. All of GitLab's state is on one node-local volume set, so the task must
#    be single and must never overlap itself, and the health probe must allow a cold boot.
[ "$(yq -r '.services.gitlab.deploy.replicas' "$out")" = "1" ] || note "replicas must be 1 (one volume set, one Postgres)"
[ "$(yq -r '.services.gitlab.deploy.update_config.order' "$out")" = "stop-first" ] \
  || note "update_config.order must be stop-first, or a rollout runs two GitLabs against one database"
[ "$(yq -r '.services.gitlab.healthcheck.start_period // ""' "$out")" != "" ] \
  || note "no healthcheck start_period — the image's own probe has none and Swarm restart-loops a cold boot"
[ "$(yq -r '.services.gitlab.stop_grace_period // ""' "$out")" != "" ] \
  || note "no stop_grace_period — Swarm's 10s default SIGKILLs Postgres mid-shutdown"

exit "$fail"
