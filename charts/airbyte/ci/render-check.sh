#!/usr/bin/env bash
#
# Render-time assertions for the airbyte chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy).
#
# The public scheme is the point: oauth2-proxy's callback and AIRBYTE_URL must follow
# exposure.tls, or login over a plain-HTTP published port redirects into https:// and fails.
set -euo pipefail

out="$1"
case="${2:-}"

scheme=https
host=airbyte.example.com
case "$case" in
  published|login-published) scheme=http ;;
  noauth|login) scheme=http; host=airbyte.e2e.test ;;
esac

fail=0

[ "$(grep -c "AIRBYTE_URL: $scheme://$host" "$out")" -eq 2 ] \
  || { echo "  FAIL($case): server and worker AIRBYTE_URL are not both $scheme://"; fail=1; }

# Every mode: each service that signs or checks Airbyte's internal JWTs reads the one secret
# (2.3's worker refuses to start without it), and the Connector Builder's manifest server
# stays on the internal overlay, reachable only from the server.
for svc in server worker workload-api-server cron manifest-server; do
  yq -r ".services[\"$svc\"].command[2]" "$out" | grep -F 'AB_JWT_SIGNATURE_SECRET="$$(cat /run/secrets/airbyte_jwt_signature_secret)"' >/dev/null \
    && yq -e ".services[\"$svc\"].secrets[] | select(. == \"airbyte_jwt_signature_secret\")" "$out" >/dev/null 2>&1 \
    || { echo "  FAIL($case): $svc does not read the JWT signing secret"; fail=1; }
done
[ "$(yq -o=json -I=0 '.services["manifest-server"].networks' "$out")" = '["airbyte"]' ] \
  || { echo "  FAIL($case): the manifest server is not on the internal overlay alone"; fail=1; }

case "$case" in
  noauth*)
    # auth.mode none: no oauth2-proxy, nothing of its session store, and in traefik mode the
    # basic-auth middleware on the public router.
    yq -e '.services | has("oauth2-proxy") or has("oauth2-redis")' "$out" >/dev/null 2>&1 \
      && { echo "  FAIL($case): oauth2-proxy or its Redis rendered with auth.mode none"; fail=1; }
    if [ "$case" = "noauth" ]; then
      [ "$(grep -cE 'traefik\.http\.routers\.[^.]+-http\.middlewares=[^ ]+-auth$' "$out")" -eq 1 ] \
        || { echo "  FAIL($case): the public router does not carry the basic-auth middleware"; fail=1; }
    else
      grep -q 'traefik\.' "$out" && { echo "  FAIL($case): Traefik labels rendered with exposure.mode none"; fail=1; }
      [ "$(yq '.services.server.networks | map(select(. == "traefik-public")) | length' "$out")" -eq 1 ] \
        || { echo "  FAIL($case): the server does not join exposure.network"; fail=1; }
    fi
    ;;
  login*)
    # auth.mode airbyte: no oauth2-proxy; the server logs users in.
    yq -e '.services | has("oauth2-proxy") or has("oauth2-redis")' "$out" >/dev/null 2>&1 \
      && { echo "  FAIL($case): oauth2-proxy or its Redis rendered with auth.mode airbyte"; fail=1; }
    for svc in server workload-api-server; do
      [ "$(yq -r ".services[\"$svc\"].environment.API_AUTHORIZATION_ENABLED" "$out")" = true ] \
        || { echo "  FAIL($case): $svc does not enforce authorization"; fail=1; }
    done
    yq -r '.services.server.command[2]' "$out" | grep -F 'AB_INSTANCE_ADMIN_PASSWORD="$$(cat /run/secrets/airbyte_admin_password)"' >/dev/null \
      || { echo "  FAIL($case): the server does not read the admin password"; fail=1; }
    # Secure cookies are dropped over plain http, so the login would silently never stick.
    [ "$(yq -r '.services.server.environment.AB_COOKIE_SECURE' "$out")" = "$([ "$scheme" = https ] && echo true || echo false)" ] \
      || { echo "  FAIL($case): AB_COOKIE_SECURE does not follow the public scheme ($scheme)"; fail=1; }
    # setupComplete closes Airbyte's anonymous setup endpoint at the public router.
    if [ "$case" = "login" ]; then
      grep -E 'traefik\.http\.routers\.[^.]+-setup-http\.rule=.*Path\(`/api/v1/instance_configuration/setup`\)' "$out" >/dev/null \
        && grep -E 'traefik\.http\.routers\.[^.]+-setup-http\.middlewares=[^ ]+-setup-closed$' "$out" >/dev/null \
        && grep -F 'setup-closed.ipallowlist.sourcerange=127.0.0.1/32' "$out" >/dev/null \
        || { echo "  FAIL($case): setupComplete does not close the setup endpoint at Traefik"; fail=1; }
    elif grep -F 'instance_configuration/setup' "$out" >/dev/null; then
      echo "  FAIL($case): the setup endpoint is closed without auth.airbyte.setupComplete"; fail=1
    fi
    if [ "$case" = "login-published" ]; then
      [ "$(yq '.services.server.ports[0].target' "$out")" = 8001 ] \
        || { echo "  FAIL($case): the server does not own the published port"; fail=1; }
    fi
    ;;
  *)
    grep -q -- "--redirect-url=$scheme://$host/oauth2/callback" "$out" \
      || { echo "  FAIL($case): oauth2-proxy redirect-url is not $scheme://"; fail=1; }
    grep -q -- '--ssl-insecure-skip-verify=false' "$out" \
      || { echo "  FAIL($case): oauth2-proxy skips TLS verification by default"; fail=1; }
    ;;
esac

# auth.mode none refuses to serve Airbyte where nothing authenticates. Checked once, from the
# default fixture, by rendering the two refused combinations.
if [ "$case" = "default" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  refused() {
    local want="$1"; shift
    if "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" "$@" >/dev/null 2>"$out.refusal"; then
      echo "  FAIL($case): rendered with $* — it must be refused"; fail=1
    elif ! grep -qF "$want" "$out.refusal"; then
      echo "  FAIL($case): $* failed, but not with \"$want\":"; sed 's/^/    /' "$out.refusal"; fail=1
    fi
    rm -f "$out.refusal"
  }
  refused 'needs traefik.basicAuthUsers' --set auth.mode=none
  refused 'cannot use exposure.mode published' --set auth.mode=none --set exposure.mode=published \
    --set 'traefik.basicAuthUsers=u:$$apr1$$x$$y'
fi

# placement.constraints reaches every service that runs an Airbyte platform image: since 2.3.0 they
# all need an x86-64-v2 CPU, so one left unpinned can land on a node where glibc refuses to start.
if [ "$case" = "placement" ]; then
  for svc in db-migrations server worker workload-api-server workload-launcher cron; do
    yq -e ".services[\"$svc\"].deploy.placement.constraints[] | select(. == \"node.labels.x86-64-v2 == true\")" "$out" >/dev/null 2>&1 \
      || { echo "  FAIL($case): $svc does not carry placement.constraints"; fail=1; }
  done
fi

# One Airbyte release everywhere: every platform image carries the tag AIRBYTE_VERSION names,
# or a Renovate bump of appVersion runs mixed versions. The manifest server is the one exception:
# it ships with Airbyte's Python CDK, on its own version line.
versions="$(sed -n 's/^ *AIRBYTE_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$out" | sort -u)"
tags="$(grep -v 'image: airbyte/manifest-server:' "$out" | sed -n 's/^ *image: airbyte\/[a-z-]*:\(.*\)$/\1/p' | sort -u)"
{ [ "$(printf '%s\n' "$versions" | wc -l)" -eq 1 ] && [ "$tags" = "$versions" ]; } \
  || { echo "  FAIL($case): platform image tags [$(echo $tags)] != AIRBYTE_VERSION [$(echo $versions)]"; fail=1; }

# Only the workload launcher holds the Docker socket; the worker never starts containers.
[ "$(grep -c '/var/run/docker.sock:/var/run/docker.sock' "$out")" -eq 1 ] \
  || { echo "  FAIL($case): docker.sock is mounted into more than the workload launcher"; fail=1; }

# A private registry's config.json reaches FakeK8s: the launcher mounts the secret and names
# the same path in FAKEK8S_REGISTRY_AUTH_FILE; without the value, neither appears.
if [ "$case" = "registry-auth" ]; then
  grep -q 'FAKEK8S_REGISTRY_AUTH_FILE: "\{0,1\}/run/secrets/airbyte_registry_auth"\{0,1\}$' "$out" \
    && grep -q '^ *- airbyte_registry_auth$' "$out" \
    || { echo "  FAIL($case): registry auth secret not mounted where FAKEK8S_REGISTRY_AUTH_FILE points"; fail=1; }
elif grep -q 'FAKEK8S_REGISTRY_AUTH_FILE' "$out"; then
  echo "  FAIL($case): FAKEK8S_REGISTRY_AUTH_FILE set without workloadLauncher.registryAuthSecretName"; fail=1
fi

# The data pin follows the named volumes (session Redis and Temporal; Temporal alone with
# auth.mode none) and nothing else, and goes away with nodeLabel: "".
case "$case" in
  published|login-published) pins=0 ;;
  noauth*|login*) pins=1 ;;
  *) pins=2 ;;
esac
[ "$(grep -c 'node.labels.airbyte-data == true' "$out")" -eq "$pins" ] \
  || { echo "  FAIL($case): expected $pins data-node pin(s), one per named volume"; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "  $case: public URLs use $scheme://, auth.mode wiring checked, one Airbyte version, one socket mount, $pins data pin"
