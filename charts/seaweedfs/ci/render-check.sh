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
#   * On the Enterprise image weed admin binds its unauthenticated worker gRPC port with
#     the UI, so both must stay on 127.0.0.1 behind the forwarder; admin.oidc's client
#     secret must reach weed admin alone, like the password.
#   * admin.oauth2 puts oauth2-proxy in front of the UI. Its flags are its whole security,
#     and a wrong one still converges: no allowed group admits every user of the provider,
#     a bearer-token skip admits any token, and a proxy-less route to the UI bypasses it.
#     So the proxy's command is compared flag by flag, its routers must be the UI's, and
#     seaweedfs must carry none of them.
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
nets="$(q "$svc.networks | keys | .[]")"
grep -Fx seaweedfs-net <<<"$nets" >/dev/null || bad "the service is not on network.name (seaweedfs-net): other stacks could not reach it"
[ "$(q '.networks."seaweedfs-net".external')" = "true" ] || bad "seaweedfs-net is not external — it would be stack-scoped and unreachable by name from other stacks"
# Java clients cannot dial ci_seaweedfs: java.net.URI rejects the '_' in it.
[ "$(q "$svc.networks.\"seaweedfs-net\".aliases | join(\" \")")" = "ci-seaweedfs" ] \
  || bad "the service's alias on seaweedfs-net is not exactly ci-seaweedfs, the name without '_' Java clients dial"

# ── exposure ──────────────────────────────────────────────────────────────────────────
labels="$(q "$svc.deploy.labels[]")"
# The admin routers' rule after Host(): /metrics needs no login, so it is not served; anything
# but GET/HEAD a browser marks same-site or cross-site is refused at the edge; and an encoded
# slash is refused, since Traefik matches the escaped path.
admin_guard='!PathPrefix(`/metrics`) && !PathRegexp(`(?i)%2f`) && (Method(`GET`) || Method(`HEAD`) || !HeaderRegexp(`Sec-Fetch-Site`, `^(cross|same)-site`))'
# The routes that return stored files or their metadata ride a router of their own whose
# responses are sandboxed.
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
  admin-oauth2)
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: seaweedfs carries Traefik labels, which are oauth2-proxy's in this mode"; fi
    [ "$(sort <<<"$nets")" = "$(printf 'admin-oauth2\nseaweedfs-net')" ] \
      || bad "case $case: seaweedfs is on $(tr '\n' ' ' <<<"$nets")instead of exactly seaweedfs-net and admin-oauth2"
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
    want_nets=seaweedfs-net
    [ "$case" = "metrics" ] && want_nets="$(printf 'seaweedfs-net\nmonitoring')"
    [ "$(sort <<<"$nets")" = "$(sort <<<"$want_nets")" ] || bad "case $case: attached to $(tr '\n' ' ' <<<"$nets")instead of $(tr '\n' ' ' <<<"$want_nets")"
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
  # Exactly the two discovery labels: an extra prometheus.io/path would point every
  # scrape somewhere else on this listener, /debug/pprof included.
  disc="$(grep -E '^prometheus\.io/' <<<"$labels" | LC_ALL=C sort | tr '\n' ' ' || true)"
  [ "$disc" = "prometheus.io/port=$mport prometheus.io/scrape=true " ] \
    || bad "case $case: discovery labels are '$disc', expected exactly prometheus.io/port=$mport and prometheus.io/scrape=true"
  [ "$(q '.networks.monitoring.external')" = "true" ] || bad "case $case: the monitoring overlay is not external — Prometheus in another stack could not reach it"
  if q "$svc.ports[].target" | grep -Fx "$mport" >/dev/null; then bad "case $case: the metrics port is published; /metrics and /debug/pprof have no authentication"; fi
else
  if grep -E -- '^-metrics(Port|Ip)=' <<<"$args" >/dev/null; then bad "case $case: a metrics listener is rendered although metrics.enabled is off"; fi
  if grep -F 'prometheus.io/' <<<"$labels" >/dev/null; then bad "case $case: discovery labels are rendered although metrics.enabled is off"; fi
  if grep -Fx monitoring <<<"$nets" >/dev/null; then bad "case $case: attached to the monitoring overlay although metrics.enabled is off"; fi
fi

# ── the refusals ──────────────────────────────────────────────────────────────────────
# Rendered once, from the metrics fixture, with the renderer test-charts.sh runs.
if [ "$case" = "metrics" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  render() { "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" -f "$chart/ci/metrics-values.yaml" "$@"; }
  refused() {
    local want="$1"; shift
    if render "$@" >/dev/null 2>"$tmp/err"; then
      bad "rendered with $* — it must be refused"
    elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
      bad "$* failed, but not with \"$want\": $(cat "$tmp/err")"
    fi
  }
  # Every port weed binds inside the container: a second listener on one of them
  # takes the whole process down at start.
  for p in 8333 18333 9333 19333 8080 18080 8888 18888; do
    refused "metrics.port $p is already taken" --set "metrics.port=$p"
  done
  refused "metrics.port 19000 is already taken" --set s3.port=9000 --set metrics.port=19000
  # With the web UI on, its port and its worker gRPC port are taken too, and on the
  # Enterprise image the UI one port up, behind the forwarder.
  refused "metrics.port 23646 collides with the web UI" --set admin.enabled=true --set metrics.port=23646
  refused "metrics.port 33646 collides with the web UI" --set admin.enabled=true --set metrics.port=33646
  refused "metrics.port 23647 collides with the web UI" --set admin.enabled=true \
    --set image.repository=chrislusf/seaweedfs-enterprise --set metrics.port=23647
  render --set admin.enabled=true --set metrics.port=23647 >/dev/null 2>"$tmp/err" \
    || bad "metrics.port 23647 was refused on the free image, where weed admin does not bind it: $(cat "$tmp/err")"
  cat >"$tmp/basic.yaml" <<'EOF'
labels:
  traefik.http.middlewares.ops.BasicAuth.Users: "ops:$$apr1$$x$$y"
EOF
  cat >"$tmp/digest.yaml" <<'EOF'
labels:
  traefik.http.middlewares.ops.digestauth.users: "ops:realm:abc"
EOF
  cat >"$tmp/header.yaml" <<'EOF'
labels:
  traefik.http.middlewares.up.headers.customRequestHeaders.Authorization: "Bearer x"
EOF
  cat >"$tmp/usersfile.yaml" <<'EOF'
labels:
  traefik.http.middlewares.ops.basicauth.usersfile: /run/secrets/ops-users
EOF
  refused '"traefik.http.middlewares.ops.BasicAuth.Users" carries credentials' -f "$tmp/basic.yaml"
  refused '"traefik.http.middlewares.ops.digestauth.users" carries credentials' -f "$tmp/digest.yaml"
  refused 'customRequestHeaders.Authorization" carries credentials' -f "$tmp/header.yaml"
  render -f "$tmp/usersfile.yaml" >/dev/null 2>"$tmp/err" \
    || bad "a basicauth.usersfile label was refused with metrics on; it is the alternative the refusal recommends: $(cat "$tmp/err")"
  render -f "$tmp/basic.yaml" --set metrics.enabled=false >/dev/null 2>"$tmp/err" \
    || bad "a basic-auth label was refused with metrics off; only metrics makes it readable: $(cat "$tmp/err")"
  render --set metrics.port=9100 >/dev/null 2>"$tmp/err" \
    || bad "metrics.port 9100 was refused; only ports weed binds may be: $(cat "$tmp/err")"
fi
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
    # The Enterprise image: the UI and its worker gRPC port on 127.0.0.1, the UI one port up.
    [ "$case" = "admin-oidc" ] \
      && want="( export WEED_ADMIN_PASSWORD=\"\$\$(cat /run/secrets/$pw)\" WEED_ADMIN_OIDC_CLIENT_SECRET=\"\$\$(cat /run/secrets/seaweedfs-admin-oidc-client-secret)\" GODEBUG=fips140=on; exec su-exec seaweed weed -logtostderr=true admin -ip=127.0.0.1 -master=127.0.0.1:9333 -port=23647 -port.grpc=33646 -dataDir=/data/admin -adminUser=admin ) || rc=\$\$?;"
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

# ── the Enterprise image and admin.oidc ───────────────────────────────────────────────
cs=seaweedfs-admin-oidc-client-secret
fwd='( while :; do rc=0; su-exec seaweed nc -lk -p 23646 -e nc 127.0.0.1 23647 || rc=$$?; echo "admin forwarder exited (status $$rc) - restarting in 5s" >&2; sleep 5; done ) & '
oidcenv="$(q "$svc.environment | to_entries | map(select(.key | test(\"^WEED_ADMIN_OIDC_\"))) | .[] | .key + \"=\" + .value")"
if [ "$case" = "admin-oidc" ]; then
  grep -F -- "$fwd" <<<"$script" >/dev/null \
    || bad "case $case: no restarting forwarder from admin.port 23646 to the UI on 127.0.0.1:23647 — the UI would be unreachable"
  [ "$oidcenv" = "$(printf '%s\n' WEED_ADMIN_OIDC_ADMIN_GROUPS=storage-admins WEED_ADMIN_OIDC_CLIENT_ID=seaweedfs-admin \
      WEED_ADMIN_OIDC_ENABLED=true WEED_ADMIN_OIDC_ISSUER=http://127.0.0.1:8888/buckets/idp WEED_ADMIN_OIDC_READONLY_GROUPS=storage-auditors \
      WEED_ADMIN_OIDC_REDIRECT_URL=https://seaweedfs-admin.example.com/login/oidc/callback)" ] \
    || bad "case $case: the WEED_ADMIN_OIDC_* environment is not exactly the fixture's (no client secret, no default role): $(tr '\n' ' ' <<<"$oidcenv")"
  grep -Fx "$cs" <<<"$mounted" >/dev/null && [ "$(q ".secrets.\"$cs\".external")" = "true" ] \
    || bad "case $case: the OIDC client secret is not mounted from an external secret"
  grep -F "test -s \"/run/secrets/$cs\" || { echo \"secret $cs is missing or empty - refusing to start the admin UI's OIDC login without its client secret\" >&2; exit 1; };" <<<"$script" >/dev/null \
    || bad "case $case: the wrapper does not refuse a missing or empty OIDC client secret"
  [ "$(grep -o WEED_ADMIN_OIDC_CLIENT_SECRET <<<"$script" | wc -l | tr -d ' ')" = "1" ] \
    || bad "case $case: WEED_ADMIN_OIDC_CLIENT_SECRET is set outside the admin's own subshell"
else
  if grep -F -e 'nc -lk' -e ' admin -ip=' -e WEED_ADMIN_OIDC <<<"$script" >/dev/null || [ -n "$oidcenv" ] || grep -Fx "$cs" <<<"$mounted" >/dev/null; then
    bad "case $case: the Enterprise forwarder or admin.oidc is rendered on the free image"
  fi
fi

# ── admin.oauth2: oauth2-proxy in front of the UI ────────────────────────────────────
px='.services."oauth2-proxy"'
if [ "$case" = "admin-oauth2" ]; then
  want_cmd="$(printf '%s\n' --http-address=0.0.0.0:4180 --provider=oidc --oidc-issuer-url=https://seaweedfs-e2e-oidc:8443 \
    --client-id=seaweedfs-admin --client-secret-file=/run/secrets/seaweedfs-admin-oauth2-client-secret \
    --cookie-secret-file=/run/secrets/seaweedfs-admin-oauth2-cookie-secret --provider-ca-file=/run/secrets/seaweedfs-e2e-oidc-ca \
    --cookie-secure=true --cookie-samesite=lax --cookie-refresh=1m --redirect-url=https://admin.e2e.test/oauth2/callback '--email-domain=*' \
    --allowed-group=storage-admins '--scope=openid email profile' --code-challenge-method=S256 --reverse-proxy=true \
    --trusted-proxy-ip=10.0.0.0/8 --upstream=http://seaweedfs:23646/ --proxy-prefix=/oauth2 --pass-basic-auth=false \
    --pass-user-headers=false --pass-access-token=false --pass-authorization-header=false --set-xauthrequest=false \
    --skip-jwt-bearer-tokens=false)"
  got_cmd="$(q "$px.command[]")"
  [ "$got_cmd" = "$want_cmd" ] || bad "case $case: oauth2-proxy's command is not exactly the expected flags: $(diff <(echo "$want_cmd") <(echo "$got_cmd") | grep '^[<>]' | tr '\n' ' ')"
  [ "$(q "$px.image")" = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.4" ] || bad "case $case: oauth2-proxy runs $(q "$px.image"), not the values' pin"
  [ "$(q "$px.networks[]" | sort | tr '\n' ' ')" = "admin-oauth2 traefik-public " ] \
    || bad "case $case: oauth2-proxy is on $(q "$px.networks[]" | tr '\n' ' ')instead of exactly traefik-public and admin-oauth2"
  [ "$(q '.networks."admin-oauth2".external // false')" = "false" ] && [ "$(q '.networks."admin-oauth2".attachable // false')" = "false" ] \
    || bad "case $case: admin-oauth2 is external or attachable, so something besides the proxy could join it"
  for sec in seaweedfs-admin-oauth2-client-secret seaweedfs-admin-oauth2-cookie-secret seaweedfs-e2e-oidc-ca; do
    q "$px.secrets[]" | grep -Fx "$sec" >/dev/null && [ "$(q ".secrets.\"$sec\".external")" = "true" ] \
      || bad "case $case: oauth2-proxy does not mount the external secret $sec"
  done
  if q "$svc.secrets[]" | grep -E '^seaweedfs-(admin-oauth2|e2e-oidc)-' >/dev/null; then bad "case $case: seaweedfs mounts one of oauth2-proxy's secrets"; fi
  plabels="$(q "$px.deploy.labels[]")"
  for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public' \
           'traefik.http.services.ci-admin.loadbalancer.server.port=4180' \
           "traefik.http.routers.ci-admin-https.rule=Host(\`admin.e2e.test\`) && $admin_guard" \
           'traefik.http.routers.ci-admin-https.tls=true' 'traefik.http.routers.ci-admin-http.middlewares=https-redirect' \
           "traefik.http.routers.ci-admin-content-https.rule=Host(\`admin.e2e.test\`) && $admin_guard && $content_paths" \
           'traefik.http.routers.ci-admin-content-https.middlewares=ci-admin-sandbox' \
           'traefik.http.middlewares.ci-admin-sandbox.headers.contentSecurityPolicy=sandbox'; do
    grep -Fx -- "$l" <<<"$plabels" >/dev/null || bad "case $case: oauth2-proxy lacks label $l"
  done
  [ "$(grep -c '=ci-admin-sandbox$' <<<"$plabels")" = "1" ] || bad "case $case: the sandbox middleware is not on exactly the content router"
else
  if [ "$(q "$px")" != "null" ] || [ "$(q '.networks."admin-oauth2"')" != "null" ]; then
    bad "case $case: oauth2-proxy or admin-oauth2 is rendered although admin.oauth2 is off"
  fi
fi

# ── buckets ───────────────────────────────────────────────────────────────────────────
case "$case" in
  buckets) want='runner-cache e2e.second-bucket' ;;
  traefik|edge) want='runner-cache' ;;
  ephemeral) want='scratch' ;;
  oidc) want='idp runner-cache reports' ;;
  admin-oidc) want='idp' ;;
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
  ephemeral|admin-oidc)
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
  [ "$(j '.providers[0].config.issuer')" = "$iss" ] || bad "case $case: the provider issuer is not s3.oidc.issuer"
  [ "$(j '.providers[0].config.clientId')" = "seaweedfs-s3" ] || bad "case $case: the provider clientId is not s3.oidc.clientId"
  [ "$(j '.providers[0].config.jwksUri')" = "" ] || bad "case $case: the provider jwksUri is not s3.oidc.jwksUri (\"\": discovery)"
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
    || bad "case $case: the trust policy does not pin oidc:iss to s3.oidc.issuer"
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
  refused "$chart" "at '/s3/oidc/issuer'" --set s3.oidc.issuer=sso.example.com/realms/infra
  refused "$chart" "at '/s3/oidc/issuer'" --set s3.oidc.issuer=
  refused "$chart" "at '/s3/oidc/clientId'" --set s3.oidc.clientId=
  refused "$chart" "at '/s3/oidc/grants'" --set 's3.oidc.grants={}'
  refused "$chart" "at '/s3/oidc/grants/0/group'" --set 's3.oidc.grants[0].group=ci*'
  refused "$chart" "at '/s3/oidc/grants/0/group'" --set 's3.oidc.grants[0].group=ci?'
  refused "$chart" "at '/s3/oidc/grants/0/group'" --set 's3.oidc.grants[0].group=${ci}'
  refused "$chart" "at '/s3/oidc/grants/0/access'" --set 's3.oidc.grants[0].access=admin'
  refused "$chart" "at '/s3/oidc/grants/0/buckets/0'" --set 's3.oidc.grants[0].buckets[0]=Runner_Cache'
  refused "$chart" "additional properties 'bucket' not allowed" --set 's3.oidc.grants[0].bucket[0]=runner-cache'
  refused "$chart" "at '/s3/oidc/jwksUri'" --set s3.oidc.jwksUri=sso.example.com/certs
  printf 's3:\n  oidc:\n    grants:\n      - { group: ci-cache, access: readwrite }\n' >"$tmp/nobuckets.yaml"
  refused "$chart" "missing property 'buckets'" -f "$tmp/nobuckets.yaml"
  ns="$tmp/noschema"
  refused "$ns" "s3.oidc.issuer must be the identity provider's issuer URL" --set s3.oidc.issuer=sso.example.com/realms/infra
  refused "$ns" "s3.oidc.issuer must be the identity provider's issuer URL" --set s3.oidc.issuer=
  refused "$ns" "s3.oidc.clientId is required" --set s3.oidc.clientId=
  refused "$ns" "s3.oidc.grants needs at least one grant" --set 's3.oidc.grants={}'
  refused "$ns" "group \"ci*\" must be a non-empty groups-claim value" --set 's3.oidc.grants[0].group=ci*'
  refused "$ns" "group \"ci?\" must be a non-empty groups-claim value" --set 's3.oidc.grants[0].group=ci?'
  refused "$ns" "group \"\${ci}\" must be a non-empty groups-claim value" --set 's3.oidc.grants[0].group=${ci}'
  refused "$ns" "group \"\" must be a non-empty groups-claim value" --set 's3.oidc.grants[0].group='
  refused "$ns" "has access \"admin\"; it must be readonly or readwrite" --set 's3.oidc.grants[0].access=admin'
  refused "$ns" "\"Runner_Cache\" is not a valid S3 bucket name" --set 's3.oidc.grants[0].buckets[0]=Runner_Cache'
  refused "$ns" "group \"ci-cache\" has no buckets list" -f "$tmp/nobuckets.yaml"
  # The fixture discovers its keys; an explicit jwksUri must reach the provider as given.
  render "$chart" --set s3.oidc.jwksUri=https://sso.example.com/certs >"$tmp/jwks.yaml" 2>"$tmp/err" \
    && [ "$(yq -r "$svc.environment.SEAWEEDFS_IAM_CONFIG" "$tmp/jwks.yaml" | yq -p json -r '.providers[0].config.jwksUri')" = "https://sso.example.com/certs" ] \
    || bad "an explicit s3.oidc.jwksUri does not reach the provider config"
  # A `$` in a value must reach the container as `$`, not be interpolated by Docker.
  render "$chart" --set 's3.oidc.clientId=seaweedfs$s3' >"$tmp/dollar.yaml" 2>"$tmp/err" \
    && grep -F 'seaweedfs$$s3' "$tmp/dollar.yaml" >/dev/null \
    || bad "a \$ in s3.oidc.clientId is not escaped as \$\$ in SEAWEEDFS_IAM_CONFIG — Docker would interpolate it"
fi

# ── the admin.oidc and Enterprise guards, rendered once with SWARMCLI ─────────────────
# Each refusal names what SeaweedFS would otherwise turn into a log warning and a login
# page without OIDC, or a UI that never starts.
if [ "$case" = "admin-oidc" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R "$chart" "$tmp/noschema"
  rm "$tmp/noschema/values.schema.json"
  render() { local dir="$1"; shift; "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template ci "$dir" -f "$chart/ci/admin-oidc-values.yaml" "$@"; }
  refused() {
    local dir="$1" want="$2"; shift 2
    if render "$dir" "$@" >/dev/null 2>"$tmp/err"; then
      bad "rendered with $* ($dir) — it must be refused"
    elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
      bad "$* ($dir) failed, but not with \"$want\": $(tail -1 "$tmp/err")"
    fi
  }
  envof() { yq -r ".services.seaweedfs.environment.$1" "$tmp/out.yaml"; }
  refused "$chart" "at '/admin/oidc/issuer'" --set admin.oidc.issuer=http://sso.example.com/realms/infra
  refused "$chart" "at '/admin/oidc/browserUrl'" --set admin.oidc.browserUrl=http://seaweedfs-admin.example.com
  refused "$chart" "at '/admin/oidc/browserUrl'" --set admin.oidc.browserUrl=https://seaweedfs-admin.example.com/ui
  # --set splits on commas, so the comma group comes from a file.
  printf 'admin:\n  oidc:\n    adminGroups: ["a,b"]\n' >"$tmp/comma.yaml"
  refused "$chart" "at '/admin/oidc/adminGroups/0'" -f "$tmp/comma.yaml"
  # SeaweedFS matches the groups as wildcards: `*` would make every user of the realm admin.
  refused "$chart" "at '/admin/oidc/adminGroups/0'" --set 'admin.oidc.adminGroups[0]=*'
  refused "$chart" "at '/admin/oidc/readonlyGroups/0'" --set 'admin.oidc.readonlyGroups[0]=audit?'
  ns="$tmp/noschema"
  refused "$ns" "admin.oidc needs the SeaweedFS Enterprise image" --set image.repository=chrislusf/seaweedfs
  refused "$ns" "admin.oidc.issuer must be the provider's https:// issuer URL" --set admin.oidc.issuer=http://sso.example.com/realms/infra
  refused "$ns" "admin.oidc.issuer must be the provider's https:// issuer URL" --set admin.oidc.issuer=
  refused "$ns" "admin.oidc.clientId is required" --set admin.oidc.clientId=
  refused "$ns" "admin.oidc.clientSecretSecret must name a secret of its own" --set admin.oidc.clientSecretSecret=
  refused "$ns" "admin.oidc.clientSecretSecret must name a secret of its own" --set admin.oidc.clientSecretSecret=seaweedfs-admin-password
  refused "$ns" "admin.oidc.clientSecretSecret must name a secret of its own" --set admin.oidc.clientSecretSecret=seaweedfs-s3-secret-key
  refused "$ns" "admin.oidc needs adminGroups or readonlyGroups" --set 'admin.oidc.adminGroups={}' --set 'admin.oidc.readonlyGroups={}'
  refused "$ns" "group \"a,b\" must be a non-empty groups-claim value without ',', '*' or '?'" -f "$tmp/comma.yaml"
  refused "$ns" "group \"*\" must be a non-empty groups-claim value" --set 'admin.oidc.adminGroups[0]=*'
  refused "$ns" "group \"audit?\" must be a non-empty groups-claim value" --set 'admin.oidc.readonlyGroups[0]=audit?'
  refused "$ns" "admin.oidc.browserUrl must be the UI's public base URL" --set admin.oidc.browserUrl=https://seaweedfs-admin.example.com/ui
  refused "$ns" "admin.oidc.browserUrl is required unless admin.exposure.mode=traefik" --set admin.oidc.browserUrl=
  refused "$ns" "admin.oidc needs an https callback, and http://seaweedfs-admin.example.com is not" --set admin.oidc.browserUrl=http://seaweedfs-admin.example.com
  refused "$ns" "admin.oidc needs an https callback, and http://adm.example.com is not" --set admin.oidc.browserUrl= \
    --set admin.exposure.mode=traefik --set admin.ingress.host=adm.example.com --set admin.ingress.tls=false
  # One port up from admin.port 8332 is the S3 port, taken only on the Enterprise image.
  refused "$ns" "on the Enterprise image weed admin listens on 127.0.0.1:8333" --set admin.port=8332
  render "$ns" --set admin.port=8332 --set image.repository=chrislusf/seaweedfs --set admin.oidc.enabled=false >/dev/null 2>"$tmp/err" \
    || bad "admin.port 8332 is refused on the free image, where the UI binds it alone: $(tail -1 "$tmp/err")"
  # Routed with TLS, the callback comes from admin.ingress.host; a trailing slash is dropped.
  render "$chart" --set admin.oidc.browserUrl= --set admin.exposure.mode=traefik --set admin.ingress.host=adm.example.com >"$tmp/out.yaml" 2>"$tmp/err" \
    && [ "$(envof WEED_ADMIN_OIDC_REDIRECT_URL)" = "https://adm.example.com/login/oidc/callback" ] \
    || bad "routed with TLS and no browserUrl, the callback is not https://<admin.ingress.host>/login/oidc/callback"
  render "$chart" --set admin.oidc.browserUrl=https://adm.example.com:8443/ >"$tmp/out.yaml" 2>"$tmp/err" \
    && [ "$(envof WEED_ADMIN_OIDC_REDIRECT_URL)" = "https://adm.example.com:8443/login/oidc/callback" ] \
    || bad "a browserUrl with a port and a trailing slash does not give <browserUrl>/login/oidc/callback"
  # A mirror of the Enterprise image counts as Enterprise.
  render "$chart" --set image.repository=registry.example.com/mirror/seaweedfs-enterprise >"$tmp/out.yaml" 2>"$tmp/err" \
    && grep -F 'nc -lk -p 23646' "$tmp/out.yaml" >/dev/null \
    || bad "a mirrored seaweedfs-enterprise repository is not treated as the Enterprise image"
  # The Enterprise image without admin.oidc still gets the forwarder, and no OIDC.
  render "$chart" --set admin.oidc.enabled=false >"$tmp/out.yaml" 2>"$tmp/err" \
    && grep -F 'nc -lk -p 23646' "$tmp/out.yaml" >/dev/null && ! grep -F -e WEED_ADMIN_OIDC -e "$cs" "$tmp/out.yaml" >/dev/null \
    || bad "the Enterprise image with admin.oidc off does not render the forwarder alone"
  # With the UI off, admin.oidc is neither checked nor rendered.
  render "$ns" --set admin.enabled=false --set admin.oidc.issuer= >"$tmp/out.yaml" 2>"$tmp/err" \
    && ! grep -F -e WEED_ADMIN -e "$cs" -e 'nc -lk' "$tmp/out.yaml" >/dev/null \
    || bad "admin.oidc is checked or rendered although admin.enabled is false"
  # A `$` in a value must reach the container as `$`, not be interpolated by Docker.
  render "$chart" --set 'admin.oidc.clientId=seaweedfs$admin' >"$tmp/out.yaml" 2>"$tmp/err" \
    && grep -F 'seaweedfs$$admin' "$tmp/out.yaml" >/dev/null \
    || bad "a \$ in admin.oidc.clientId is not escaped as \$\$ — Docker would interpolate it"
fi

# ── the admin.oauth2 guards, rendered once with SWARMCLI ──────────────────────────────
if [ "$case" = "admin-oauth2" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R "$chart" "$tmp/noschema"
  rm "$tmp/noschema/values.schema.json"
  render() { local dir="$1"; shift; "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template ci "$dir" -f "$chart/ci/admin-oauth2-values.yaml" "$@"; }
  refused() {
    local dir="$1" want="$2"; shift 2
    if render "$dir" "$@" >/dev/null 2>"$tmp/err"; then
      bad "rendered with $* ($dir) — it must be refused"
    elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
      bad "$* ($dir) failed, but not with \"$want\": $(tail -1 "$tmp/err")"
    fi
  }
  ns="$tmp/noschema"
  printf 'admin:\n  oauth2:\n    allowedGroups: ["a,b"]\n' >"$tmp/comma.yaml"
  refused "$chart" "at '/admin/oauth2/issuer'" --set admin.oauth2.issuer=http://sso.example.com/realms/infra
  refused "$chart" "at '/admin/oauth2/allowedGroups/0'" -f "$tmp/comma.yaml"
  refused "$chart" "at '/admin/oauth2/cookieRefresh'" --set admin.oauth2.cookieRefresh=1min
  # Both logins on: the Enterprise image with a complete admin.oidc, so nothing else stops it.
  refused "$ns" "admin.oidc and admin.oauth2 cannot both be enabled" --set image.repository=chrislusf/seaweedfs-enterprise \
    --set admin.oidc.enabled=true --set admin.oidc.issuer=https://sso.example.com --set 'admin.oidc.adminGroups[0]=storage-admins'
  refused "$ns" "admin.oauth2 needs admin.exposure.mode=traefik with admin.ingress.tls" --set admin.exposure.mode=none
  refused "$ns" "admin.oauth2 needs admin.exposure.mode=traefik with admin.ingress.tls" --set admin.exposure.mode=published
  refused "$ns" "admin.oauth2 needs admin.exposure.mode=traefik with admin.ingress.tls" --set admin.ingress.tls=false
  refused "$ns" "admin.oauth2.issuer must be the provider's https:// issuer URL" --set admin.oauth2.issuer=http://sso.example.com/realms/infra
  refused "$ns" "admin.oauth2.issuer must be the provider's https:// issuer URL" --set admin.oauth2.issuer=
  refused "$ns" "admin.oauth2.clientId is required" --set admin.oauth2.clientId=
  refused "$ns" "admin.oauth2.clientSecretSecret must name a secret of its own" --set admin.oauth2.clientSecretSecret=
  refused "$ns" "admin.oauth2.clientSecretSecret must name a secret of its own" --set admin.oauth2.clientSecretSecret=seaweedfs-admin-password
  refused "$ns" "admin.oauth2.clientSecretSecret must name a secret of its own" --set admin.oauth2.clientSecretSecret=seaweedfs-s3-secret-key
  refused "$ns" "admin.oauth2.cookieSecretSecret must name a secret of its own" --set admin.oauth2.cookieSecretSecret=
  refused "$ns" "admin.oauth2.cookieSecretSecret must name a secret of its own" --set admin.oauth2.cookieSecretSecret=seaweedfs-admin-oauth2-client-secret
  refused "$ns" "admin.oauth2.cookieSecretSecret must name a secret of its own" --set admin.oauth2.cookieSecretSecret=seaweedfs-s3-access-key
  refused "$ns" "admin.oauth2.caSecret must name a secret of its own" --set admin.oauth2.caSecret=seaweedfs-admin-oauth2-cookie-secret
  refused "$ns" "admin.oauth2.caSecret must name a secret of its own" --set admin.oauth2.caSecret=seaweedfs-admin-password
  refused "$ns" "admin.oauth2.allowedGroups needs at least one group" --set 'admin.oauth2.allowedGroups={}'
  refused "$ns" "admin.oauth2.allowedGroups: group \"a,b\" must be a non-empty groups-claim value without ','" -f "$tmp/comma.yaml"
  # Without caSecret the proxy trusts the image's roots: no CA flag, no CA secret.
  render "$chart" --set admin.oauth2.caSecret= >"$tmp/out.yaml" 2>"$tmp/err" \
    && ! grep -F -e provider-ca-file -e seaweedfs-e2e-oidc-ca "$tmp/out.yaml" >/dev/null \
    || bad "with no caSecret, a CA file or secret is still rendered: $(tail -1 "$tmp/err")"
  # Each group is its own flag.
  render "$chart" --set 'admin.oauth2.allowedGroups={storage-admins,storage-auditors}' >"$tmp/out.yaml" 2>"$tmp/err" \
    && [ "$(yq -r '.services."oauth2-proxy".command[] | select(test("^--allowed-group="))' "$tmp/out.yaml" | tr '\n' ' ')" \
         = "--allowed-group=storage-admins --allowed-group=storage-auditors " ] \
    || bad "two allowedGroups are not two --allowed-group flags"
  # With the S3 API routed too, seaweedfs carries its routers and joins the edge; the UI's stay on the proxy.
  render "$chart" --set exposure.mode=traefik --set ingress.host=s3-cache.example.com >"$tmp/out.yaml" 2>"$tmp/err" \
    && yq -r '.services.seaweedfs.deploy.labels[]' "$tmp/out.yaml" | grep -Fx 'traefik.http.routers.ci-https.service=ci' >/dev/null \
    && ! yq -r '.services.seaweedfs.deploy.labels[]' "$tmp/out.yaml" | grep -F 'ci-admin' >/dev/null \
    && yq -r '.services.seaweedfs.networks | keys | .[]' "$tmp/out.yaml" | grep -Fx traefik-public >/dev/null \
    && yq -r '.services."oauth2-proxy".deploy.labels[]' "$tmp/out.yaml" | grep -Fx 'traefik.http.routers.ci-admin-https.service=ci-admin' >/dev/null \
    || bad "with S3 and the UI both routed, S3's routers are not on seaweedfs alone and the UI's on oauth2-proxy alone: $(tail -1 "$tmp/err")"
  # With the UI off, admin.oauth2 is neither checked nor rendered.
  render "$ns" --set admin.enabled=false --set admin.oauth2.issuer= >"$tmp/out.yaml" 2>"$tmp/err" \
    && ! grep -F -e oauth2-proxy -e admin-oauth2 "$tmp/out.yaml" >/dev/null \
    || bad "admin.oauth2 is checked or rendered although admin.enabled is false"
  # A `$` in a value must reach the container as `$`, not be interpolated by Docker.
  render "$chart" --set 'admin.oauth2.clientId=seaweedfs$admin' >"$tmp/out.yaml" 2>"$tmp/err" \
    && grep -F -- '--client-id=seaweedfs$$admin' "$tmp/out.yaml" >/dev/null \
    || bad "a \$ in admin.oauth2.clientId is not escaped as \$\$ — Docker would interpolate it"
fi

# ── the alias of a release name with '_' or '.' (from the default fixture only) ──────
if [ "$case" = "default" ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.err"' EXIT
  if "${SWARMCLI:?render-check needs SWARMCLI to render a second release}" charts template my_s3.x \
    "$(cd "$(dirname "$0")/.." && pwd)" >"$tmp" 2>"$tmp.err"; then
    [ "$(yq -r "$svc.networks.\"seaweedfs-net\".aliases[]" "$tmp")" = "my-s3-x-seaweedfs" ] \
      || bad "release my_s3.x does not get the alias my-s3-x-seaweedfs: '_' and '.' must become '-'"
  else
    bad "release my_s3.x was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
fi

exit "$fail"
