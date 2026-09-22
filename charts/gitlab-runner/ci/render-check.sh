#!/usr/bin/env bash
#
# Render assertions for the gitlab-runner chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it is here for: this chart's whole job is to turn values into a config.toml, and
# almost every way of getting that wrong still renders, compose-validates and DEPLOYS.
# Three verified failure modes it guards:
#
#   * gitlab-runner SILENTLY IGNORES unknown keys in config.toml — a run with a
#     deliberately bogus `BogusKeyThatDoesNotExist` logged "Configuration loaded" and
#     started normally. So a mis-cased `accesskey` instead of `AccessKey` deploys a healthy
#     runner whose distributed cache does nothing at all. The exact capitalisation asserted
#     below comes from the v19.4.0 source (cache/cacheconfig/cacheconfig.go toml tags).
#   * `${RUNNER_TOKEN}` must reach the manifest as `$${RUNNER_TOKEN}`. With one `$` Docker
#     interpolates it at deploy time, the runner reads an EMPTY token, and it then polls
#     GitLab forever with 403s that look like a revoked token.
#   * a runner with no token, a bogus token or an unreachable url starts, mints a system ID
#     and reports Running. Convergence proves nothing here, so the manifest has to.
#
# No check pipes into `grep -q`: under the `pipefail` below that makes a check that DID
# match report "no match" (scripts/lint.sh enforces this repo-wide). Match with
# `grep … >/dev/null`, or a here-string.
set -euo pipefail

rendered="${1:?rendered stack file}"
case="${2:-}"

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -F mikefarah >/dev/null; then
  echo "    ERROR: mikefarah yq v4 is required by render-check.sh (a skipped check reads exactly like a passing one)" >&2
  exit 1
fi

fail=0
bad() { echo "    FAIL: $*" >&2; fail=1; }

svc='.services.gitlab-runner'
q() { yq -r "$1" "$rendered"; }

# The generated config.toml and the start-up command, the two things every assertion reads.
toml="$(q "$svc.environment.RUNNER_CONFIG_TOML")"
cmd="$(q "$svc.command[0]")"

# ── the fixtures must not be vacuous ──────────────────────────────────────────────────
# Without this, every assertion below could pass on an empty string.
[ -n "$toml" ] && [ "$toml" != "null" ] || bad "RUNNER_CONFIG_TOML is empty — every TOML assertion below would pass vacuously"
[ -n "$cmd" ] && [ "$cmd" != "null" ] || bad "the service has no command — the config would never be written"

# ── the token path ────────────────────────────────────────────────────────────────────
token_secret="$(q "$svc.secrets[0]")"
grep -F 'token = "$${RUNNER_TOKEN}"' <<<"$toml" >/dev/null \
  || bad "config.toml does not carry token = \"\$\${RUNNER_TOKEN}\" (the runner expands it from its own env; the double \$ is what stops Docker expanding it first)"
# A single-$ occurrence anywhere is the interpolation bug. Count both spellings.
all_refs="$(grep -o -- '\${RUNNER_TOKEN}' <<<"$toml" | grep -c . || true)"
escaped_refs="$(grep -o -- '\$\${RUNNER_TOKEN}' <<<"$toml" | grep -c . || true)"
[ "$all_refs" = "$escaped_refs" ] \
  || bad "config.toml has an UNESCAPED \${RUNNER_TOKEN} ($all_refs references, $escaped_refs escaped): Docker would interpolate it away and the runner would authenticate with an empty token"
grep -F "cat /run/secrets/$token_secret" <<<"$cmd" >/dev/null \
  || bad "the command never reads /run/secrets/$token_secret, so RUNNER_TOKEN would be unset and the token would expand to nothing"
grep -F "test -s /run/secrets/$token_secret" <<<"$cmd" >/dev/null \
  || bad "the command does not check that /run/secrets/$token_secret is non-empty (an empty secret otherwise boots a runner that 403s forever)"
if grep -E 'glrt-' "$rendered" >/dev/null; then
  bad "the manifest contains a literal glrt- token; the token must only ever be a secret reference"
fi

# Every mounted secret must be declared external AND actually read by the command.
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ "$(q ".secrets.\"$s\".external")" = "true" ] \
    || bad "secret $s is mounted but not declared external: true"
  grep -F "/run/secrets/$s" <<<"$cmd" >/dev/null \
    || bad "secret $s is mounted but never read — a mount nothing reads is a mount that silently does nothing"
done < <(q "$svc.secrets[]")

# ── the engine socket ─────────────────────────────────────────────────────────────────
q "$svc.volumes[]" | grep -Fx '/var/run/docker.sock:/var/run/docker.sock' >/dev/null \
  || bad "the runner does not mount /var/run/docker.sock — with no engine it cannot create a job container at all"

# ── shutdown: the difference between draining jobs and killing them ───────────────────
[ "$(q "$svc.stop_signal")" = "SIGQUIT" ] \
  || bad "stop_signal is not SIGQUIT — SIGTERM/SIGINT ABORT running builds, SIGQUIT lets them finish"
grace="$(q "$svc.stop_grace_period")"
[ "$grace" != "null" ] || bad "no stop_grace_period: Swarm's 10s default SIGKILLs the runner mid-build on every update"
# stop_grace_period must outlast the runner's own shutdown_timeout, or Swarm kills it while
# it is still draining. One is a duration string, the other seconds.
secs() {
  local v="$1"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}
shutdown_timeout="$(grep -E '^shutdown_timeout = ' <<<"$toml" | sed -n 's/^shutdown_timeout = //p' || true)"
if [ -n "$shutdown_timeout" ] && [ "$grace" != "null" ]; then
  [ "$(secs "$grace")" -gt "$shutdown_timeout" ] \
    || bad "stop_grace_period ($grace) is not longer than config.toml shutdown_timeout (${shutdown_timeout}s): Swarm would SIGKILL the runner while it is still draining jobs"
fi
[ "$(q "$svc.deploy.update_config.order")" = "stop-first" ] \
  || bad "update_config.order is not stop-first: two tasks would briefly share /etc/gitlab-runner and collide on .runner_system_id"

# ── the runner block ──────────────────────────────────────────────────────────────────
runner_blocks="$(grep -c '^\[\[runners\]\]' <<<"$toml" || true)"
[ "$runner_blocks" = "1" ] || bad "config.toml declares $runner_blocks [[runners]] sections, expected exactly 1"
grep -E '^  executor = "docker"$' <<<"$toml" >/dev/null || bad "config.toml does not set executor = \"docker\""
grep -E '^  request_concurrency = [1-9]' <<<"$toml" >/dev/null \
  || bad "request_concurrency is unset or 0; 1 bottlenecks long polling and the runner warns about it on every start"

# ── metrics: opt-in, and never published ──────────────────────────────────────────────
# The endpoint is unauthenticated, so publishing it is a defect, not a preference.
[ "$(q "$svc.ports")" = "null" ] \
  || bad "the service publishes a port; /metrics and /debug/pprof carry no authentication and this chart must never expose them"
listen="$(grep -E '^listen_address = ' <<<"$toml" | sed -n 's/^listen_address = //p' | tr -d '"' || true)"
hc="$(q "$svc.healthcheck.test")"
# Keyed on the manifest, not on the case name, so a new fixture cannot slip past it: the
# probe and the listener are one feature and must appear together or not at all.
if [ -n "$listen" ]; then
  grep -E '^0\.0\.0\.0:[0-9]+$' <<<"$listen" >/dev/null \
    || bad "listen_address is '$listen'; expected the 0.0.0.0:<port> form"
  port="${listen#0.0.0.0:}"
  # Only one direction is required: the probe needs the listener, not the other way round.
  # Metrics without a probe is a reasonable thing to run (scrape it, but do not let a probe
  # failure restart a runner mid-job), so it must not be asserted away — ci/metrics-only.
  if [ "$hc" != "null" ]; then
    grep -F "$port/metrics" <<<"$hc" >/dev/null \
      || bad "the healthcheck does not probe port $port, the one the runner was told to listen on"
  fi
else
  [ "$hc" = "null" ] \
    || bad "a healthcheck is rendered with metrics off — it probes /metrics, so it could never pass"
fi
# The fixtures that exist to cover this must not quietly stop covering it.
case "$case" in
  metrics|metrics-only|mock)
    [ -n "$listen" ] || bad "case $case: metrics are off, so this fixture no longer exercises the listener"
    ;;
esac
# And the fixture that exists to cover the metrics-without-a-probe mode must keep covering it.
if [ "$case" = "metrics-only" ]; then
  [ "$hc" = "null" ] || bad "case $case: a healthcheck is rendered, so this fixture no longer covers metrics without a probe"
fi
if [ "$case" = "metrics" ]; then
  [ "$hc" != "null" ] || bad "case $case: no healthcheck is rendered, so this fixture no longer covers the probe"
fi

# ── placement: the pin must follow the node label, in every persistence mode ──────────
constraints="$(q "$svc.deploy.placement.constraints")"
case "$case" in
  ephemeral|scaleout)
    [ "$constraints" = "null" ] \
      || bad "case $case: a placement constraint is rendered although persistence.nodeLabel is empty — the task would sit Pending on a label nobody set"
    ;;
  bind-mount)
    grep -F 'node.labels.runner-node == true' <<<"$constraints" >/dev/null \
      || bad "case $case: the node pin for persistence.nodeLabel=runner-node is missing"
    ;;
  default|metrics|metrics-only|mock|cache|cache-iam|dind|extra-toml)
    grep -F 'node.labels.gitlab-runner-data == true' <<<"$constraints" >/dev/null \
      || bad "case $case: the default node pin is missing; the runner would be free to reschedule away from its volume and its warm image cache"
    ;;
esac

# ── persistence: the volume and its declaration move together ─────────────────────────
mounts="$(q "$svc.volumes[]")"
case "$case" in
  ephemeral|scaleout)
    if grep -F ':/etc/gitlab-runner' <<<"$mounts" >/dev/null; then
      bad "case $case: /etc/gitlab-runner is mounted although persistence is off"
    fi
    [ "$(q ".volumes")" = "null" ] || bad "case $case: a top-level volume is declared although persistence is off"
    ;;
  bind-mount)
    grep -Fx '/tmp/gitlab-runner-e2e/config:/etc/gitlab-runner' <<<"$mounts" >/dev/null \
      || bad "case $case: the host path is not bind-mounted at /etc/gitlab-runner"
    [ "$(q ".volumes")" = "null" ] \
      || bad "case $case: a named volume is still declared although volumePath takes precedence"
    ;;
  *)
    grep -Fx 'gitlab-runner-config:/etc/gitlab-runner' <<<"$mounts" >/dev/null \
      || bad "case $case: the named volume is not mounted at /etc/gitlab-runner, so .runner_system_id would be re-minted on every restart"
    [ "$(q ".volumes.gitlab-runner-config")" != "null" ] \
      || bad "case $case: the named volume is mounted but not declared at the top level"
    ;;
esac

# ── the distributed cache ─────────────────────────────────────────────────────────────
# Capitalisation is copied from the runner's own toml tags on purpose: it ignores keys it
# does not know, so `accesskey` or `servername` would disable the cache in silence.
if [ "$case" = "cache" ] || [ "$case" = "cache-iam" ] || [ "$case" = "cache-path" ]; then
  grep -E '^  \[runners\.cache\]$' <<<"$toml" >/dev/null || bad "case $case: no [runners.cache] table"
  grep -E '^    Type = "s3"$' <<<"$toml" >/dev/null || bad "case $case: [runners.cache] Type is not exactly \"s3\""
  grep -E '^    Shared = (true|false)$' <<<"$toml" >/dev/null || bad "case $case: [runners.cache] Shared is missing or not a bool"
  grep -E '^    \[runners\.cache\.s3\]$' <<<"$toml" >/dev/null || bad "case $case: no [runners.cache.s3] table"
  for key in ServerAddress BucketName Insecure AuthenticationType; do
    grep -E "^      $key = " <<<"$toml" >/dev/null \
      || bad "case $case: [runners.cache.s3] $key is missing or mis-cased (the runner would ignore it silently)"
  done
  # ── bucket addressing ───────────────────────────────────────────────────────────────
  # PathStyle is a *bool upstream (cache/cacheconfig/cacheconfig.go:45 at v19.4.0), so an
  # ABSENT key is not the same as `false`: absent selects the runner's own detection, which
  # picks path-style for MinIO and virtual-host for AWS, while `false` forces virtual-host
  # on every endpoint. Forcing it on a MinIO with no wildcard DNS breaks the cache at JOB
  # time, in a job log, with "no such host" on a hostname the operator never typed — so the
  # default emitting nothing is the assertion that matters most in this file.
  case "$case" in
    cache)
      if grep -E '^      PathStyle = ' <<<"$toml" >/dev/null; then
        bad "case $case: PathStyle is rendered although addressing is the default auto — that suppresses the runner's own endpoint detection"
      fi
      ;;
    cache-path)
      grep -E '^      PathStyle = true$' <<<"$toml" >/dev/null \
        || bad "case $case: addressing: path did not render PathStyle = true"
      ;;
    cache-iam)
      grep -E '^      PathStyle = false$' <<<"$toml" >/dev/null \
        || bad "case $case: addressing: virtual did not render PathStyle = false"
      ;;
  esac

  # The credentials are appended by the container, so the s3 table has to be last.
  last_table="$(grep -E '^ *\[+runners' <<<"$toml" | sed -n '$p' | sed 's/^ *//')"
  [ "$last_table" = "[runners.cache.s3]" ] \
    || bad "case $case: the last table in config.toml is '$last_table', not [runners.cache.s3] — the AccessKey/SecretKey lines the container appends would land in the wrong table"
fi
case "$case" in
  cache)
    grep -F "AccessKey = '%s'" <<<"$cmd" >/dev/null \
      || bad "case $case: the command does not append AccessKey from the mounted secret"
    grep -F "SecretKey = '%s'" <<<"$cmd" >/dev/null \
      || bad "case $case: the command does not append SecretKey from the mounted secret"
    grep -E "^      AuthenticationType = \"access-key\"$" <<<"$toml" >/dev/null \
      || bad "case $case: AuthenticationType is not access-key although key secrets are mounted"
    for s in gitlab-runner-cache-access-key gitlab-runner-cache-secret-key; do
      q "$svc.secrets[]" | grep -Fx "$s" >/dev/null || bad "case $case: secret $s is not mounted"
    done
    ;;
  cache-iam|cache-path)
    if grep -F "AccessKey = '%s'" <<<"$cmd" >/dev/null; then
      bad "case $case: the command appends AccessKey although authenticationType is iam"
    fi
    if q "$svc.secrets[]" | grep -F 'cache' >/dev/null; then
      bad "case $case: a cache secret is mounted although authenticationType iam needs none"
    fi
    ;;
  *)
    if grep -E '^  \[runners\.cache\]$' <<<"$toml" >/dev/null; then
      bad "case $case: a [runners.cache] table is rendered although cache.enabled is false"
    fi
    ;;
esac

# ── the privileged / socket-in-jobs grants ────────────────────────────────────────────
case "$case" in
  dind)
    grep -E '^    privileged = true$' <<<"$toml" >/dev/null \
      || bad "case $case: privileged = true is missing, so docker:dind jobs would fail"
    grep -E '^    volumes = .*"/var/run/docker\.sock:/var/run/docker\.sock"' <<<"$toml" >/dev/null \
      || bad "case $case: mountSocketInJobs is on but the socket is not in the job volumes"
    grep -E '^    allowed_images = ' <<<"$toml" >/dev/null || bad "case $case: allowed_images is missing"
    ;;
  *)
    grep -E '^    privileged = false$' <<<"$toml" >/dev/null \
      || bad "case $case: privileged is not explicitly false — leave no doubt about which jobs get to disable their own isolation"
    if grep -E '^    volumes = .*docker\.sock' <<<"$toml" >/dev/null; then
      bad "case $case: the engine socket is exposed to JOB containers although mountSocketInJobs is off"
    fi
    ;;
esac

# ── verbatim TOML lands where it is documented to land ────────────────────────────────
if [ "$case" = "extra-toml" ]; then
  grep -F '[session_server]' <<<"$toml" >/dev/null || bad "case $case: config.extraGlobalToml was not emitted"
  grep -F 'memory_swap = "4g"' <<<"$toml" >/dev/null || bad "case $case: config.extraDockerToml was not emitted"
  # Global before [[runners]], docker extras after [runners.docker]: the insertion points
  # the values.yaml comments promise.
  global_line="$(grep -n -F '[session_server]' <<<"$toml" | sed -n 's/^\([0-9]*\).*/\1/p' | sed -n 1p)"
  runners_line="$(grep -n -E '^\[\[runners\]\]$' <<<"$toml" | sed -n 's/^\([0-9]*\).*/\1/p' | sed -n 1p)"
  docker_line="$(grep -n -E '^  \[runners\.docker\]$' <<<"$toml" | sed -n 's/^\([0-9]*\).*/\1/p' | sed -n 1p)"
  swap_line="$(grep -n -F 'memory_swap = "4g"' <<<"$toml" | sed -n 's/^\([0-9]*\).*/\1/p' | sed -n 1p)"
  [ "$global_line" -lt "$runners_line" ] \
    || bad "case $case: extraGlobalToml landed after [[runners]], so its keys belong to the runner instead of the global table"
  [ "$swap_line" -gt "$docker_line" ] \
    || bad "case $case: extraDockerToml landed before [runners.docker], so its keys belong to the wrong table"
  grep -E '^  environment = \[' <<<"$toml" >/dev/null || bad "case $case: runner.environment was not emitted"
  grep -E '^  limit = 2$' <<<"$toml" >/dev/null || bad "case $case: runner.limit was not emitted"
  grep -E '^  name = "swarm-docker-1"$' <<<"$toml" >/dev/null || bad "case $case: gitlab.name was not used as the runner name"
fi

# ── scale-out shape ───────────────────────────────────────────────────────────────────
if [ "$case" = "scaleout" ]; then
  [ "$(q "$svc.deploy.replicas")" = "3" ] || bad "case $case: replicas is not 3"
  [ "$(q "$svc.deploy.resources.limits.memory")" = "256M" ] || bad "case $case: the memory limit is missing"
fi

exit "$fail"
