#!/usr/bin/env bash
#
# Render-time assertions for the zammad chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# It asserts the properties a refactor could silently break and that `docker compose config`
# does not check:
#   1. no password ever lands in an `environment:` map — every credential is read from
#      /run/secrets in each role's command wrapper;
#   2. nginx dials the in-stack rails/websocket services it actually renders (a rename that left
#      ZAMMAD_RAILSSERVER_HOST pointing at a nonexistent service would 502 at runtime);
#   3. exposure.mode renders the right edge surface (traefik labels / a published port / neither);
#   4. elasticsearch.mode renders what it promises (embedded service / external overlay / disabled);
#   5. database.mode / redis.mode: embedded run the service in-stack and dial it, external consume
#      an EXTERNAL overlay and run no such service;
#   6. persistence toggles the volumes and the node pin together.
set -euo pipefail

out="$1"
case="${2:-}"

fail=0
note() { echo "   FAIL: $1"; fail=1; }

# Hard failure, never a skip (a skipped check is indistinguishable from a passing one).
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "   FAIL: mikefarah yq v4 is required by the zammad render checks but was not found" >&2
  exit 1
fi

has_svc() { [ "$(yq -r ".services | has(\"$1\")" "$out")" = "true" ]; }
net_external() { [ "$(yq -r ".networks.\"$1\".external // false" "$out")" = "true" ]; }

# 1. No password in any service's environment map. The only vars that carry a secret
#    (POSTGRESQL_PASS / REDIS_PASSWORD / ELASTICSEARCH_PASS) must appear ONLY inside command
#    wrappers as `$(cat /run/secrets/...)`, never as an environment key.
if yq -r '.services[].environment | keys | .[]' "$out" 2>/dev/null \
     | grep -Eq '^(POSTGRESQL_PASS|REDIS_PASSWORD|ELASTICSEARCH_PASS)$'; then
  note "a password variable is set in an environment: map (it must be read from /run/secrets in the command wrapper)"
fi
# The DB password wrapper is on every Zammad role.
yq -r '.services.railsserver.command[0]' "$out" | grep -q 'cat /run/secrets/' \
  || note "railsserver command does not read the DB password from a mounted secret"

# 2. Every Zammad role exists, and nginx dials the rendered rails/websocket services.
for svc in init railsserver websocket scheduler nginx; do
  has_svc "$svc" || note "missing Zammad role: $svc"
done
rails_host="$(yq -r '.services.nginx.environment.ZAMMAD_RAILSSERVER_HOST' "$out")"
ws_host="$(yq -r '.services.nginx.environment.ZAMMAD_WEBSOCKET_HOST' "$out")"
has_svc "$rails_host" || note "nginx ZAMMAD_RAILSSERVER_HOST=$rails_host is not a rendered service"
has_svc "$ws_host"    || note "nginx ZAMMAD_WEBSOCKET_HOST=$ws_host is not a rendered service"

# 3. exposure.mode.
labels="$(yq -r '.services.nginx.deploy.labels // [] | .[]' "$out")"
ports="$(yq -r '.services.nginx.ports // [] | length' "$out")"
case "$case" in
  published|embedded-backing|ephemeral|bind-mount)
    grep -q 'traefik.enable=true' <<<"$labels" && note "published mode rendered Traefik labels"
    [ "$ports" -ge 1 ] || note "published mode rendered no published port on nginx"
    ;;
  none)
    grep -q 'traefik.enable=true' <<<"$labels" && note "none mode rendered Traefik labels"
    [ "$ports" = "0" ] || note "none mode published a port (it must not)"
    ;;
  *)  # traefik (the default for every other fixture)
    grep -q 'traefik.enable=true' <<<"$labels" || note "traefik mode did not render traefik.enable"
    grep -q 'traefik.constraint-label=' <<<"$labels" || note "traefik mode did not render the constraint-label (swarm provider would never discover nginx)"
    [ "$ports" = "0" ] || note "traefik mode published a port directly (it must route through the edge)"
    ;;
esac

# 4. elasticsearch.mode.
es_enabled="$(yq -r '.services.init.environment.ELASTICSEARCH_ENABLED' "$out")"
case "$case" in
  es-disabled)
    [ "$es_enabled" = "false" ] || note "es-disabled did not set ELASTICSEARCH_ENABLED=false"
    has_svc elasticsearch && note "es-disabled rendered an elasticsearch service"
    ;;
  es-external)
    [ "$es_enabled" = "true" ] || note "es-external did not enable Elasticsearch"
    has_svc elasticsearch && note "es-external rendered an in-stack elasticsearch service (must consume the external cluster)"
    net_external elasticsearch-net || note "es-external must consume an EXTERNAL elasticsearch overlay"
    [ "$(yq -r '.secrets | has("zammad_elasticsearch_password")' "$out")" = "true" ] \
      || note "es-external + auth did not declare the ES password secret"
    ;;
  *)  # embedded everywhere else
    [ "$es_enabled" = "true" ] || note "embedded ES not enabled"
    has_svc elasticsearch || note "embedded ES rendered no elasticsearch service"
    [ "$(yq -r '.services.init.environment.ELASTICSEARCH_HOST' "$out")" = "elasticsearch" ] \
      || note "embedded ES: init does not dial the in-stack elasticsearch service"
    ;;
esac

# 5. database.mode / redis.mode. embedded => service present + dialled in-stack; external => no
#    such service + an EXTERNAL overlay consumed.
case "$case" in
  embedded-backing|ephemeral|bind-mount)
    has_svc postgres || note "embedded DB rendered no postgres service"
    [ "$(yq -r '.services.init.environment.POSTGRESQL_HOST' "$out")" = "postgres" ] \
      || note "embedded DB: init does not dial the in-stack postgres service"
    net_external postgres-net && note "embedded DB rendered postgres-net external (it must be chart-internal)"
    has_svc redis || note "embedded Redis rendered no redis service"
    # REDIS_URL is in the environment (no auth) or built in the command wrapper (auth on, so it
    # carries the password read from the secret) — either way it must dial the in-stack `redis`.
    redis_ref="$(yq -r '(.services.init.environment.REDIS_URL // ""), (.services.init.command[0] // "")' "$out")"
    grep -qE 'redis://(:[^@]*@)?redis:6379' <<<"$redis_ref" \
      || note "embedded Redis: init does not dial the in-stack redis service"
    ;;
  *)
    has_svc postgres && note "external DB rendered an in-stack postgres service"
    net_external postgres-net || note "external DB must consume an EXTERNAL postgres overlay"
    has_svc redis && note "external Redis rendered an in-stack redis service"
    net_external redis-net || note "external Redis must consume an EXTERNAL redis overlay"
    ;;
esac

# 6. persistence: the volume and the data pin travel together.
pin="$(yq -r '[.services.railsserver.deploy.placement.constraints // [] | .[] | select(test("node.labels"))] | length' "$out")"
vols="$(yq -r '.services.railsserver.volumes // [] | length' "$out")"
case "$case" in
  ephemeral)
    [ "$pin" = "0" ] || note "ephemeral (persistence off) still rendered a node pin"
    [ "$vols" = "0" ] || note "ephemeral (persistence off) still mounted a storage volume"
    [ "$(yq -r '.volumes // {} | length' "$out")" = "0" ] || note "ephemeral rendered top-level named volumes"
    ;;
  no-nodepin)
    [ "$pin" = "0" ] || note "no-nodepin (nodeLabel: \"\") still rendered a node.labels pin"
    [ "$vols" -ge 1 ] || note "no-nodepin dropped the storage volume (only the pin should go)"
    ;;
  *)
    [ "$pin" = "1" ] || note "expected exactly one node.labels data pin on railsserver, got $pin"
    [ "$vols" -ge 1 ] || note "railsserver mounts no storage volume"
    ;;
esac

# bind-mount: at least one absolute host path is mounted (this is what the host-mount ack covers).
if [ "$case" = "bind-mount" ]; then
  yq -r '.services[].volumes // [] | .[]' "$out" | grep -Eq '^/[^:]+:' \
    || note "bind-mount fixture rendered no host-path mount"
fi

# backup: the service is rendered and runs as root to read every file.
if [ "$case" = "backup" ]; then
  has_svc backup || note "backup fixture rendered no backup service"
  [ "$(yq -r '.services.backup.user' "$out")" = "0:0" ] || note "backup service is not user 0:0"
fi

# extra-networks: the app tier joins EVERY EXTERNAL overlay listed in extraNetworks (reachability for
# co-located, unexposed services). Each must render external:true and railsserver must attach to ALL
# of them — a regression here would silently cut Zammad off from one of its backends.
if [ "$case" = "extra-networks" ]; then
  rails_nets="$(yq -r '.services.railsserver.networks // [] | .[]' "$out")"
  for n in eldara-ollama_ai-internal mail_internal; do
    net_external "$n" || note "extra-networks: $n did not render as an EXTERNAL overlay"
    grep -qx "$n" <<<"$rails_nets" \
      || note "extra-networks: railsserver did not join $n (cannot reach that backend)"
  done
fi

exit "$fail"
