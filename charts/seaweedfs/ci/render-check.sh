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
#   * The admin UI (admin.enabled) is one password away from every object. That password
#     must reach weed admin alone, never weed server or an argv, and the UI must stay off
#     the S3 API's routers, ports and health. The guards are rendered below with $SWARMCLI.
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
grep -Fx -- '-master.telemetry=false' <<<"$args" >/dev/null \
  || bad "telemetry is not switched off: weed would report cluster statistics to telemetry.seaweedfs.com"
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
# The admin routers' rule after Host(): /metrics needs no login, and weed admin checks no CSRF
# token on most writes, so anything but GET/HEAD a browser marks same-site or cross-site is
# refused at the edge (the session cookie is SameSite=Lax, so same-site would carry it). An
# encoded slash is refused too: Traefik matches the escaped path, weed admin the decoded one.
admin_guard='!PathPrefix(`/metrics`) && !PathRegexp(`(?i)%2f`) && (Method(`GET`) || Method(`HEAD`) || !HeaderRegexp(`Sec-Fetch-Site`, `^(cross|same)-site`))'
# The routes that return stored files or their metadata ride a router of their own whose
# responses are sandboxed: weed admin serves an uploaded SVG inline, script and all.
content_paths='(Path(`/api/files/download`) || Path(`/api/files/view`) || Path(`/api/files/metadata`))'
case "$case" in
  traefik|edge)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public' \
             "traefik.http.services.ci.loadbalancer.server.port=$port" 'traefik.http.routers.ci-http.service=ci'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published in traefik mode"
    ;;
  admin-traefik|admin-edge)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public although the admin UI is routed"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public' \
             'traefik.http.services.ci-admin.loadbalancer.server.port=23646' 'traefik.http.routers.ci-admin-http.service=ci-admin'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    if grep -E '^traefik\.http\.(routers\.ci-https?|services\.ci)\.' <<<"$labels" >/dev/null; then
      bad "case $case: the S3 API is routed although exposure.mode is none"
    fi
    for l in 'traefik.http.middlewares.ci-admin-sandbox.headers.contentSecurityPolicy=sandbox' \
             'traefik.http.middlewares.ci-admin-sandbox.headers.contentTypeNosniff=true' \
             'traefik.http.routers.ci-admin-content-http.service=ci-admin'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    # The sandbox would stop the UI's own scripts, so only the content router may carry it.
    [ "$(grep -c '=ci-admin-sandbox$' <<<"$labels")" = "1" ] \
      && grep -E '^traefik\.http\.routers\.ci-admin-content-https?\.middlewares=ci-admin-sandbox$' <<<"$labels" >/dev/null \
      || bad "case $case: the sandbox middleware is not on exactly the content router"
    if grep -F 'traefik.http.services.ci-admin-content.' <<<"$labels" >/dev/null; then
      bad "case $case: the content router has a service of its own instead of the admin UI's"
    fi
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published although nothing is in published mode"
    ;;
  published)
    [ "$(q "$svc.ports[0].target")" = "$port" ] && [ "$(q "$svc.ports[0].published")" = "18333" ] \
      || bad "case $case: the S3 port is not published as 18333 -> $port"
    ;;
  admin-published)
    [ "$(q "$svc.ports | length")" = "1" ] && [ "$(q "$svc.ports[0].target")" = "23646" ] && [ "$(q "$svc.ports[0].published")" = "24646" ] \
      || bad "case $case: not exactly the admin UI is published, as 24646 -> 23646"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: Traefik labels rendered although nothing is routed"; fi
    [ "$nets" = "seaweedfs-net" ] || bad "case $case: attached to more than network.name: $(tr '\n' ' ' <<<"$nets")"
    ;;
  *)
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published although exposure.mode is none"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: Traefik labels rendered although exposure.mode is none"; fi
    [ "$nets" = "seaweedfs-net" ] || bad "case $case: attached to more than network.name: $(tr '\n' ' ' <<<"$nets")"
    ;;
esac
case "$case" in
  traefik)
    grep -Fx 'traefik.http.routers.ci-http.middlewares=https-redirect' <<<"$labels" >/dev/null \
      || bad "case $case: tls is on but HTTP does not redirect"
    grep -Fx 'traefik.http.routers.ci-https.rule=Host(`s3-cache.example.com`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTPS router for ingress.host"
    grep -Fx 'traefik.http.routers.ci-https.tls.certresolver=le' <<<"$labels" >/dev/null \
      || bad "case $case: the HTTPS router has no certresolver"
    grep -Fx 'traefik.http.routers.ci-https.service=ci' <<<"$labels" >/dev/null \
      || bad "case $case: the HTTPS router does not name its service"
    ;;
  admin-traefik)
    for l in 'traefik.http.routers.ci-admin-http.middlewares=https-redirect' \
             "traefik.http.routers.ci-admin-https.rule=Host(\`seaweedfs-admin.example.com\`) && $admin_guard" \
             'traefik.http.routers.ci-admin-https.tls=true' 'traefik.http.routers.ci-admin-https.tls.certresolver=le' \
             'traefik.http.routers.ci-admin-https.service=ci-admin' \
             'traefik.http.routers.ci-admin-content-http.middlewares=https-redirect' \
             "traefik.http.routers.ci-admin-content-https.rule=Host(\`seaweedfs-admin.example.com\`) && $admin_guard && $content_paths" \
             'traefik.http.routers.ci-admin-content-https.tls=true' 'traefik.http.routers.ci-admin-content-https.tls.certresolver=le' \
             'traefik.http.routers.ci-admin-content-https.service=ci-admin' 'traefik.http.routers.ci-admin-content-https.middlewares=ci-admin-sandbox'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    ;;
  admin-edge)
    if grep -F 'https' <<<"$labels" >/dev/null; then bad "case $case: tls is off but an https router or redirect is rendered"; fi
    grep -Fx "traefik.http.routers.ci-admin-http.rule=Host(\`admin.e2e.test\`) && $admin_guard" <<<"$labels" >/dev/null \
      || bad "case $case: no HTTP router for admin.ingress.host that keeps /metrics and cross-site writes off the edge"
    for l in "traefik.http.routers.ci-admin-content-http.rule=Host(\`admin.e2e.test\`) && $admin_guard && $content_paths" \
             'traefik.http.routers.ci-admin-content-http.middlewares=ci-admin-sandbox'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    ;;
  edge)
    if grep -F 'https' <<<"$labels" >/dev/null; then bad "case $case: tls is off but an https router or redirect is rendered"; fi
    grep -Fx 'traefik.http.routers.ci-http.rule=Host(`s3.e2e.test`)' <<<"$labels" >/dev/null \
      || bad "case $case: no HTTP router for ingress.host"
    ;;
esac

# ── the admin UI ──────────────────────────────────────────────────────────────────────
pw=seaweedfs-admin-password
mounted="$(q "$svc.secrets[]")"
case "$case" in
  admin-*)
    grep -Fx "$pw" <<<"$mounted" >/dev/null && [ "$(q ".secrets.\"$pw\".external")" = "true" ] \
      || bad "case $case: the admin password secret is not mounted from an external secret"
    grep -F "test -s \"/run/secrets/$pw\" || { echo \"secret $pw is missing or empty - refusing to start the admin UI without a password\" >&2; exit 1; };" <<<"$script" >/dev/null \
      || bad "case $case: the wrapper does not refuse a missing or empty admin password"
    grep -F '( until curl -fs -o /dev/null --max-time 5 http://127.0.0.1:9333/cluster/status; do sleep 2; done; while :; do rc=0;' <<<"$script" >/dev/null \
      || bad "case $case: the admin loop does not wait for the master on 127.0.0.1"
    # The key is exported before the loop starts, so weed admin inherits it: without it the
    # filer refuses the admin's writes and user management fails.
    grep -F 'export WEED_JWT_FILER_SIGNING_KEY=' <<<"${script%%"( until curl"*}" >/dev/null \
      || bad "case $case: the admin loop starts before the filer signing key is exported — weed admin could not manage users"
    # Once per container start, outside the restart loop: a redeploy logs everyone out, so a
    # password change does too, while a crash of the UI alone does not.
    [ "$(grep -o 'rm -f /data/admin/.session_key;' <<<"$script" | wc -l | tr -d ' ')" = "1" ] \
      && grep -F 'rm -f /data/admin/.session_key;' <<<"${script%%"while :; do"*}" >/dev/null \
      || bad "case $case: the admin session key is not deleted exactly once per container start, before the restart loop — a password change would not log anyone out"
    want="( export WEED_ADMIN_PASSWORD=\"\$\$(cat /run/secrets/$pw)\" GODEBUG=fips140=on; exec su-exec seaweed weed -logtostderr=true admin -master=127.0.0.1:9333 -port=23646 -dataDir=/data/admin -adminUser=admin ) || rc=\$\$?;"
    grep -F -- "$want" <<<"$script" >/dev/null || bad "case $case: weed admin is not started as: $want"
    [ "$(grep -o WEED_ADMIN_PASSWORD <<<"$script" | wc -l | tr -d ' ')" = "1" ] \
      || bad "case $case: WEED_ADMIN_PASSWORD is set outside the admin's own subshell — weed server would hold the admin password"
    grep -F 'echo "weed admin exited (status $$rc) - restarting in 5s" >&2; sleep 5; done ) & ' <<<"$script" >/dev/null \
      || bad "case $case: weed admin is not restarted by a background loop — it would block the server, or stay down after one exit"
    ;;
  *)
    if grep -Fx "$pw" <<<"$mounted" >/dev/null || grep -F -e WEED_ADMIN_PASSWORD -e ' admin -master=' <<<"$script" >/dev/null; then
      bad "case $case: the admin UI is rendered although admin.enabled is false"
    fi
    ;;
esac

# ── buckets ───────────────────────────────────────────────────────────────────────────
case "$case" in
  buckets) want='runner-cache e2e.second-bucket' ;;
  traefik|edge) want='runner-cache' ;;
  ephemeral) want='scratch' ;;
  oidc) want='idp runner-cache reports' ;;
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

# ── the admin guards, rendered once with SWARMCLI (test-charts.sh sets it) ────────────
# From a copy without values.schema.json: the schema stops some of these first, and this
# proves the template's own guards, which a renderer without schema support relies on.
if [ "$case" = "admin-traefik" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R "$(cd "$(dirname "$0")/.." && pwd)" "$tmp/chart"
  rm "$tmp/chart/values.schema.json"
  render() { "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template ci "$tmp/chart" -f "$tmp/chart/ci/admin-traefik-values.yaml" "$@"; }
  refused() {
    local want="$1"; shift
    if render "$@" >/dev/null 2>"$tmp/err"; then
      bad "rendered with $* — it must be refused"
    elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
      bad "$* failed, but not with \"$want\": $(tail -1 "$tmp/err")"
    fi
  }
  refused "admin.passwordSecret is required" --set admin.passwordSecret=
  refused "admin.passwordSecret must name a secret of its own" --set admin.passwordSecret=seaweedfs-s3-access-key
  refused "admin.passwordSecret must name a secret of its own" --set admin.passwordSecret=seaweedfs-s3-secret-key
  refused "is not a valid login name" --set 'admin.user=a;b'
  # One per gRPC port: each also covers its HTTP twin, which an admin.port 10000 lower
  # reaches through the admin's own worker gRPC port.
  refused "admin.port 18333 collides" --set admin.port=18333
  refused "admin.port 19333 collides" --set admin.port=19333
  refused "admin.port 18080 collides" --set admin.port=18080
  refused "admin.port 18888 collides" --set admin.port=18888
  # Only its worker gRPC port (2000 + 10000) lands on the S3 port.
  refused "admin.port 2000 collides" --set s3.port=12000 --set admin.port=2000
  refused "admin.ingress.host is required" --set admin.ingress.host=
  refused "admin.ingress.host must differ from ingress.host" --set exposure.mode=traefik --set ingress.host=seaweedfs-admin.example.com
  refused "admin.publish.port must differ from publish.port" --set exposure.mode=published --set admin.exposure.mode=published \
    --set publish.port=24646 --set admin.publish.port=24646
  # Both routed on their own hosts: each router names its own service, or Traefik links
  # them to neither.
  both="$(render --set exposure.mode=traefik --set ingress.host=s3-cache.example.com 2>"$tmp/err")" \
    || bad "S3 and the admin UI routed on two hosts is refused: $(tail -1 "$tmp/err")"
  for l in 'traefik.http.routers.ci-https.service=ci' 'traefik.http.routers.ci-admin-https.service=ci-admin'; do
    grep -F -- "- $l" <<<"$both" >/dev/null || bad "with S3 and the admin UI both routed, label $l is missing"
  done
  # Both published, each on its own port.
  pub="$(render --set exposure.mode=published --set admin.exposure.mode=published 2>"$tmp/err")" \
    || bad "S3 and the admin UI published on two ports is refused: $(tail -1 "$tmp/err")"
  [ "$(yq -r '.services.seaweedfs.ports[].target' <<<"$pub" | tr '\n' ' ')" = "8333 23646 " ] \
    && [ "$(yq -r '.services.seaweedfs.ports[].published' <<<"$pub" | tr '\n' ' ')" = "8333 23646 " ] \
    || bad "with S3 and the admin UI both published, the ports are not 8333 -> 8333 and 23646 -> 23646"
  # Off, the admin values are neither checked nor rendered, its exposure.mode included.
  off="$(render --set admin.enabled=false --set admin.port=8333 --set admin.passwordSecret=seaweedfs-s3-secret-key 2>"$tmp/err")" \
    || bad "admin values are refused although admin.enabled is false: $(tail -1 "$tmp/err")"
  if grep -F -e ci-admin -e traefik-public <<<"$off" >/dev/null; then
    bad "admin.exposure.mode traefik is still routed although admin.enabled is false"
  fi
fi

# ── OIDC ──────────────────────────────────────────────────────────────────────────────
# SeaweedFS logs a broken IAM file and carries on without OIDC, and it trusts the file for
# every security property, so the generated JSON is checked here field by field: what each
# of these lines guards still converges to a healthy task.
iamarg='-s3.iam.config=/tmp/seaweedfs-iam.json'
iamwrite="printf '%s' \"\$\$SEAWEEDFS_IAM_CONFIG\" > /tmp/seaweedfs-iam.json;"
iamjson="$(q "$svc.environment.SEAWEEDFS_IAM_CONFIG")"
if [ "$case" != "oidc" ]; then
  if grep -F -- '-s3.iam.config' <<<"$args" >/dev/null; then bad "case $case: -s3.iam.config is passed although oidc is off"; fi
  if grep -F -- '-s3.iam=' <<<"$args" >/dev/null; then bad "case $case: -s3.iam is set although oidc is off"; fi
  [ "$iamjson" = "null" ] || bad "case $case: SEAWEEDFS_IAM_CONFIG is set although oidc is off"
  if grep -F 'SEAWEEDFS_IAM_CONFIG' <<<"$script" >/dev/null; then bad "case $case: the wrapper writes an IAM file although oidc is off"; fi
else
  grep -Fx -- "$iamarg" <<<"$args" >/dev/null || bad "case $case: $iamarg is not passed — OIDC would be off"
  grep -Fx -- '-s3.iam=false' <<<"$args" >/dev/null \
    || bad "case $case: -s3.iam=false is not passed — the embedded IAM API would list the admin's access key id to any granted token"
  [[ "${script%%exec /entrypoint.sh*}" == *"$iamwrite"* ]] \
    || bad "case $case: the wrapper does not write SEAWEEDFS_IAM_CONFIG to the -s3.iam.config path before exec"
  j() { yq -p json -r "$1" <<<"$iamjson"; }
  iss='http://127.0.0.1:8888/buckets/idp'
  role='arn:aws:iam::role/oidc'
  groups='ci-cache auditors'
  [ "$(j '.policy.defaultEffect')" = "Deny" ] \
    || bad "case $case: policy.defaultEffect is not Deny — a trust policy that matches nothing would ALLOW, so any token could assume the role"
  keys="$(j '[.. | select(tag == "!!map") | keys | .[]] | unique | .[]')"
  for k in sts signingKey policyClaim clientSecret defaultRole oidc:aud; do
    if grep -Fx "$k" <<<"$keys" >/dev/null; then bad "case $case: the IAM file carries '$k'"; fi
  done
  # The provider: one, with the issuer and client from the fixture and a role mapping that
  # sends every granted group, and nothing else, to the one role.
  [ "$(j '.providers | length')" = "1" ] && [ "$(j '.providers[0].type')" = "oidc" ] || bad "case $case: not exactly one oidc provider"
  [ "$(j '.providers[0].config.issuer')" = "$iss" ] || bad "case $case: the provider issuer is not oidc.issuer"
  [ "$(j '.providers[0].config.clientId')" = "seaweedfs-s3" ] || bad "case $case: the provider clientId is not oidc.clientId"
  [ "$(j '.providers[0].config.jwksUri')" = "" ] || bad "case $case: the provider jwksUri is not oidc.jwksUri (\"\": discovery)"
  [ "$(j '[.providers[0].config.roleMapping.rules[] | .claim + " " + .role] | unique | join(",")')" = "groups $role" ] \
    || bad "case $case: a role-mapping rule does not map the groups claim to $role (without roleMapping SeaweedFS maps hard-coded group names)"
  [ "$(j '[.providers[0].config.roleMapping.rules[].value] | join(" ")')" = "$groups" ] \
    || bad "case $case: the role-mapping rules do not cover exactly the granted groups"
  # The role: one, attached to the one policy, assumable only with the issuer AND a granted
  # group. STS lets the caller name the role, so this trust policy is the whole gate.
  [ "$(j '.roles | length')" = "1" ] && [ "$(j '.roles[0].roleArn')" = "$role" ] && [ "$(j '.roles[0].attachedPolicies | join(",")')" = "oidc" ] \
    || bad "case $case: not exactly one role $role attached to the oidc policy"
  [ "$(j '.roles[0].trustPolicy.Statement | length')" = "1" ] || bad "case $case: the trust policy does not have exactly one statement"
  tp='.roles[0].trustPolicy.Statement[0]'
  [ "$(j "$tp.Effect + \" \" + ($tp.Action | join(\",\"))")" = "Allow sts:AssumeRoleWithWebIdentity" ] \
    || bad "case $case: the trust statement does not allow exactly sts:AssumeRoleWithWebIdentity"
  [ "$(j "$tp.Condition | keys | join(\",\")")" = "ForAnyValue:StringEquals,StringEquals" ] \
    || bad "case $case: the trust condition is not exactly the issuer and the groups"
  [ "$(j "$tp.Condition.StringEquals | to_entries | map(.key + \"=\" + .value) | join(\",\")")" = "oidc:iss=$iss" ] \
    || bad "case $case: the trust policy does not pin oidc:iss to oidc.issuer"
  [ "$(j "$tp.Condition.\"ForAnyValue:StringEquals\".\"oidc:groups\" | join(\" \")")" = "$groups" ] \
    || bad "case $case: the trust policy does not require one of the granted groups — any token of the realm could assume the role"
  # The grants: one statement each, conditioned on exactly its group, with explicit actions.
  [ "$(j '.policies | length')" = "1" ] && [ "$(j '.policies[0].name')" = "oidc" ] || bad "case $case: not exactly one policy named oidc"
  st='.policies[0].document.Statement'
  [ "$(j "$st | length")" = "2" ] || bad "case $case: not one policy statement per grant"
  [ "$(j "[${st}[] | .Condition | keys | join(\",\")] | unique | join(\" \")")" = "ForAnyValue:StringEquals" ] \
    && [ "$(j "[${st}[] | .Condition.\"ForAnyValue:StringEquals\".\"jwt:groups\" | join(\",\")] | join(\" \")")" = "$groups" ] \
    || bad "case $case: a grant is not conditioned on exactly its own group — it would apply to every group"
  [ "$(j "[${st}[].Action[]] | sort | unique | join(\" \")")" = "s3:DeleteObject s3:GetBucketLocation s3:GetObject s3:ListBucket s3:PutObject" ] \
    || bad "case $case: the grants use other actions than the five explicit ones (s3:Put* or s3:* would include s3:PutBucketPolicy)"
  [ "$(j "${st}[0].Action | join(\" \")")" = "s3:GetObject s3:ListBucket s3:GetBucketLocation s3:PutObject s3:DeleteObject" ] \
    && [ "$(j "${st}[0].Resource | join(\" \")")" = "arn:aws:s3:::runner-cache arn:aws:s3:::runner-cache/*" ] \
    || bad "case $case: the readwrite grant is not read+write on runner-cache and its objects only"
  [ "$(j "${st}[1].Action | join(\" \")")" = "s3:GetObject s3:ListBucket s3:GetBucketLocation" ] \
    && [ "$(j "${st}[1].Resource | join(\" \")")" = "arn:aws:s3:::*" ] \
    || bad "case $case: the readonly grant with buckets [] is not read-only on every bucket"

  # ── the refusals: the schema's, then the template's own with the schema removed ─────
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R "$chart" "$tmp/noschema"
  rm "$tmp/noschema/values.schema.json"
  render() { local dir="$1"; shift; "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$dir" -f "$chart/ci/oidc-values.yaml" "$@"; }
  refused() {
    local dir="$1" want="$2"; shift 2
    if render "$dir" "$@" >/dev/null 2>"$tmp/err"; then
      bad "rendered with $* ($dir) — it must be refused"
    elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
      bad "$* ($dir) failed, but not with \"$want\": $(tail -1 "$tmp/err")"
    fi
  }
  for dir in "$chart" "$tmp/noschema"; do
    render "$dir" >/dev/null 2>"$tmp/err" || bad "the oidc fixture itself does not render ($dir): $(tail -1 "$tmp/err")"
  done
  refused "$chart" "at '/oidc/issuer'" --set oidc.issuer=sso.example.com/realms/infra
  refused "$chart" "at '/oidc/issuer'" --set oidc.issuer=
  refused "$chart" "at '/oidc/clientId'" --set oidc.clientId=
  refused "$chart" "at '/oidc/grants'" --set 'oidc.grants={}'
  refused "$chart" "at '/oidc/grants/0/group'" --set 'oidc.grants[0].group=ci*'
  refused "$chart" "at '/oidc/grants/0/group'" --set 'oidc.grants[0].group=ci?'
  refused "$chart" "at '/oidc/grants/0/group'" --set 'oidc.grants[0].group=${ci}'
  refused "$chart" "at '/oidc/grants/0/access'" --set 'oidc.grants[0].access=admin'
  refused "$chart" "at '/oidc/grants/0/buckets/0'" --set 'oidc.grants[0].buckets[0]=Runner_Cache'
  refused "$chart" "additional properties 'bucket' not allowed" --set 'oidc.grants[0].bucket[0]=runner-cache'
  refused "$chart" "at '/oidc/jwksUri'" --set oidc.jwksUri=sso.example.com/certs
  printf 'oidc:\n  grants:\n    - { group: ci-cache, access: readwrite }\n' >"$tmp/nobuckets.yaml"
  refused "$chart" "missing property 'buckets'" -f "$tmp/nobuckets.yaml"
  ns="$tmp/noschema"
  refused "$ns" "oidc.issuer must be the identity provider's issuer URL" --set oidc.issuer=sso.example.com/realms/infra
  refused "$ns" "oidc.issuer must be the identity provider's issuer URL" --set oidc.issuer=
  refused "$ns" "oidc.clientId is required" --set oidc.clientId=
  refused "$ns" "oidc.grants needs at least one grant" --set 'oidc.grants={}'
  refused "$ns" "group \"ci*\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group=ci*'
  refused "$ns" "group \"ci?\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group=ci?'
  refused "$ns" "group \"\${ci}\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group=${ci}'
  refused "$ns" "group \"\" must be a non-empty groups-claim value" --set 'oidc.grants[0].group='
  refused "$ns" "has access \"admin\"; it must be readonly or readwrite" --set 'oidc.grants[0].access=admin'
  refused "$ns" "\"Runner_Cache\" is not a valid S3 bucket name" --set 'oidc.grants[0].buckets[0]=Runner_Cache'
  refused "$ns" "group \"ci-cache\" has no buckets list" -f "$tmp/nobuckets.yaml"
  # The fixture discovers its keys; an explicit jwksUri must reach the provider as given.
  render "$chart" --set oidc.jwksUri=https://sso.example.com/certs >"$tmp/jwks.yaml" 2>"$tmp/err" \
    && [ "$(yq -r "$svc.environment.SEAWEEDFS_IAM_CONFIG" "$tmp/jwks.yaml" | yq -p json -r '.providers[0].config.jwksUri')" = "https://sso.example.com/certs" ] \
    || bad "an explicit oidc.jwksUri does not reach the provider config"
  # A `$` in a value must reach the container as `$`, not be interpolated by Docker.
  render "$chart" --set 'oidc.clientId=seaweedfs$s3' >"$tmp/dollar.yaml" 2>"$tmp/err" \
    && grep -F 'seaweedfs$$s3' "$tmp/dollar.yaml" >/dev/null \
    || bad "a \$ in oidc.clientId is not escaped as \$\$ in SEAWEEDFS_IAM_CONFIG — Docker would interpolate it"
fi

exit "$fail"
