#!/usr/bin/env bash
#
# Render assertions for the harbor chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it guards is mostly what a deploy cannot see:
#
#   * Harbor reads no secret from a *_FILE variable, so every wrapper exports them from
#     /run/secrets. A secret value in environment: lands in the manifest and docker inspect;
#     a single `$` in a wrapper is resolved by Docker at deploy time, on the wrong machine.
#   * Only nginx is exposed, and only core, jobservice and the exporter reach the database
#     (jobservice reads the database's address from core and connects itself). Valkey has
#     no password, so it must stay on the stack's own overlay.
#   * The registry, registryctl and Valkey keep data on the pinned node; the pin must never
#     outlive the volume (persistence off, or S3 for the registry).
#   * Metrics are opt-in: exactly core, jobservice, the registry and the exporter join the
#     metrics overlay, with exactly the two discovery labels.
#   * OIDC reaches Harbor through CONFIG_OVERWRITE_JSON with the client secret spliced in by
#     the wrapper, never written into the manifest.
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
q() { yq -r "$1" "$rendered"; }
env_() { q ".services.$1.environment.$2"; }
nets() { q ".services.$1.networks | join(\" \")"; }
pins() { q ".services.$1.deploy.placement.constraints // [] | join(\",\")"; }

case "$case" in
  metrics) metrics=1 ;;
  *) metrics=0 ;;
esac
trivy=1; [ "$case" = "s3" ] && trivy=0

# ── the services ──────────────────────────────────────────────────────────────────────
want="core jobservice nginx portal registry registryctl valkey"
[ "$trivy" = 1 ] && want="$want trivy"
[ "$metrics" = 1 ] && want="$want exporter"
want="$(tr ' ' '\n' <<<"$want" | sort | tr '\n' ' ')"
got="$(q '.services | keys | .[]' | sort | tr '\n' ' ')"
[ "$got" = "$want" ] || bad "services are '$got', expected '$want'"

# ── wrappers: secrets exported from files, never written into the manifest ────────────
for s in core jobservice registry registryctl exporter; do
  [ "$(q ".services.$s // \"\"")" = "" ] && continue
  script="$(q ".services.$s.command[0]")"
  [ "$(q ".services.$s.entrypoint | join(\" \")")" = "/bin/bash -c" ] || bad "$s: entrypoint is not [/bin/bash, -c]"
  grep -F 'rd() { f=/run/secrets/$$2; v="$$(cat "$$f" 2>/dev/null || true)"; if [ -z "$$v" ]; then echo' <<<"$script" >/dev/null \
    || bad "$s: the wrapper has no rd() that refuses a missing or empty secret"
  if grep -E '(^|[^$])\$[({A-Za-z_#@]' <<<"$script" >/dev/null; then
    bad "$s: the start-up script has an unescaped \$ ($(grep -oE '(^|[^$])\$[({A-Za-z_#@][^ ]{0,20}' <<<"$script" | sed -n 1p)): Docker would interpolate it at deploy time"
  fi
  for v in POSTGRESQL_PASSWORD HARBOR_ADMIN_PASSWORD CORE_SECRET JOBSERVICE_SECRET CSRF_KEY REGISTRY_CREDENTIAL_PASSWORD \
           REGISTRY_HTTP_SECRET REGISTRY_STORAGE_S3_ACCESSKEY REGISTRY_STORAGE_S3_SECRETKEY HARBOR_DATABASE_PASSWORD \
           HARBOR_OIDC_CLIENT_SECRET; do
    [ "$(env_ "$s" "$v")" = "null" ] || bad "$s: $v is set in environment:, where it lands in the manifest and docker inspect"
  done
done
core="$(q '.services.core.command[0]')"
# Every secret each component needs, exported from the secret of that name. A missing one does
# not always fail: the registry picks a random http secret, and registryctl's health check
# never authenticates, so convergence cannot stand in for this.
exports() {  # $1 service, then VAR=secret pairs
  local svc="$1"; shift
  for pair in "$@"; do
    grep -Fx "rd ${pair%%=*} ${pair#*=}" <<<"$(q ".services.$svc.command[0]")" >/dev/null \
      || bad "$svc: the wrapper does not export ${pair%%=*} from secret ${pair#*=}"
  done
}
exports core POSTGRESQL_PASSWORD=harbor-db-password HARBOR_ADMIN_PASSWORD=harbor-admin-password \
  CORE_SECRET=harbor-core-secret JOBSERVICE_SECRET=harbor-jobservice-secret CSRF_KEY=harbor-csrf-key \
  REGISTRY_CREDENTIAL_PASSWORD=harbor-registry-password
exports jobservice CORE_SECRET=harbor-core-secret JOBSERVICE_SECRET=harbor-jobservice-secret \
  REGISTRY_CREDENTIAL_PASSWORD=harbor-registry-password
exports registry REGISTRY_HTTP_SECRET=harbor-registry-http-secret
exports registryctl CORE_SECRET=harbor-core-secret JOBSERVICE_SECRET=harbor-jobservice-secret
if [ "$case" = "s3" ]; then
  for s in registry registryctl; do
    exports "$s" REGISTRY_STORAGE_S3_ACCESSKEY=harbor-s3-access-key REGISTRY_STORAGE_S3_SECRETKEY=harbor-s3-secret-key
  done
fi
[ "$metrics" = 1 ] && exports exporter HARBOR_DATABASE_PASSWORD=harbor-db-password
grep -F 'if [ "$${#CSRF_KEY}" -ne 32 ]' <<<"$core" >/dev/null || bad "core: the wrapper does not refuse a CSRF key that is not 32 characters"
grep -F 'n="$$(wc -c < "$$KEY_PATH")"' <<<"$core" >/dev/null && grep -F 'if [ "$$n" -ne 16 ]' <<<"$core" >/dev/null \
  || bad "core: the wrapper does not refuse a secret key that is not exactly 16 bytes"
grep -F 'if [ "$$first" != "-----BEGIN RSA PRIVATE KEY-----" ]' <<<"$core" >/dev/null \
  || bad "core: the wrapper does not refuse a token key that is not PKCS#1 (libtrust reads no other; every docker login would 500)"
[ "$(tail -n1 <<<"$core")" = "exec /harbor/entrypoint.sh" ] || bad "core: the wrapper does not end by exec'ing the image's entrypoint"
[ "$(env_ core KEY_PATH)" = "/run/secrets/harbor-secret-key" ] && [ "$(env_ core TOKEN_PRIVATE_KEY_PATH)" = "/run/secrets/harbor-token-key" ] \
  || bad "core: KEY_PATH / TOKEN_PRIVATE_KEY_PATH do not point at the mounted secrets"
for s in $(q '.secrets | keys | .[]'); do
  [ "$(q ".secrets.\"$s\".external")" = "true" ] || bad "secret $s is not external: the chart must never create one"
done

# ── networks: only nginx is exposed, only core, jobservice and the exporter reach the database
db=postgres-net
case "$case" in published|oidc|metrics) db=harbor-e2e-db-net ;; esac
for s in $(q '.services | keys | .[]'); do
  n=" $(nets "$s") "
  grep -F ' internal ' <<<"$n" >/dev/null || bad "$s is not on the stack's internal overlay"
  case "$s" in
    nginx) ;;
    *) if grep -F ' traefik-public ' <<<"$n" >/dev/null; then bad "$s joins the edge overlay; only nginx may"; fi ;;
  esac
  case "$s" in
    core|jobservice|exporter) grep -F " $db " <<<"$n" >/dev/null || bad "$s does not join $db" ;;
    *) if grep -F " $db " <<<"$n" >/dev/null; then bad "$s joins $db; only core, jobservice and the exporter reach the database"; fi ;;
  esac
  [ "$(q ".services.$s.ports // [] | length")" = "0" ] || [ "$s" = "nginx" ] || bad "$s publishes a port; only nginx may"
done
[ "$(nets valkey)" = "internal" ] || bad "valkey is on '$(nets valkey)'; it has no password and must stay on internal alone"
[ "$(q '.networks.internal.external // false')" = "false" ] || bad "the internal overlay is external; it must be the stack's own"

# ── components dial each other by full service name ──────────────────────────────
# A short name is an alias on every external overlay too, where another stack's service of
# that name answers.
for s in $(q '.services | keys | .[]'); do
  short="$(q ".services.$s.environment // {} | to_entries | .[] | .value" | grep -E '://(core|portal|jobservice|registry|registryctl|valkey|trivy|exporter):' || true)"
  [ -z "$short" ] || bad "$s dials a short service name: $short"
done
[ "$(env_ core CORE_URL)" = "http://ci_core:8080" ] && [ "$(env_ jobservice CORE_URL)" = "http://ci_core:8080" ] \
  && [ "$(env_ jobservice JOB_SERVICE_POOL_REDIS_URL)" = "redis://ci_valkey:6379/2?idle_timeout_seconds=30" ] \
  || bad "core/jobservice do not dial ci_core and ci_valkey"
[ "$(env_ nginx HARBOR_CORE)/$(env_ nginx HARBOR_PORTAL)" = "ci_core/ci_portal" ] \
  && [ "$(q '.configs.nginx.template_driver')" = "golang" ] \
  || bad "nginx is not told ci_core / ci_portal through its templated config"
nginxconf="$(dirname "$0")/../files/nginx/nginx.conf"
grep -F 'set $core "{{ env "HARBOR_CORE" }}:8080";' "$nginxconf" >/dev/null \
  && grep -F 'resolver 127.0.0.11' "$nginxconf" >/dev/null \
  || bad "files/nginx/nginx.conf does not resolve HARBOR_CORE per request through Swarm's DNS"
if grep -E '^[[:space:]]*(upstream|server [a-z]+:[0-9])' "$nginxconf" >/dev/null; then
  bad "files/nginx/nginx.conf has an upstream block: nginx resolves it once at start and exits while core has no healthy task"
fi
for f in config.yml config-metrics.yml; do
  if grep -E 'redis_url:' "$(dirname "$0")/../files/jobservice/$f" >/dev/null; then bad "files/jobservice/$f names a redis_url; it comes from JOB_SERVICE_POOL_REDIS_URL"; fi
done
grep -F 'until curl -fsS -o /dev/null --max-time 5 "$$CORE_URL/api/v2.0/ping"' <<<"$(q '.services.jobservice.command[0]')" >/dev/null \
  || bad "jobservice does not wait for core; started first it exits, which pauses a rollout"

# ── exposure ──────────────────────────────────────────────────────────────────────────
labels="$(q '.services.nginx.deploy.labels // [] | .[]')"
ext="$(env_ core EXT_ENDPOINT)"
case "$case" in
  published|oidc|metrics)
    [ "$(q '.services.nginx.ports[0].published')/$(q '.services.nginx.ports[0].target')" = "18080/8080" ] \
      || bad "published: nginx does not publish 18080 -> 8080"
    [ "$(nets nginx)" = "internal" ] || bad "published: nginx joins '$(nets nginx)', expected internal only"
    [ "$ext" = "http://127.0.0.1:18080" ] || bad "published: EXT_ENDPOINT is '$ext', not externalURL"
    if grep -F 'traefik.' <<<"$labels" >/dev/null; then bad "published: nginx carries Traefik labels"; fi
    ;;
  none)
    [ "$(nets nginx)" = "internal traefik-public" ] || bad "none: nginx joins '$(nets nginx)', expected internal and traefik-public"
    [ "$(q '.services.nginx.ports // [] | length')" = "0" ] || bad "none: nginx publishes a port"
    [ -z "$labels" ] || bad "none: nginx carries labels"
    [ "$ext" = "https://registry.example.com" ] || bad "none: EXT_ENDPOINT is '$ext', not externalURL"
    ;;
  *)
    grep -Fx 'traefik.constraint-label=traefik-public' <<<"$labels" >/dev/null \
      && grep -Fx 'traefik.swarm.network=traefik-public' <<<"$labels" >/dev/null \
      && grep -Fx 'traefik.http.routers.ci-http.rule=Host(`harbor.example.com`)' <<<"$labels" >/dev/null \
      && grep -Fx 'traefik.http.services.ci.loadbalancer.server.port=8080' <<<"$labels" >/dev/null \
      || bad "traefik: nginx lacks the constraint label, swarm network, HTTP router or service port"
    if [ "$case" = "tls-off" ]; then
      if grep -E 'ci-https|middlewares' <<<"$labels" >/dev/null; then bad "tls-off: an HTTPS router or the redirect middleware is rendered"; fi
      [ "$ext" = "http://harbor.example.com" ] || bad "tls-off: EXT_ENDPOINT is '$ext'"
    else
      grep -Fx 'traefik.http.routers.ci-http.middlewares=https-redirect' <<<"$labels" >/dev/null \
        && grep -Fx 'traefik.http.routers.ci-https.tls.certresolver=le' <<<"$labels" >/dev/null \
        || bad "traefik: the redirect or the HTTPS router is missing"
      [ "$ext" = "https://harbor.example.com" ] || bad "traefik: EXT_ENDPOINT is '$ext'"
    fi
    ;;
esac
# nginx answers /v1/ itself, so its healthcheck does not depend on portal or core.
grep -F '/v1/' <<<"$(q '.services.nginx.healthcheck.test | join(" ")')" >/dev/null || bad "nginx's healthcheck does not probe /v1/"

# ── storage, volumes and the data pin ─────────────────────────────────────────────────
regcfg="$(env_ registry HARBOR_REGISTRY_CONFIG)"
[ "$regcfg" = "$(env_ registryctl HARBOR_REGISTRY_CONFIG)" ] || bad "registry and registryctl run different registry configurations"
rc() { yq -r "$1" <<<"$regcfg"; }
[ "$(rc '.auth.htpasswd.path')" = "/run/secrets/harbor-registry-htpasswd" ] || bad "the registry does not check logins against the htpasswd secret"
[ "$(rc '.redis.addr')" = "ci_valkey:6379" ] || bad "the registry's cache is not ci_valkey"
for s in registry registryctl; do
  [ "$(q ".services.$s.user")" = "0:0" ] || bad "$s does not start as root, so it cannot take ownership of the storage"
  grep -F "exec su -s /bin/sh harbor -c 'exec /home/harbor/" <<<"$(q ".services.$s.command[0]")" >/dev/null \
    || bad "$s does not hand over to uid 10000 through su"
done
if [ "$case" = "s3" ]; then
  [ "$(rc '.storage.s3.regionendpoint')/$(rc '.storage.s3.bucket')/$(rc '.storage.s3.rootdirectory')" = "http://rustfs-rustfs:9000/harbor/registry" ] \
    || bad "s3: the registry's s3 driver is not endpoint/bucket/rootdirectory from the values"
  [ "$(rc '.storage.filesystem')" = "null" ] || bad "s3: a filesystem driver is configured too; the registry refuses two"
  [ "$(rc '.storage.redirect.disable')" = "true" ] || bad "s3: redirects are on; clients cannot reach an overlay endpoint"
  [ "$(env_ core REGISTRY_STORAGE_PROVIDER_NAME)" = "s3" ] || bad "s3: core is not told the storage provider is s3"
  for s in registry registryctl; do
    grep -E '^rd REGISTRY_STORAGE_S3_ACCESSKEY harbor-s3-access-key$' <<<"$(q ".services.$s.command[0]")" >/dev/null \
      || bad "s3: $s does not export the S3 access key from its secret"
    [ "$(q ".services.$s.volumes // [] | length")" = "0" ] || bad "s3: $s mounts a volume"
    [ "$(pins "$s")" = "" ] || bad "s3: $s is pinned to the data node, which holds no data of its"
    grep -F ' rustfs-net' <<<" $(nets "$s")" >/dev/null || bad "s3: $s does not join storage.s3.network"
    if grep -F 'chown' <<<"$(q ".services.$s.command[0]")" >/dev/null; then bad "s3: $s still takes ownership of a /storage it does not use"; fi
  done
  [ "$(pins valkey)" = "node.labels.harbor-data == true" ] || bad "s3: valkey lost its pin"
  [ "$(env_ core WITH_TRIVY)" = "false" ] || bad "s3 (trivy off): core still registers the scanner"
else
  [ "$(rc '.storage.filesystem.rootdirectory')" = "/storage" ] || bad "the registry does not store layers under /storage"
  [ "$(rc '.storage.s3')" = "null" ] || bad "an s3 driver is configured with storage.type=filesystem"
  for s in registry registryctl; do
    grep -F 'mkdir -p /storage; chown 10000:10000 /storage; exec su' <<<"$(q ".services.$s.command[0]")" >/dev/null \
      || bad "$s does not take ownership of /storage before handing over"
  done
  [ "$(env_ core WITH_TRIVY)" = "true" ] || bad "core does not register the scanner"
  case "$case" in
    ephemeral)
      for s in registry registryctl valkey; do
        [ "$(q ".services.$s.volumes // [] | length")" = "0" ] || bad "ephemeral: $s mounts a volume"
        [ "$(pins "$s")" = "" ] || bad "ephemeral: $s is pinned although nothing is persisted"
      done
      [ "$(q '.volumes // {} | length')" = "0" ] || bad "ephemeral: volumes are declared"
      ;;
    bind-mount)
      [ "$(q '.services.registry.volumes[0]')" = "/srv/harbor/registry:/storage" ] \
        && [ "$(q '.services.registryctl.volumes[0]')" = "/srv/harbor/registry:/storage" ] \
        && [ "$(q '.services.valkey.volumes[0]')" = "/srv/harbor/valkey:/var/lib/redis" ] \
        || bad "bind-mount: the host paths are not mounted"
      [ "$(q '.volumes // {} | length')" = "0" ] || bad "bind-mount: named volumes are declared as well"
      for s in registry registryctl valkey; do
        [ "$(pins "$s")" = "node.labels.harbor-node == true" ] || bad "bind-mount: $s is not pinned to harbor-node"
      done
      ;;
    *)
      # The e2e fixtures run on CI's single node with nodeLabel: "", which drops the pin.
      pin="node.labels.harbor-data == true"
      case "$case" in published|oidc|metrics) pin="" ;; esac
      for s in registry registryctl valkey; do
        [ "$(pins "$s")" = "$pin" ] || bad "$s is pinned to '$(pins "$s")', expected '$pin'"
      done
      [ "$(q '.services.registry.volumes[0]')" = "harbor-registry:/storage" ] \
        && [ "$(q '.services.registryctl.volumes[0]')" = "harbor-registry:/storage" ] \
        && [ "$(q '.services.valkey.volumes[0]')" = "harbor-valkey:/var/lib/redis" ] \
        || bad "the registry, registryctl and Valkey volumes are not mounted"
      ;;
  esac
fi
for s in nginx core portal jobservice trivy exporter; do
  [ "$(q ".services.$s // \"\"")" = "" ] && continue
  [ "$(pins "$s")" = "" ] || bad "$s is pinned ($(pins "$s")); it keeps no data"
done
for s in registry registryctl valkey; do
  [ "$(q ".services.$s.deploy.update_config.order")" = "stop-first" ] || bad "$s does not stop the old task first"
done

# ── metrics ───────────────────────────────────────────────────────────────────────────
scraped="$(q '.services | to_entries | .[] | select(.value.deploy.labels // [] | .[] | test("^prometheus.io/")) | .key' | sort -u | tr '\n' ' ')"
if [ "$metrics" = 1 ]; then
  [ "$scraped" = "core exporter jobservice registry " ] || bad "metrics: the scraped services are '$scraped'"
  for s in core exporter jobservice registry; do
    [ "$(q ".services.$s.deploy.labels | join(\" \")")" = "prometheus.io/scrape=true prometheus.io/port=8001" ] \
      || bad "metrics: $s's deploy labels are '$(q ".services.$s.deploy.labels | join(\" \")")', expected exactly the two discovery labels"
    grep -F ' monitoring ' <<<" $(nets "$s") " >/dev/null || bad "metrics: $s does not join monitoring"
  done
  for s in nginx portal registryctl valkey trivy; do
    if grep -F ' monitoring ' <<<" $(nets "$s") " >/dev/null; then bad "metrics: $s joins monitoring"; fi
  done
  [ "$(env_ core METRIC_ENABLE)/$(env_ core METRIC_PORT)" = "true/8001" ] || bad "metrics: core does not serve metrics on 8001"
  [ "$(rc '.http.debug.addr')/$(rc '.http.debug.prometheus.enabled')" = ":8001/true" ] || bad "metrics: the registry does not serve metrics on 8001"
  [ "$(q '.services.jobservice.configs[0].source')" = "jobservice-metrics" ] \
    && [ "$(q '.configs.jobservice-metrics.file')" = "files/jobservice/config-metrics.yml" ] \
    || bad "metrics: jobservice does not get the config with metrics on"
  [ "$(q '.configs.jobservice-metrics.name')" = "ci_jobservice-metrics_0.1.0" ] \
    || bad "metrics: the jobservice config's name does not say metrics; toggling them would update a config Swarm refuses to update"
  [ "$(nets exporter)" = "internal $db monitoring" ] || bad "metrics: the exporter joins '$(nets exporter)'"
  grep -Fx 'team=registry' <<<"$labels" >/dev/null || bad "metrics: labels did not reach nginx"
else
  [ -z "$scraped" ] || bad "metrics off, but '$scraped' carry discovery labels"
  [ "$(q '.networks.monitoring // ""')" = "" ] || bad "metrics off, but the monitoring overlay is declared"
  [ "$(rc '.http.debug')" = "null" ] || bad "metrics off, but the registry's debug listener is configured"
  [ "$(env_ core METRIC_ENABLE)" = "null" ] || bad "metrics off, but core serves metrics"
  [ "$(q '.services.jobservice.configs[0].source')" = "jobservice" ] || bad "metrics off, but jobservice gets the metrics config"
fi
diff <(sed '/^# /d' "$(dirname "$0")/../files/jobservice/config.yml") \
     <(sed '/^# /d; /^metric:$/,/^$/d' "$(dirname "$0")/../files/jobservice/config-metrics.yml") >/dev/null \
  || bad "files/jobservice/config.yml and config-metrics.yml differ in more than the metric block"

# ── system settings: oidc.* and config ────────────────────────────────────────────────
case "$case" in
  oidc)
    j="$(env_ core HARBOR_CONFIG_OVERWRITE)"
    [ "$(env_ core CONFIG_OVERWRITE_JSON)" = "null" ] || bad "oidc: CONFIG_OVERWRITE_JSON is in environment:; the wrapper must build it"
    jq_() { yq -p json -r "$1" <<<"$j"; }
    [ "$(jq_ .auth_mode)" = "oidc_auth" ] && [ "$(jq_ .oidc_endpoint)" = "http://harbor-e2e-idp:8080/realms/e2e" ] \
      && [ "$(jq_ .oidc_client_id)" = "harbor" ] && [ "$(jq_ .oidc_user_claim)" = "preferred_username" ] \
      && [ "$(jq_ .oidc_auto_onboard)" = "true" ] && [ "$(jq_ .oidc_verify_cert)" = "true" ] \
      && [ "$(jq_ .oidc_admin_group)" = "harbor-admins" ] && [ "$(jq_ .project_creation_restriction)" = "adminonly" ] \
      || bad "oidc: the settings are not those of the values: $j"
    [ "$(jq_ .oidc_client_secret)" = "__HARBOR_OIDC_CLIENT_SECRET__" ] || bad "oidc: the client secret is not the placeholder the wrapper replaces"
    grep -E '^rd HARBOR_OIDC_CLIENT_SECRET harbor-oidc-client-secret$' <<<"$core" >/dev/null \
      && grep -F 'export CONFIG_OVERWRITE_JSON="$${HARBOR_CONFIG_OVERWRITE/__HARBOR_OIDC_CLIENT_SECRET__/"$$HARBOR_OIDC_CLIENT_SECRET"}"' <<<"$core" >/dev/null \
      || bad "oidc: the wrapper does not splice the client secret into CONFIG_OVERWRITE_JSON"
    grep -Fx -- '- harbor-oidc-client-secret' <<<"$(q '.services.core.secrets' )" >/dev/null || bad "oidc: core does not mount the client secret"
    ;;
  config)
    j="$(env_ core CONFIG_OVERWRITE_JSON)"
    [ "$(yq -p json -r .project_creation_restriction <<<"$j")" = "adminonly" ] || bad "config: CONFIG_OVERWRITE_JSON does not carry config: $j"
    [ "$(yq -p json -r .robot_name_prefix <<<"$j")" = 'robot$$' ] || bad "config: a \$ is not escaped for compose: $j"
    [ "$(env_ core HARBOR_CONFIG_OVERWRITE)" = "null" ] || bad "config: the OIDC placeholder variable is set without OIDC"
    if grep -F 'CONFIG_OVERWRITE' <<<"$core" >/dev/null; then bad "config: the wrapper touches CONFIG_OVERWRITE_JSON without OIDC"; fi
    ;;
  *)
    [ "$(env_ core CONFIG_OVERWRITE_JSON)/$(env_ core HARBOR_CONFIG_OVERWRITE)" = "null/null" ] \
      || bad "no oidc and no config, yet Harbor's settings are overwritten (which makes every one read-only in the UI)"
    ;;
esac

# ── refusals (from the default fixture only) ──────────────────────────────────────────
if [ "$case" = "default" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.err"' EXIT
  render() { "${SWARMCLI:?render-check needs SWARMCLI to render the refusals}" charts template ci "$chart" "$@" >"$tmp" 2>"$tmp.err"; }
  refused() {
    local want="$1"; shift
    if render "$@"; then
      bad "rendered with $* — it must be refused"
    elif ! grep -F -- "$want" "$tmp.err" >/dev/null; then
      bad "$* failed, but not with \"$want\": $(tr '\n' ' ' <"$tmp.err")"
    fi
  }
  refused 'externalURL is required when exposure.mode=published' --set exposure.mode=published
  refused 'externalURL is required when exposure.mode=none' --set exposure.mode=none
  refused 'externalURL must be scheme://host[:port]' --set externalURL=https://harbor.example.com/
  refused 'externalURL must be scheme://host[:port]' --set externalURL=harbor.example.com
  refused 'ingress.host is required' --set ingress.host=
  refused 'config.auth_mode is set by the chart' --set oidc.enabled=true --set oidc.endpoint=https://kc.example.com/realms/r --set config.auth_mode=db_auth
  render --set config.auth_mode=ldap_auth && [ "$(yq -r .services.core.environment.CONFIG_OVERWRITE_JSON "$tmp")" = '{"auth_mode":"ldap_auth"}' ] \
    || bad "config.auth_mode without OIDC (e.g. LDAP) was refused or not passed on: $(tr '\n' ' ' <"$tmp.err")"
  refused 'config.oidc_client_secret is set by the chart' --set config.oidc_client_secret=x
  refused 'oidc.endpoint must be' --set oidc.enabled=true
  refused 'is not a Docker secret name' --set 'oidc.enabled=true' --set oidc.endpoint=https://kc.example.com/realms/r --set 'oidc.clientSecretSecret=x;id'
  refused 'is not a Docker secret name' --set 'secrets.core=a b'
  refused 'must name a different Swarm secret' --set secrets.jobservice=harbor-core-secret
  refused 'metrics.network must differ' --set metrics.enabled=true --set metrics.network=postgres-net
  refused 'metrics.network must differ' --set metrics.enabled=true --set metrics.network=traefik-public
  refused 'storage.s3.bucket' --set storage.type=s3 --set storage.s3.bucket=Bad_Bucket
  refused 'storage.s3.endpoint must be' --set storage.type=s3 --set storage.s3.endpoint=rustfs:9000
  refused 'persistence.registryVolume is a Docker named-volume name' --set persistence.registryVolume=a/b
fi

exit "$fail"
