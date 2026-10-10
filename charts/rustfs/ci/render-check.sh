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
#     console.enabled, and be routed or published only then. The S3 API and the console
#     are exposed independently: routing one must not route the other.
#   * A single `$` in the wrapper is interpolated by Docker at deploy time, so the secret
#     would be read on the deploying machine (or read as empty) instead of in the task.
#   * The OIDC client secret has no _FILE form in RustFS, so the wrapper exports it; it
#     must never reach environment:, and RustFS must be told the callback base and the
#     provider's origin, or SSO silently disappears or follows a client's Host header.
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
case "$case" in traefik|published|console-edge|oidc) console=1 ;; *) console="" ;; esac
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
  traefik|edge|console-edge|oidc)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public'; do
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
    [ "$(q "$svc.ports | length")" = "2" ] || bad "case $case: more than the S3 and console ports are published"
    ;;
  *)
    [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published although exposure.mode is none"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "case $case: Traefik labels rendered although exposure.mode is none"; fi
    [ "$nets" = "rustfs-net" ] || bad "case $case: attached to more than network.name: $(tr '\n' ' ' <<<"$nets")"
    ;;
esac
case "$case" in traefik|edge|console-edge|oidc) ;; *)
  [ "$(env_ RUSTFS_HTTP1_HEADER_READ_TIMEOUT)" = "null" ] || bad "case $case: the idle timeout is raised outside traefik mode"
esac
# The S3 routers exist exactly when exposure.mode routes the S3 API.
case "$case" in
  traefik|edge)
    for l in "traefik.http.services.ci.loadbalancer.server.port=$port" 'traefik.http.routers.ci-http.service=ci'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: label $l is missing"
    done
    ;;
  *)
    if grep -E '^traefik\.http\.(routers\.ci-https?|services\.ci)\.' <<<"$labels" >/dev/null; then
      bad "case $case: an S3 router or service is rendered although exposure.mode does not route the S3 API"
    fi
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
  # The console alone, plain HTTP: console.ingress.tls, not ingress.tls, decides its routers.
  console-edge)
    if grep -F 'https' <<<"$labels" >/dev/null; then bad "case $case: console.ingress.tls is off but an https router or redirect is rendered"; fi
    for l in 'traefik.http.routers.ci-console-http.rule=Host(`rustfs-console.e2e.test`)' \
             'traefik.http.routers.ci-console-http.service=ci-console' \
             'traefik.http.services.ci-console.loadbalancer.server.port=9001'; do
      grep -Fx "$l" <<<"$labels" >/dev/null || bad "case $case: console label $l is missing"
    done
    ;;
esac

# ── single sign-on: the client secret only through the wrapper ───────────────────────
if [ "$(q "$svc.environment | keys | .[]" | grep -E 'IDENTITY_OPENID_CLIENT_SECRET' || true)" != "" ]; then
  bad "case $case: an OIDC client secret is set in environment:, where it lands in the manifest and docker inspect"
fi
if [ "$case" = "oidc" ]; then
  [ "$(env_ RUSTFS_IDENTITY_OPENID_CONFIG_URL)" = "http://rustfs-e2e-idp:8080/realms/e2e/.well-known/openid-configuration" ] \
    || bad "case $case: RUSTFS_IDENTITY_OPENID_CONFIG_URL is not oidc.configUrl"
  [ "$(env_ RUSTFS_IDENTITY_OPENID_CLIENT_ID)" = "rustfs-e2e" ] || bad "case $case: RUSTFS_IDENTITY_OPENID_CLIENT_ID is not oidc.clientId"
  [ "$(env_ RUSTFS_BROWSER_REDIRECT_URL)" = "https://rustfs-console.e2e.test" ] \
    || bad "case $case: RUSTFS_BROWSER_REDIRECT_URL is not derived from console.ingress (got '$(env_ RUSTFS_BROWSER_REDIRECT_URL)') — the callback would follow the request's Host header"
  [ "$(env_ RUSTFS_OUTBOUND_ALLOW_ORIGINS)" = "http://rustfs-e2e-idp:8080" ] \
    || bad "case $case: RUSTFS_OUTBOUND_ALLOW_ORIGINS is not the origin of oidc.configUrl (got '$(env_ RUSTFS_OUTBOUND_ALLOW_ORIGINS)') — RustFS would refuse the provider on its overlay address"
  [ "$(q "$svc.secrets[2]")" = "rustfs-oidc-client-secret" ] && [ "$(q '.secrets."rustfs-oidc-client-secret".external')" = "true" ] \
    || bad "case $case: the OIDC client secret is not mounted as the external secret rustfs-oidc-client-secret"
  grep -F 'done; f=/run/secrets/rustfs-oidc-client-secret; RUSTFS_IDENTITY_OPENID_CLIENT_SECRET="$$(cat "$$f" 2>/dev/null || true)"; if [ -z "$$RUSTFS_IDENTITY_OPENID_CLIENT_SECRET" ]; then echo' <<<"$script" >/dev/null \
    && grep -F 'export RUSTFS_IDENTITY_OPENID_CLIENT_SECRET;' <<<"$script" >/dev/null \
    || bad "case $case: the wrapper does not export the client secret from /run/secrets/rustfs-oidc-client-secret, refusing an empty one"
else
  for v in RUSTFS_IDENTITY_OPENID_CONFIG_URL RUSTFS_IDENTITY_OPENID_CLIENT_ID RUSTFS_BROWSER_REDIRECT_URL RUSTFS_OUTBOUND_ALLOW_ORIGINS; do
    [ "$(env_ "$v")" = "null" ] || bad "case $case: $v is set although oidc is off"
  done
  [ "$(q "$svc.secrets | length")" = "2" ] || bad "case $case: a third secret is mounted although oidc is off"
  if grep -F 'CLIENT_SECRET' <<<"$script" >/dev/null; then bad "case $case: the wrapper reads an OIDC client secret although oidc is off"; fi
fi

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

# ── refusals and one-off renders (from the default fixture only) ──────────────────────
if [ "$case" = "default" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.err"' EXIT
  render() { "${SWARMCLI:?render-check needs SWARMCLI to render the refusals}" charts template ci "$chart" "$@" >"$tmp" 2>"$tmp.err"; }
  refused() {
    local want="$1"; shift
    if render "$@"; then
      bad "rendered with $* — it must be refused"
    elif ! grep -F "$want" "$tmp.err" >/dev/null; then
      bad "$* failed, but not with \"$want\": $(tr '\n' ' ' <"$tmp.err")"
    fi
  }
  refused 'console.ingress.host is required' --set console.enabled=true --set console.exposure.mode=traefik
  refused 'console.ingress.host must differ from ingress.host' --set exposure.mode=traefik --set console.enabled=true \
    --set console.exposure.mode=traefik --set console.ingress.host=s3.example.com
  refused 'console.publish.port must differ from publish.port' --set exposure.mode=published --set console.enabled=true \
    --set console.exposure.mode=published --set console.publish.port=9000
  refused 'console.port must differ from s3.port' --set console.enabled=true --set console.port=9000
  kc=https://kc.example.com/realms/r/.well-known/openid-configuration
  refused 'oidc.configUrl must be' --set oidc.enabled=true
  refused 'oidc.configUrl must be' --set oidc.enabled=true --set oidc.configUrl=https://u:p@kc.example.com/realms/r
  refused 'oidc.browserUrl is required' --set oidc.enabled=true --set oidc.configUrl=$kc --set console.enabled=true
  refused '/oidc/clientSecretSecret' --set oidc.enabled=true --set oidc.configUrl=$kc --set oidc.clientSecretSecret=
  for k in RUSTFS_IDENTITY_OPENID_CLIENT_SECRET MINIO_IDENTITY_OPENID_CLIENT_SECRET RUSTFS_IDENTITY_OPENID_CLIENT_SECRET_kc2; do
    refused "extraEnv: $k is a credential" --set "extraEnv.$k=x"
  done
  for k in RUSTFS_IDENTITY_OPENID_CONFIG_URL MINIO_IDENTITY_OPENID_CONFIG_URL RUSTFS_IDENTITY_OPENID_CLIENT_ID \
           MINIO_IDENTITY_OPENID_CLIENT_ID RUSTFS_BROWSER_REDIRECT_URL; do
    refused "extraEnv: $k is set by the chart from oidc" --set oidc.enabled=true --set oidc.configUrl=$kc --set "extraEnv.$k=x"
    render --set "extraEnv.$k=x" || bad "extraEnv.$k was refused although oidc is off: $(tr '\n' ' ' <"$tmp.err")"
  done
  # With the console off nothing needs a callback; an explicit browserUrl wins over the derived one;
  # an extraEnv allow-list replaces the chart's.
  envt() { yq -r "$svc.environment.$1" "$tmp"; }
  if render --set oidc.enabled=true --set oidc.configUrl=$kc; then
    [ "$(envt RUSTFS_BROWSER_REDIRECT_URL)" = "null" ] && [ "$(envt RUSTFS_OUTBOUND_ALLOW_ORIGINS)" = "https://kc.example.com" ] \
      || bad "oidc with the console off: callback base '$(envt RUSTFS_BROWSER_REDIRECT_URL)', allow-list '$(envt RUSTFS_OUTBOUND_ALLOW_ORIGINS)'"
  else
    bad "oidc with the console off was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  render --set oidc.enabled=true --set oidc.configUrl=$kc --set console.enabled=true --set console.exposure.mode=traefik \
    --set console.ingress.host=c.example.com --set oidc.browserUrl=https://sso.example.com \
    --set extraEnv.RUSTFS_OUTBOUND_ALLOW_ORIGINS=https://kc-backchannel:8443 \
    && [ "$(envt RUSTFS_BROWSER_REDIRECT_URL)" = "https://sso.example.com" ] \
    && [ "$(envt RUSTFS_OUTBOUND_ALLOW_ORIGINS)" = "https://kc-backchannel:8443" ] \
    || bad "oidc.browserUrl or an extraEnv RUSTFS_OUTBOUND_ALLOW_ORIGINS does not win over the chart's own"
  # A disabled console is exposed nowhere, whatever console.exposure says (prometheus-stack's rule).
  for m in traefik published; do
    if render --set console.exposure.mode="$m"; then
      [ "$(yq -r "$svc.deploy.labels" "$tmp")" = "null" ] && [ "$(yq -r "$svc.ports" "$tmp")" = "null" ] \
        && [ "$(yq -r "$svc.networks | length" "$tmp")" = "1" ] \
        || bad "console.exposure.mode=$m with the console off still routes, publishes or joins the edge"
    else
      bad "console.exposure.mode=$m with the console off was refused: $(tr '\n' ' ' <"$tmp.err")"
    fi
  done
fi

exit "$fail"
