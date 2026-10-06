#!/usr/bin/env bash
#
# Render assertions for the rustfs chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it guards is mostly what a deploy cannot see: every one of these mistakes still
# converges to a healthy task.
#
#   * RustFS without credentials starts with the public default pair rustfsadmin /
#     rustfsadmin. The keys have to reach it from the secrets as *_FILE paths, never as
#     values, and the wrapper has to refuse an empty or default key.
#   * The console listener serves the S3 and admin API too, so it must exist only when
#     console.enabled, and be routed or published only then.
#   * A single `$` in the wrapper is interpolated by Docker at deploy time, so the secret
#     would be read on the deploying machine (or read as empty) instead of in the task.
#
# No check pipes into `grep -q` (scripts/lint.sh enforces it): match with `grep … >/dev/null`
# or a here-string.
set -euo pipefail

rendered="${1:?rendered stack file}"
case="${2:-}"

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -F mikefarah >/dev/null; then
  echo "    ERROR: mikefarah yq v4 is required by render-check.sh (a skipped check reads exactly like a passing one)" >&2
  exit 1
fi

fail=0
bad() { echo "    FAIL: $*" >&2; fail=1; }

svc='.services.rustfs'
q() { yq -r "$1" "$rendered"; }

script="$(q "$svc.command[0]")"
[ -n "$script" ] && [ "$script" != "null" ] || bad "the service has no start-up script — every check below would pass vacuously"
env_() { q "$svc.environment.$1"; }

# ── the wrapper and its exec target ───────────────────────────────────────────────────
[ "$(q "$svc.entrypoint | join(\" \")")" = "/bin/sh -c" ] \
  || bad "entrypoint is not [/bin/sh, -c]; the start-up script would not run"
[ "$(q "$svc.command | length")" = "1" ] || bad "command has more than the script; the extra words would become \$0 and \$@"
grep -E 'exec /entrypoint.sh rustfs$' <<<"$script" >/dev/null \
  || bad "the wrapper does not end by exec'ing the image entrypoint — rustfs would not be PID 1, or would not start"

# ── credentials ───────────────────────────────────────────────────────────────────────
access="$(q "$svc.secrets[0]")"
secret="$(q "$svc.secrets[1]")"
[ "$access" != "null" ] && [ "$secret" != "null" ] && [ "$access" != "$secret" ] \
  || bad "the service does not mount two distinct credential secrets (got '$access' / '$secret')"
for s in "$access" "$secret"; do
  [ "$(q ".secrets.\"$s\".external")" = "true" ] || bad "secret $s is not declared external: true"
done
[ "$(env_ RUSTFS_ACCESS_KEY_FILE)" = "/run/secrets/$access" ] \
  || bad "RUSTFS_ACCESS_KEY_FILE is not /run/secrets/$access — RustFS would fall back to rustfsadmin"
[ "$(env_ RUSTFS_SECRET_KEY_FILE)" = "/run/secrets/$secret" ] \
  || bad "RUSTFS_SECRET_KEY_FILE is not /run/secrets/$secret"
for v in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY RUSTFS_ROOT_USER RUSTFS_ROOT_PASSWORD \
         MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_ROOT_USER MINIO_ROOT_PASSWORD \
         MINIO_ACCESS_KEY_FILE MINIO_SECRET_KEY_FILE; do
  [ "$(env_ "$v")" = "null" ] || bad "$v is set in environment:, where it lands in the manifest and docker inspect (and conflicts with the _FILE variant)"
done
grep -F 'for f in "$$RUSTFS_ACCESS_KEY_FILE" "$$RUSTFS_SECRET_KEY_FILE"; do' <<<"$script" >/dev/null \
  && grep -F 'w="$$(wc -w 2>/dev/null < "$$f"' <<<"$script" >/dev/null \
  && grep -F 'if [ "$${w:-0}" != 1 ]; then echo' <<<"$script" >/dev/null \
  || bad "the wrapper does not refuse an empty key, or one with whitespace inside it"
# Comparing only the alphanumerics: RustFS trims every Unicode space, so a check that
# strips less lets `rustfsadmin` plus a vertical tab or a no-break space through.
grep -F 'if [ "$$(LC_ALL=C tr -cd '"'"'[:alnum:]'"'"' < "$$f")" = rustfsadmin ]; then echo' <<<"$script" >/dev/null \
  || bad "the wrapper does not refuse the public default rustfsadmin (compared on alphanumerics only)"
# A key on a command line is readable in /proc/<pid>/cmdline and exec audit logs.
if grep -E -- '(--user|-u) ' <<<"$script" >/dev/null; then
  bad "the wrapper passes credentials to curl as an argument; feed them through -K - instead"
fi
# A single-$ expansion anywhere would be resolved by Docker at deploy time.
if grep -E '(^|[^$])\$[({A-Za-z@]' <<<"$script" >/dev/null; then
  bad "the start-up script has an unescaped \$ ($(grep -oE '(^|[^$])\$[({A-Za-z@][^ ]{0,20}' <<<"$script" | sed -n 1p)): Docker would interpolate it at deploy time"
fi

# ── port wiring: one value drives listener, probe, edge target and publish target ────
port="$(env_ RUSTFS_ADDRESS | sed -n 's/^:\([0-9]*\)$/\1/p')"
[ "$port" = "9000" ] || bad "RUSTFS_ADDRESS is not :9000 (got '$(env_ RUSTFS_ADDRESS)')"
hc="$(q "$svc.healthcheck.test | join(\" \")")"
[ "$hc" = "CMD curl -fsS -o /dev/null http://127.0.0.1:$port/health/ready" ] \
  || bad "the healthcheck does not probe /health/ready on the S3 port $port (got: $hc)"
[ "$(env_ RUSTFS_OBS_LOG_DIRECTORY)" = "" ] || bad "RUSTFS_OBS_LOG_DIRECTORY is not empty: the server log would go to a file inside the container, not docker service logs"
[ "$(env_ RUSTFS_CHECK_UPDATE)" = "false" ] || bad "RUSTFS_CHECK_UPDATE is not false"
[ "$(q "$svc.ulimits.nofile.soft")" = "65536" ] || bad "the nofile ulimit is not raised; RustFS disables its fd cache below 16384"

# ── one process owns /data ────────────────────────────────────────────────────────────
[ "$(q "$svc.deploy.replicas")" = "1" ] || bad "replicas is not 1: two servers would share one /data"
[ "$(q "$svc.deploy.update_config.order")" = "stop-first" ] \
  || bad "update_config.order is not stop-first: old and new tasks would briefly share /data"
[ "$(q "$svc.stop_grace_period")" != "null" ] || bad "no stop_grace_period"

# ── networks ──────────────────────────────────────────────────────────────────────────
nets="$(q "$svc.networks[]")"
grep -Fx rustfs-net <<<"$nets" >/dev/null || bad "the service is not on network.name (rustfs-net): other stacks could not reach it"
[ "$(q '.networks."rustfs-net".external')" = "true" ] || bad "rustfs-net is not external — it would be stack-scoped and unreachable by name from other stacks"

# ── the console: a second listener with the full API, only when asked for ─────────────
case "$case" in traefik|published) console=1 ;; *) console="" ;; esac
labels="$(q "$svc.deploy.labels[]")"
if [ -n "$console" ]; then
  [ "$(env_ RUSTFS_CONSOLE_ENABLE)" = "true" ] || bad "case $case: console.enabled but RUSTFS_CONSOLE_ENABLE is not true"
  [ "$(env_ RUSTFS_CONSOLE_ADDRESS)" = ":9001" ] || bad "case $case: the console does not listen on :9001"
else
  [ "$(env_ RUSTFS_CONSOLE_ENABLE)" = "false" ] \
    || bad "case $case: RUSTFS_CONSOLE_ENABLE is not false — RustFS turns the console ON when it is unset"
  [ "$(env_ RUSTFS_CONSOLE_ADDRESS)" = "null" ] || bad "case $case: a console address is set although the console is off"
  if grep -F 'console' <<<"$labels" >/dev/null; then bad "case $case: a console router is rendered although the console is off"; fi
fi

# ── exposure ──────────────────────────────────────────────────────────────────────────
case "$case" in
  traefik|edge)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public' \
             "traefik.http.services.ci.loadbalancer.server.port=$port" 'traefik.http.routers.ci-http.service=ci'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published in traefik mode"
    [ "$(env_ RUSTFS_HTTP1_HEADER_READ_TIMEOUT)" = "120" ] \
      || bad "case $case: RustFS's idle timeout is not raised above Traefik's 90s upstream keep-alive — large PUTs would hit closed connections"
    ;;
  published)
    [ "$(q "$svc.ports[0].target")" = "$port" ] && [ "$(q "$svc.ports[0].published")" = "19000" ] \
      || bad "case $case: the S3 port is not published as 19000 -> $port"
    [ "$(q "$svc.ports[1].target")" = "9001" ] && [ "$(q "$svc.ports[1].published")" = "19001" ] \
      || bad "case $case: the console port is not published as 19001 -> 9001"
    ;;
  *)
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published although exposure.mode is none"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: Traefik labels rendered although exposure.mode is none"; fi
    [ "$nets" = "rustfs-net" ] || bad "case $case: attached to more than network.name: $(tr '\n' ' ' <<<"$nets")"
    ;;
esac
case "$case" in traefik|edge) ;; *)
  [ "$(env_ RUSTFS_HTTP1_HEADER_READ_TIMEOUT)" = "null" ] || bad "case $case: the idle timeout is raised outside traefik mode"
esac
case "$case" in
  traefik)
    grep -Fx 'traefik.http.routers.ci-http.middlewares=https-redirect' <<<"$labels" >/dev/null \
      || bad "case $case: tls is on but HTTP does not redirect"
    grep -Fx 'traefik.http.routers.ci-https.rule=Host(`s3-cache.example.com`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTPS router for ingress.host"
    grep -Fx 'traefik.http.routers.ci-https.tls.certresolver=le' <<<"$labels" >/dev/null \
      || bad "case $case: the HTTPS router has no certresolver"
    # Two Traefik services on one Swarm service: a router that does not name its own is
    # dropped by Traefik, so the HTTPS router would 404 while the console's works.
    grep -Fx 'traefik.http.routers.ci-https.service=ci' <<<"$labels" >/dev/null \
      || bad "case $case: the HTTPS router does not name its service"
    for l in 'traefik.http.routers.ci-console-https.rule=Host(`rustfs-console.example.com`)' \
             'traefik.http.routers.ci-console-https.service=ci-console' \
             'traefik.http.routers.ci-console-http.middlewares=https-redirect' \
             'traefik.http.services.ci-console.loadbalancer.server.port=9001'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: console label $l is missing"
    done
    ;;
  edge)
    if grep -F 'https' <<<"$labels" >/dev/null; then bad "case $case: tls is off but an https router or redirect is rendered"; fi
    grep -Fx 'traefik.http.routers.ci-http.rule=Host(`s3.e2e.test`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTP router for ingress.host"
    ;;
esac

# ── buckets ───────────────────────────────────────────────────────────────────────────
case "$case" in
  buckets) want='runner-cache e2e.second-bucket' ;;
  traefik|edge) want='runner-cache' ;;
  ephemeral) want='scratch' ;;
  *) want='' ;;
esac
if [ -n "$want" ]; then
  grep -F "for b in $want; do" <<<"$script" >/dev/null || bad "case $case: the bootstrap loop does not iterate exactly '$want'"
  grep -F "\"http://127.0.0.1:$port/\$\$b\"" <<<"$script" >/dev/null \
    || bad "case $case: buckets are not created against the S3 port $port"
  grep -F -- '--aws-sigv4' <<<"$script" >/dev/null || bad "case $case: bucket creation is not signed — it would be refused"
  grep -F '| curl -K - ' <<<"$script" >/dev/null \
    || bad "case $case: curl does not read the key pair from a config on stdin"
  grep -F '[ "$$code" = 200 ]' <<<"$script" >/dev/null \
    || bad "case $case: 200 is not treated as done — RustFS answers an existing bucket with 200, so every restart would retry for five minutes"
  grep -F '[ "$$code" = 409 ]' <<<"$script" >/dev/null \
    || bad "case $case: 409 (bucket exists) is not treated as done"
  grep -F ') & exec /entrypoint.sh' <<<"$script" >/dev/null \
    || bad "case $case: the bootstrap loop does not run in the background — it would block the server it waits for"
else
  if grep -F 'for b in' <<<"$script" >/dev/null; then bad "case $case: a bucket loop is rendered with no buckets"; fi
fi

# ── persistence and placement ─────────────────────────────────────────────────────────
mounts="$(q "$svc.volumes[]")"
constraints="$(q "$svc.deploy.placement.constraints[]")"
case "$case" in
  ephemeral)
    [ "$(q "$svc.volumes")" = "null" ] || bad "case $case: /data is mounted although persistence is off"
    [ "$(q ".volumes")" = "null" ] || bad "case $case: a top-level volume is declared although persistence is off"
    [ "$(q "$svc.deploy.placement")" = "null" ] || bad "case $case: a placement block is rendered although persistence is off"
    ;;
  bind-mount)
    grep -Fx '/tmp/rustfs-e2e/data:/data' <<<"$mounts" >/dev/null || bad "case $case: the host path is not bind-mounted at /data"
    [ "$(q ".volumes")" = "null" ] || bad "case $case: a named volume is declared although volumePath takes precedence"
    grep -Fx 'node.labels.rustfs-e2e-node == true' <<<"$constraints" >/dev/null || bad "case $case: the custom node pin is missing"
    ;;
  *)
    grep -Fx 'rustfs-data:/data' <<<"$mounts" >/dev/null || bad "case $case: the named volume is not mounted at /data"
    [ "$(q '.volumes."rustfs-data"')" != "null" ] || bad "case $case: the named volume is not declared at the top level"
    grep -Fx 'node.labels.rustfs-data == true' <<<"$constraints" >/dev/null || bad "case $case: the data node pin is missing"
    ;;
esac
if [ "$case" = "buckets" ]; then
  grep -Fx 'node.role == manager' <<<"$constraints" >/dev/null || bad "case $case: placement.constraints was not applied"
fi

exit "$fail"
