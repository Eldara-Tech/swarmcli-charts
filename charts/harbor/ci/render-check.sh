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
#   * An external Redis (ha): every component dials it through the Sentinels in its own
#     database, and its password is spliced in by the wrappers, never written into the
#     manifest; only the components that use Redis join its overlay or hold its secret.
#   * Replicas: more than one is spread over the nodes, one renders no preference.
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
# Storage and Redis by what the fixture configures: s3 and ha keep layers in S3, ha uses the
# redis chart in sentinel mode instead of the valkey service.
s3=0; extredis=0; s3ep=http://rustfs-rustfs:9000; s3root=registry; s3net=rustfs-net
case "$case" in s3) s3=1 ;; ha) s3=1; extredis=1; s3ep=http://harbor-e2e-s3:8333; s3root=null; s3net=harbor-e2e-s3-net ;; esac
sentinels=harbor-e2e-redis-sentinel-1:26379,harbor-e2e-redis-sentinel-2:26379,harbor-e2e-redis-sentinel-3:26379
redisurl="redis://ci_valkey:6379"
[ "$extredis" = 1 ] && redisurl="redis+sentinel://:__HARBOR_REDIS_PASSWORD__@$sentinels/mymaster"

# ── the services ──────────────────────────────────────────────────────────────────────
want="core jobservice nginx portal registry registryctl"
[ "$extredis" = 0 ] && want="$want valkey"
[ "$trivy" = 1 ] && want="$want trivy"
[ "$metrics" = 1 ] && want="$want exporter"
want="$(tr ' ' '\n' <<<"$want" | sort | tr '\n' ' ')"
got="$(q '.services | keys | .[]' | sort | tr '\n' ' ')"
[ "$got" = "$want" ] || bad "services are '$got', expected '$want'"

# ── wrappers: secrets exported from files, never written into the manifest ────────────
for s in core jobservice registry registryctl exporter trivy; do
  [ "$(q ".services.$s // \"\"")" = "" ] && continue
  # Trivy has a wrapper only to splice in an external Redis's password.
  [ "$s" = trivy ] && [ "$(q '.services.trivy.command // ""')" = "" ] && continue
  script="$(q ".services.$s.command[0]")"
  [ "$(q ".services.$s.entrypoint | join(\" \")")" = "/bin/bash -c" ] || bad "$s: entrypoint is not [/bin/bash, -c]"
  grep -F 'rd() { f=/run/secrets/$$2; v="$$(cat "$$f" 2>/dev/null || true)"; if [ -z "$$v" ]; then echo' <<<"$script" >/dev/null \
    || bad "$s: the wrapper has no rd() that refuses a missing or empty secret"
  if grep -E '(^|[^$])\$[({A-Za-z_#@]' <<<"$script" >/dev/null; then
    bad "$s: the start-up script has an unescaped \$ ($(grep -oE '(^|[^$])\$[({A-Za-z_#@][^ ]{0,20}' <<<"$script" | sed -n 1p)): Docker would interpolate it at deploy time"
  fi
  for v in POSTGRESQL_PASSWORD HARBOR_ADMIN_PASSWORD CORE_SECRET JOBSERVICE_SECRET CSRF_KEY REGISTRY_CREDENTIAL_PASSWORD \
           REGISTRY_HTTP_SECRET REGISTRY_STORAGE_S3_ACCESSKEY REGISTRY_STORAGE_S3_SECRETKEY HARBOR_DATABASE_PASSWORD \
           HARBOR_OIDC_CLIENT_SECRET HARBOR_REDIS_PASSWORD REGISTRY_REDIS_PASSWORD; do
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
if [ "$s3" = 1 ]; then
  for s in registry registryctl; do
    exports "$s" REGISTRY_STORAGE_S3_ACCESSKEY=harbor-s3-access-key REGISTRY_STORAGE_S3_SECRETKEY=harbor-s3-secret-key
  done
fi
if [ "$metrics" = 1 ]; then
  exports exporter HARBOR_DATABASE_PASSWORD=harbor-exporter-db-password
  [ "$(env_ exporter HARBOR_DATABASE_USERNAME)" = "harbor_exporter" ] || bad "the exporter does not log in as its read-only role"
  [ "$(q '.services.exporter.secrets | join(" ")')" = "harbor-exporter-db-password" ] \
    || bad "the exporter mounts '$(q '.services.exporter.secrets | join(" ")')'; it must hold only its own role's password, never Harbor's"
fi
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
case "$case" in published|oidc|metrics|ha) db=harbor-e2e-db-net ;; esac
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
[ "$extredis" = 1 ] || [ "$(nets valkey)" = "internal" ] || bad "valkey is on '$(nets valkey)'; it has no password and must stay on internal alone"
[ "$(q '.networks.internal.external // false')" = "false" ] || bad "the internal overlay is external; it must be the stack's own"

# ── components dial each other by full service name ──────────────────────────────
# A short name is an alias on every external overlay too, where another stack's service of
# that name answers.
for s in $(q '.services | keys | .[]'); do
  short="$(q ".services.$s.environment // {} | to_entries | .[] | .value" | grep -E '://(core|portal|jobservice|registry|registryctl|valkey|trivy|exporter):' || true)"
  [ -z "$short" ] || bad "$s dials a short service name: $short"
done
[ "$(env_ core CORE_URL)" = "http://ci_core:8080" ] && [ "$(env_ jobservice CORE_URL)" = "http://ci_core:8080" ] \
  || bad "core/jobservice do not dial ci_core"
[ "$metrics" = 0 ] || [ "$(env_ exporter HARBOR_SERVICE_HOST)" = "ci_core" ] || bad "the exporter does not dial ci_core"
[ "$(env_ nginx HARBOR_CORE)/$(env_ nginx HARBOR_PORTAL)" = "ci_core/ci_portal" ] \
  && [ "$(q '.configs.nginx.template_driver')" = "golang" ] \
  || bad "nginx is not told ci_core / ci_portal through its templated config"
nginxconf="$(dirname "$0")/../files/nginx/nginx.conf"
grep -F 'server {{ env "HARBOR_CORE" }}:8080 resolve;' "$nginxconf" >/dev/null \
  && grep -F 'server {{ env "HARBOR_PORTAL" }}:8080 resolve;' "$nginxconf" >/dev/null \
  && grep -F 'resolver 127.0.0.11' "$nginxconf" >/dev/null \
  || bad "files/nginx/nginx.conf does not re-resolve HARBOR_CORE / HARBOR_PORTAL through Swarm's DNS; resolved once at start, nginx exits while core has no healthy task"
# A variable in proxy_pass forwards the raw request URI: a `#` then carries a path past
# `location /service/notifications` to core's unauthenticated job hooks.
if grep -E 'proxy_pass[[:space:]]+[^;]*\$' "$nginxconf" >/dev/null; then
  bad "files/nginx/nginx.conf has a variable in proxy_pass; keep upstream's static targets"
fi
# Every route goes through the two upstream blocks (a host name here would be resolved once,
# at start), and the job hooks stay unreachable from outside.
other="$(grep -E '^[[:space:]]*proxy_pass' "$nginxconf" | grep -v -E 'proxy_pass http://(core|portal)/[a-z0-9/]*;$' || true)"
[ -z "$other" ] || bad "files/nginx/nginx.conf proxies around the upstream blocks: $other"
tr '\n' ' ' <"$nginxconf" | grep -E 'location /service/notifications \{[[:space:]]*return 404;' >/dev/null \
  || bad "files/nginx/nginx.conf no longer answers /service/notifications with 404; core's job hooks there are unauthenticated"
for f in config.yml config-metrics.yml; do
  if grep -E 'redis_url:' "$(dirname "$0")/../files/jobservice/$f" >/dev/null; then bad "files/jobservice/$f names a redis_url; it comes from JOB_SERVICE_POOL_REDIS_URL"; fi
done
grep -F 'until curl -fsS -o /dev/null --max-time 5 "$$CORE_URL/api/v2.0/ping"' <<<"$(q '.services.jobservice.command[0]')" >/dev/null \
  || bad "jobservice does not wait for core; started first it exits, which pauses a rollout"

# ── exposure ──────────────────────────────────────────────────────────────────────────
labels="$(q '.services.nginx.deploy.labels // [] | .[]')"
ext="$(env_ core EXT_ENDPOINT)"
case "$case" in
  published|oidc|metrics|ha)
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
for s in registry registryctl; do
  [ "$(q ".services.$s.user")" = "0:0" ] || bad "$s does not start as root, so it cannot take ownership of the storage"
  grep -F "exec su -s /bin/sh harbor -c 'exec /home/harbor/" <<<"$(q ".services.$s.command[0]")" >/dev/null \
    || bad "$s does not hand over to uid 10000 through su"
done
if [ "$s3" = 1 ]; then
  [ "$(rc '.storage.s3.regionendpoint')/$(rc '.storage.s3.bucket')/$(rc '.storage.s3.rootdirectory')" = "$s3ep/harbor/$s3root" ] \
    || bad "s3: the registry's s3 driver is not endpoint/bucket/rootdirectory from the values"
  [ "$(rc '.storage.filesystem')" = "null" ] || bad "s3: a filesystem driver is configured too; the registry refuses two"
  [ "$(rc '.storage.redirect.disable')" = "true" ] || bad "s3: redirects are on; clients cannot reach an overlay endpoint"
  [ "$(env_ core REGISTRY_STORAGE_PROVIDER_NAME)" = "s3" ] || bad "s3: core is not told the storage provider is s3"
  for s in registry registryctl; do
    grep -E '^rd REGISTRY_STORAGE_S3_ACCESSKEY harbor-s3-access-key$' <<<"$(q ".services.$s.command[0]")" >/dev/null \
      || bad "s3: $s does not export the S3 access key from its secret"
    [ "$(q ".services.$s.volumes // [] | length")" = "0" ] || bad "s3: $s mounts a volume"
    [ "$(pins "$s")" = "" ] || bad "s3: $s is pinned to the data node, which holds no data of its"
    grep -F " $s3net" <<<" $(nets "$s")" >/dev/null || bad "s3: $s does not join storage.s3.network"
    if grep -F 'chown' <<<"$(q ".services.$s.command[0]")" >/dev/null; then bad "s3: $s still takes ownership of a /storage it does not use"; fi
  done
  [ "$extredis" = 1 ] || [ "$(pins valkey)" = "node.labels.harbor-data == true" ] || bad "s3: valkey lost its pin"
  [ "$(env_ core WITH_TRIVY)" = "$([ "$trivy" = 1 ] && echo true || echo false)" ] || bad "s3: core's WITH_TRIVY does not match whether Trivy runs"
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
  [ "$s" = valkey ] && [ "$extredis" = 1 ] && continue
  [ "$(q ".services.$s.deploy.update_config.order")" = "stop-first" ] || bad "$s does not stop the old task first"
done

# ── Redis: the internal valkey, or an external one through its Sentinels ───────────────
# Each component in its own database: 0 core, 1 the registry (core's _REDIS_URL_REG must
# match it, GC clears the registry's keys there), 2 jobservice and the exporter, 5 Trivy.
[ "$(env_ core _REDIS_URL_CORE)" = "$redisurl?idle_timeout_seconds=30" ] || bad "core's _REDIS_URL_CORE is '$(env_ core _REDIS_URL_CORE)'"
[ "$(env_ core _REDIS_URL_REG)" = "$redisurl/1?idle_timeout_seconds=30" ] || bad "core's _REDIS_URL_REG is '$(env_ core _REDIS_URL_REG)'"
[ "$(env_ jobservice JOB_SERVICE_POOL_REDIS_URL)" = "$redisurl/2?idle_timeout_seconds=30" ] || bad "jobservice's Redis URL is '$(env_ jobservice JOB_SERVICE_POOL_REDIS_URL)'"
if [ "$trivy" = 1 ]; then
  for v in SCANNER_REDIS_URL SCANNER_STORE_REDIS_URL SCANNER_JOB_QUEUE_REDIS_URL; do
    [ "$(env_ trivy "$v")" = "$redisurl/5?idle_timeout_seconds=30" ] || bad "trivy's $v is '$(env_ trivy "$v")'"
  done
fi
[ "$metrics" = 0 ] || [ "$(env_ exporter HARBOR_REDIS_URL)" = "$redisurl/2" ] || bad "the exporter's HARBOR_REDIS_URL is '$(env_ exporter HARBOR_REDIS_URL)'"
[ "$(rc '.redis.db')" = "1" ] || bad "the registry's cache is not database 1"
if [ "$extredis" = 0 ]; then
  [ "$(rc '.redis.addr')/$(rc '.redis.sentinelMasterSet')" = "ci_valkey:6379/null" ] || bad "the registry's cache is not ci_valkey"
  [ "$(q '.networks.redis-net // ""')" = "" ] || bad "internal Redis, but the redis overlay is declared"
else
  [ "$(rc '.redis.addr')/$(rc '.redis.sentinelMasterSet')" = "$sentinels/mymaster" ] \
    || bad "ha: the registry does not ask the Sentinels for master set mymaster: $(rc '.redis | tojson')"
  [ "$(rc '.redis.password')" = "null" ] || bad "ha: the registry configuration carries a Redis password"
  [ "$(q '.volumes // {} | length')" = "0" ] || bad "ha: volumes are declared, though nothing keeps data in the stack"
  [ "$(q '.networks.redis-net.external')" = "true" ] || bad "ha: redis-net is not declared external"
  # The password reaches each Redis client through its wrapper, from the secret, checked for
  # the characters a URL takes unencoded; and nothing else holds it.
  check='case "$$HARBOR_REDIS_PASSWORD" in *[!A-Za-z0-9._~-]*) echo "secret redis_password may hold only'
  splice() {  # $1 service, then the variables its wrapper must splice the password into
    local svc="$1" script; shift
    script="$(q ".services.$svc.command[0]")"
    exports "$svc" HARBOR_REDIS_PASSWORD=redis_password
    grep -F "$check" <<<"$script" >/dev/null || bad "ha: $svc does not refuse a Redis password a URL cannot take"
    for v in "$@"; do
      grep -Fx "export $v=\"\$\${$v/__HARBOR_REDIS_PASSWORD__/\$\$HARBOR_REDIS_PASSWORD}\"" <<<"$script" >/dev/null \
        || bad "ha: $svc does not splice the Redis password into $v"
    done
    grep -Fx 'unset HARBOR_REDIS_PASSWORD' <<<"$script" >/dev/null || bad "ha: $svc leaves HARBOR_REDIS_PASSWORD in its environment"
  }
  splice core _REDIS_URL_CORE _REDIS_URL_REG
  splice jobservice JOB_SERVICE_POOL_REDIS_URL
  splice trivy SCANNER_REDIS_URL SCANNER_STORE_REDIS_URL SCANNER_JOB_QUEUE_REDIS_URL
  [ "$(tail -n1 <<<"$(q '.services.trivy.command[0]')")" = "exec /home/scanner/entrypoint.sh" ] || bad "ha: trivy's wrapper does not exec the image's entrypoint"
  splice registry
  grep -Fx "export REGISTRY_REDIS_PASSWORD=\"'\$\$HARBOR_REDIS_PASSWORD'\"" <<<"$(q '.services.registry.command[0]')" >/dev/null \
    || bad "ha: the registry is not given the Redis password single-quoted (it parses REGISTRY_REDIS_PASSWORD as YAML)"
  if grep -F 'REDIS' <<<"$(q '.services.registryctl.command[0]')" >/dev/null; then bad "ha: registryctl's wrapper touches Redis; it uses none"; fi
  for s in $(q '.services | keys | .[]'); do
    case "$s" in
      core|jobservice|registry|trivy)
        grep -Fx -- '- redis_password' <<<"$(q ".services.$s.secrets")" >/dev/null || bad "ha: $s does not mount redis_password"
        grep -F ' redis-net ' <<<" $(nets "$s") " >/dev/null || bad "ha: $s does not join redis-net" ;;
      *)
        if grep -Fx -- '- redis_password' <<<"$(q ".services.$s.secrets // []")" >/dev/null; then bad "ha: $s mounts the Redis password; it uses no Redis"; fi
        if grep -F ' redis-net ' <<<" $(nets "$s") " >/dev/null; then bad "ha: $s joins redis-net; it uses no Redis"; fi ;;
    esac
  done
fi

# ── replicas: more than one is spread over the nodes ─────────────────────────────────
n=1; [ "$case" = "ha" ] && n=2
for s in nginx core portal jobservice registry registryctl; do
  [ "$(q ".services.$s.deploy.replicas")" = "$n" ] || bad "$s runs $(q ".services.$s.deploy.replicas") replicas, expected $n"
  spread="$(q ".services.$s.deploy.placement.preferences // [] | map(.spread) | join(\",\")")"
  if [ "$n" -gt 1 ]; then
    [ "$spread" = "node.id" ] || bad "$s runs $n replicas, but its placement preferences are '$spread', not a node.id spread"
  else
    [ -z "$spread" ] || bad "$s runs one replica, yet renders the placement preference '$spread'"
  fi
done
for s in valkey trivy exporter; do
  [ "$(q ".services.$s // \"\"")" = "" ] && continue
  [ "$(q ".services.$s.deploy.replicas")" = "1" ] || bad "$s does not run exactly one replica"
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
  refused 'config.oidc_client_secret is set by the chart from oidc.clientSecretSecret' --set config.oidc_client_secret=x
  refused 'config.oidc_admin_group is set by the chart from oidc.adminGroup' --set config.oidc_admin_group=x
  refused 'config.oidc_group_filter is set by the chart from oidc.groupFilter' --set 'config.oidc_group_filter=^x$'
  refused 'config.ldap_search_password is a credential' --set config.ldap_search_password=x
  # healthcheck.enabled=false disables the images' own checks rather than falling back to
  # them: core's has no start period and would kill a migration after about 90 seconds.
  if render --set healthcheck.enabled=false; then
    for s in nginx core portal jobservice registry registryctl valkey trivy; do
      [ "$(yq -r ".services.$s.healthcheck.disable" "$tmp")" = "true" ] || bad "healthcheck.enabled=false leaves $s on its image's healthcheck"
    done
  else
    bad "healthcheck.enabled=false was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  refused 'oidc.endpoint must be' --set oidc.enabled=true
  refused 'is not a Docker secret name' --set 'oidc.enabled=true' --set oidc.endpoint=https://kc.example.com/realms/r --set 'oidc.clientSecretSecret=x;id'
  refused 'is not a Docker secret name' --set 'secrets.core=a b'
  refused 'must name a different Swarm secret' --set secrets.jobservice=harbor-core-secret
  refused 'metrics.network must differ' --set metrics.enabled=true --set metrics.network=postgres-net
  refused 'metrics.network must differ' --set metrics.enabled=true --set metrics.network=traefik-public
  refused 'storage.s3.bucket' --set storage.type=s3 --set storage.s3.bucket=Bad_Bucket
  refused 'storage.s3.endpoint must be' --set storage.type=s3 --set storage.s3.endpoint=rustfs:9000
  refused 'persistence.registryVolume is a Docker named-volume name' --set persistence.registryVolume=a/b
  # Replicas: a filesystem volume is one node's, so the registry and registryctl stay at one.
  refused 'registry.replicas is 2, but storage.type=filesystem' --set registry.replicas=2
  refused 'registryctl.replicas is 3, but storage.type=filesystem' --set registryctl.replicas=3
  if render --set nginx.replicas=2 --set 'placement.constraints[0]=node.role==worker'; then
    [ "$(yq -r '.services.nginx.deploy.placement.constraints[0] + "/" + .services.nginx.deploy.placement.preferences[0].spread' "$tmp")" = "node.role==worker/node.id" ] \
      || bad "nginx.replicas=2 with a constraint does not render both the constraint and the node.id spread"
    [ "$(yq -r '.services.core.deploy.placement.preferences // "none"' "$tmp")" = "none" ] || bad "core.replicas=1 renders a spread preference"
  else
    bad "nginx.replicas=2 was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  # External Redis.
  redisext=(--set redis.type=external --set redis.external.addr=redis:6379)
  refused "'/redis/type': value must be one of 'internal', 'external'" --set redis.type=sentinel
  refused 'redis.external.addr must be host:port' --set redis.type=external
  # --set splits on an unescaped comma.
  refused 'redis.external.addr must be host:port' --set redis.type=external --set 'redis.external.addr=a:1\, b:2'
  refused 'which only Sentinels can be' --set redis.type=external --set 'redis.external.addr=a:1\,b:2'
  refused 'redis.external.sentinelMasterSet may hold only' "${redisext[@]}" --set 'redis.external.sentinelMasterSet=a b'
  refused 'must name a different Swarm secret' "${redisext[@]}" --set redis.external.passwordSecret=harbor-core-secret
  refused 'is not a Docker secret name' "${redisext[@]}" --set 'redis.external.passwordSecret=x;id'
  refused 'metrics.network must differ' "${redisext[@]}" --set metrics.enabled=true --set metrics.network=redis-net
  # A plain Redis without a password: no Sentinel scheme, nothing mounted, no Trivy wrapper.
  if render "${redisext[@]}" --set redis.external.passwordSecret=; then
    [ "$(yq -r .services.jobservice.environment.JOB_SERVICE_POOL_REDIS_URL "$tmp")" = "redis://redis:6379/2?idle_timeout_seconds=30" ] \
      || bad "external Redis without a password: jobservice dials '$(yq -r .services.jobservice.environment.JOB_SERVICE_POOL_REDIS_URL "$tmp")'"
    [ "$(yq -r '.services.registry.environment.HARBOR_REGISTRY_CONFIG' "$tmp" | yq -r '.redis.addr + "/" + (.redis.sentinelMasterSet // "none")')" = "redis:6379/none" ] \
      || bad "external Redis without Sentinel: the registry's redis config is wrong"
    [ "$(yq -r '.services.trivy.command // "none"' "$tmp")" = "none" ] || bad "external Redis without a password: trivy gets a wrapper"
    if grep -E 'HARBOR_REDIS_PASSWORD|harbor-redis-password' "$tmp" >/dev/null; then bad "external Redis without a password: the password is still read"; fi
    [ "$(yq -r '.services.valkey // "gone"' "$tmp")" = "gone" ] && [ "$(yq -r '.volumes | keys | join(",")' "$tmp")" = "harbor-registry" ] \
      || bad "external Redis: the valkey service or its volume is still rendered"
  else
    bad "external Redis without a password was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  # The exporter, with metrics, reads the job queue from the external Redis too.
  if render "${redisext[@]}" --set redis.external.sentinelMasterSet=m --set metrics.enabled=true; then
    x="$(yq -r '.services.exporter.command[0]' "$tmp")"
    [ "$(yq -r .services.exporter.environment.HARBOR_REDIS_URL "$tmp")" = "redis+sentinel://:__HARBOR_REDIS_PASSWORD__@redis:6379/m/2" ] \
      && grep -Fx 'rd HARBOR_REDIS_PASSWORD harbor-redis-password' <<<"$x" >/dev/null \
      && grep -Fx 'export HARBOR_REDIS_URL="$${HARBOR_REDIS_URL/__HARBOR_REDIS_PASSWORD__/$$HARBOR_REDIS_PASSWORD}"' <<<"$x" >/dev/null \
      && [ "$(yq -r '.services.exporter.networks | join(" ")' "$tmp")" = "internal postgres-net monitoring redis-net" ] \
      || bad "external Redis with metrics: the exporter does not reach it with the password spliced in"
  else
    bad "external Redis with metrics was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
fi

exit "$fail"
