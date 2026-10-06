#!/usr/bin/env bash
#
# Render assertions for the seaweedfs chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it guards is mostly what a deploy cannot see: every one of these mistakes still
# converges to a healthy task.
#
#   * SeaweedFS with no identity serves S3 to ANYONE. The credentials have to reach the
#     process from the secrets, and an empty secret has to stop the start, not open the
#     store.
#   * The master, volume and filer APIs are unauthenticated. If they bind the overlay,
#     every object is readable and writable without a key, while S3 itself still says 403.
#   * Without a filer signing key the S3 gateway's gRPC port accepts identity updates from
#     anyone on the overlay.
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

svc='.services.seaweedfs'
q() { yq -r "$1" "$rendered"; }

script="$(q "$svc.command[0]")"
args="$(q "$svc.command[]" | sed 1d)"  # the script is one line; no slice syntax, older yq lacks it
[ -n "$script" ] && [ "$script" != "null" ] || bad "the service has no start-up script — every check below would pass vacuously"

# ── the wrapper and its exec target ───────────────────────────────────────────────────
[ "$(q "$svc.entrypoint | join(\" \")")" = "/bin/sh -c" ] \
  || bad "entrypoint is not [/bin/sh, -c]; the start-up script would not run"
grep -F 'exec /entrypoint.sh "$$@"' <<<"$script" >/dev/null \
  || bad "the wrapper does not exec the image entrypoint with its arguments — weed would not be PID 1, or would not start"
[ "$(sed -n 1p <<<"$args")" = "seaweedfs" ] \
  || bad "the first argument after the script is not the \$0 placeholder; 'server' would be swallowed as \$0"
[ "$(sed -n 2p <<<"$args")" = "server" ] || bad "the entrypoint is not asked for 'server'"
grep -Fx -- '-s3' <<<"$args" >/dev/null || bad "-s3 is missing: no S3 gateway would start"

# ── credentials ───────────────────────────────────────────────────────────────────────
access="$(q "$svc.secrets[0]")"
secret="$(q "$svc.secrets[1]")"
[ "$access" != "null" ] && [ "$secret" != "null" ] && [ "$access" != "$secret" ] \
  || bad "the service does not mount two distinct credential secrets (got '$access' / '$secret')"
for s in "$access" "$secret"; do
  [ "$(q ".secrets.\"$s\".external")" = "true" ] || bad "secret $s is not declared external: true"
done
grep -F "export AWS_ACCESS_KEY_ID=\"\$\$(cat /run/secrets/$access)\"" <<<"$script" >/dev/null \
  || bad "AWS_ACCESS_KEY_ID is not exported from /run/secrets/$access — SeaweedFS would know no identity and serve anonymously"
grep -F "export AWS_SECRET_ACCESS_KEY=\"\$\$(cat /run/secrets/$secret)\"" <<<"$script" >/dev/null \
  || bad "AWS_SECRET_ACCESS_KEY is not exported from /run/secrets/$secret"
grep -F "for s in $access $secret; do" <<<"$script" >/dev/null \
  && grep -F 'test -s "/run/secrets/$$s" ||' <<<"$script" >/dev/null \
  || bad "the wrapper does not refuse to start on a missing or empty secret — an empty one would turn authentication OFF"
# A single-$ expansion anywhere would be resolved by Docker at deploy time.
if grep -E '(^|[^$])\$[({A-Za-z@]' <<<"$script" >/dev/null; then
  bad "the start-up script has an unescaped \$ ($(grep -oE '(^|[^$])\$[({A-Za-z@][^ ]{0,20}' <<<"$script" | sed -n 1p)): Docker would interpolate it at deploy time"
fi
if [ "$(q "$svc.environment.AWS_SECRET_ACCESS_KEY")" != "null" ] || [ "$(q "$svc.environment.AWS_ACCESS_KEY_ID")" != "null" ]; then
  bad "a credential is set in environment:, where it lands in the manifest and docker inspect"
fi

# ── only S3 leaves the container ──────────────────────────────────────────────────────
grep -Fx -- '-ip=127.0.0.1' <<<"$args" >/dev/null && grep -Fx -- '-ip.bind=127.0.0.1' <<<"$args" >/dev/null \
  || bad "master/volume/filer are not bound to 127.0.0.1 — their unauthenticated APIs would be reachable from the overlay"
grep -Fx -- '-s3.ip.bind=0.0.0.0' <<<"$args" >/dev/null \
  || bad "the S3 gateway is not bound to 0.0.0.0 — it would follow -ip.bind onto loopback and nothing outside could reach it"
grep -Fx -- '-s3.port.iceberg=0' <<<"$args" >/dev/null && grep -Fx -- '-s3.port.lance=0' <<<"$args" >/dev/null \
  || bad "the Iceberg/Lance catalog listeners are not disabled"
grep -F 'export WEED_JWT_FILER_SIGNING_KEY="$$(head -c 32 /dev/urandom | base64)"' <<<"$script" >/dev/null \
  || bad "no per-start filer signing key: the S3 gRPC port would accept identity updates from anyone on the overlay"

# ── port wiring: one value drives listener, probe, edge target and publish target ────
port="$(sed -n 's/^-s3.port=\([0-9]*\)$/\1/p' <<<"$args")"
[ -n "$port" ] || bad "-s3.port is not rendered"
hc="$(q "$svc.healthcheck.test | join(\" \")")"
[ "$hc" = "CMD curl -fsS -o /dev/null http://127.0.0.1:$port/healthz" ] \
  || bad "the healthcheck does not probe /healthz on the S3 port $port (got: $hc)"

# ── one process owns /data ────────────────────────────────────────────────────────────
[ "$(q "$svc.deploy.replicas")" = "1" ] || bad "replicas is not 1: two weed servers would share one /data"
[ "$(q "$svc.deploy.update_config.order")" = "stop-first" ] \
  || bad "update_config.order is not stop-first: old and new tasks would briefly share /data"
[ "$(q "$svc.stop_grace_period")" != "null" ] || bad "no stop_grace_period"

# ── networks ──────────────────────────────────────────────────────────────────────────
nets="$(q "$svc.networks[]")"
grep -Fx seaweedfs-net <<<"$nets" >/dev/null || bad "the service is not on network.name (seaweedfs-net): other stacks could not reach it"
[ "$(q '.networks."seaweedfs-net".external')" = "true" ] || bad "seaweedfs-net is not external — it would be stack-scoped and unreachable by name from other stacks"

# ── exposure ──────────────────────────────────────────────────────────────────────────
labels="$(q "$svc.deploy.labels[]")"
case "$case" in
  traefik|edge)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public' \
             "traefik.http.services.ci.loadbalancer.server.port=$port"; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published in traefik mode"
    ;;
  published)
    [ "$(q "$svc.ports[0].target")" = "$port" ] && [ "$(q "$svc.ports[0].published")" = "18333" ] \
      || bad "case $case: the S3 port is not published as 18333 -> $port"
    ;;
  *)
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published although exposure.mode is none"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: Traefik labels rendered although exposure.mode is none"; fi
    want_nets=seaweedfs-net
    [ "$case" = "metrics" ] && want_nets="$(printf 'seaweedfs-net\nmonitoring')"
    [ "$nets" = "$want_nets" ] || bad "case $case: attached to $(tr '\n' ' ' <<<"$nets")instead of $(tr '\n' ' ' <<<"$want_nets")"
    ;;
esac

# ── metrics: opt-in, never published, one port value drives listener and label ──────
# A listener left on loopback still renders, labels and deploys cleanly — and every
# scrape fails. A label naming another port fails the same way.
if [ "$case" = "metrics" ]; then
  mport="$(sed -n 's/^-metricsPort=\([0-9]*\)$/\1/p' <<<"$args")"
  [ "$mport" = "9327" ] || bad "case $case: -metricsPort is '$mport', expected 9327"
  grep -Fx -- '-metricsIp=0.0.0.0' <<<"$args" >/dev/null \
    || bad "case $case: -metricsIp=0.0.0.0 is missing — the listener would follow -ip.bind onto loopback, out of Prometheus's reach"
  grep -Fx 'prometheus.io/scrape=true' <<<"$labels" >/dev/null || bad "case $case: label prometheus.io/scrape=true is missing"
  grep -Fx "prometheus.io/port=$mport" <<<"$labels" >/dev/null \
    || bad "case $case: label prometheus.io/port does not name the metrics port $mport (got: $(grep -F prometheus.io/port <<<"$labels" || echo none))"
  [ "$(q '.networks.monitoring.external')" = "true" ] || bad "case $case: the monitoring overlay is not external — Prometheus in another stack could not reach it"
  if q "$svc.ports[].target" | grep -Fx "$mport" >/dev/null; then bad "case $case: the metrics port is published; /metrics and /debug/pprof have no authentication"; fi
else
  if grep -E -- '^-metrics(Port|Ip)=' <<<"$args" >/dev/null; then bad "case $case: a metrics listener is rendered although metrics.enabled is off"; fi
  if grep -F 'prometheus.io/' <<<"$labels" >/dev/null; then bad "case $case: discovery labels are rendered although metrics.enabled is off"; fi
  if grep -Fx monitoring <<<"$nets" >/dev/null; then bad "case $case: attached to the monitoring overlay although metrics.enabled is off"; fi
fi
case "$case" in
  traefik)
    grep -Fx 'traefik.http.routers.ci-http.middlewares=https-redirect' <<<"$labels" >/dev/null \
      || bad "case $case: tls is on but HTTP does not redirect"
    grep -Fx 'traefik.http.routers.ci-https.rule=Host(`s3-cache.example.com`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTPS router for ingress.host"
    grep -Fx 'traefik.http.routers.ci-https.tls.certresolver=le' <<<"$labels" >/dev/null \
      || bad "case $case: the HTTPS router has no certresolver"
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
  grep -F '[ "$$code" = 409 ]' <<<"$script" >/dev/null \
    || bad "case $case: 409 (bucket exists) is not treated as done — every restart would retry for five minutes"
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
    grep -Fx '/tmp/seaweedfs-e2e/data:/data' <<<"$mounts" >/dev/null || bad "case $case: the host path is not bind-mounted at /data"
    [ "$(q ".volumes")" = "null" ] || bad "case $case: a named volume is declared although volumePath takes precedence"
    grep -Fx 'node.labels.seaweedfs-e2e-node == true' <<<"$constraints" >/dev/null || bad "case $case: the custom node pin is missing"
    ;;
  *)
    grep -Fx 'seaweedfs-data:/data' <<<"$mounts" >/dev/null || bad "case $case: the named volume is not mounted at /data"
    [ "$(q '.volumes."seaweedfs-data"')" != "null" ] || bad "case $case: the named volume is not declared at the top level"
    grep -Fx 'node.labels.seaweedfs-data == true' <<<"$constraints" >/dev/null || bad "case $case: the data node pin is missing"
    ;;
esac
if [ "$case" = "buckets" ]; then
  grep -Fx 'node.role == manager' <<<"$constraints" >/dev/null || bad "case $case: placement.constraints was not applied"
fi

exit "$fail"
