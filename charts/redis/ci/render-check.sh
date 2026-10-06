#!/usr/bin/env bash
#
# Render assertions for the redis chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# It guards the metrics option (#234), whose mistakes all converge to a healthy stack:
#
#   * Metrics must be opt-in: with them off, nothing about redis may change.
#   * Redis must never join the metrics overlay: everything on it could reach port 6379.
#   * The exporter carries exactly the two discovery labels: every deploy label of an
#     opted-in service is readable through Prometheus's targets API.
#   * With auth on, the exporter logs in as an ACL user that can read server state and
#     nothing else. A wider grant (a key pattern, CONFIG — which returns requirepass —,
#     SLOWLOG GET, a category) works just as well, so only this check would notice.
#   * /scrape?target= is disabled: it would dial any address and send it the
#     exporter's credentials.
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

rcmd="$(q '.services.redis.command[2]')"
[ -n "$rcmd" ] && [ "$rcmd" != "null" ] || bad "redis has no start-up script — every check below would pass vacuously"
services="$(q '.services | keys | .[]' | tr '\n' ' ')"

case "$case" in
  metrics|metrics-no-auth) ;;
  *)
    [ "$services" = "redis " ] || bad "case $case: services are '$services'; metrics must be opt-in"
    [ "$(q '.networks.monitoring')" = "null" ] || bad "case $case: the monitoring overlay is declared although metrics are off"
    if grep -F -- '--user ' <<<"$rcmd" >/dev/null; then bad "case $case: an ACL user is defined although metrics are off"; fi
    if q '.services.redis.deploy.labels // [] | .[]' | grep -F prometheus.io >/dev/null; then
      bad "case $case: redis carries discovery labels"
    fi
    exit "$fail"
    ;;
esac

e='.services."redis-exporter"'
[ "$services" = "redis redis-exporter " ] || bad "services are '$services', expected redis and redis-exporter"

# ── redis stays where it was ──────────────────────────────────────────────────────────
rnets="$(q '.services.redis.networks[]' | tr '\n' ' ')"
[ "$rnets" = "redis-net " ] || bad "redis networks are '$rnets'; it must not join the metrics overlay"
[ "$(q '.networks.monitoring.external')" = "true" ] || bad "the monitoring overlay is not declared external"

# ── the exporter ──────────────────────────────────────────────────────────────────────
lbls="$(q "$e.deploy.labels // [] | sort | join(\",\")")"
[ "$lbls" = "prometheus.io/port=9121,prometheus.io/scrape=true" ] \
  || bad "exporter deploy labels are '$lbls', expected exactly the two discovery labels"
enets="$(q "$e.networks // [] | .[]" | sort | tr '\n' ' ')"
[ "$enets" = "monitoring redis-net " ] || bad "exporter networks are '$enets', expected redis-net and monitoring"
[ "$(q "$e.ports // [] | length")" = "0" ] || bad "the exporter publishes a port; /metrics has no authentication"
[ "$(yq -o=json -I=0 "$e.deploy.placement" "$rendered")" = "$(yq -o=json -I=0 '.services.redis.deploy.placement' "$rendered")" ] \
  || bad "exporter placement differs from redis's; the node label should be redis's node"
ecmd="$(q "$e.command[0]")"
grep -F -- '--redis.addr=redis://tasks.ci_redis:6379' <<<"$ecmd" >/dev/null \
  || bad "the exporter does not scrape tasks.<release>_redis:6379"
grep -F -- '--disable-scrape-endpoint' <<<"$ecmd" >/dev/null \
  || bad "/scrape is enabled: it would send the exporter's credentials to any target a caller names"
grep -F -- '--config-command=-' <<<"$ecmd" >/dev/null \
  || bad "the exporter runs CONFIG GET, which its ACL user may not (and must not) run"
if grep -E -- '--redis\.password(=| )|REDIS_PASSWORD=[^"]' <<<"$ecmd" >/dev/null || [ "$(q "$e.environment")" != "null" ]; then
  bad "a password is passed inline or via environment:, where it lands in the manifest and docker inspect"
fi

if [ "$case" = "metrics-no-auth" ]; then
  [ "$(q "$e.secrets")" = "null" ] || bad "case $case: the exporter mounts a secret although auth is off"
  if grep -E 'REDIS_PASSWORD|--redis\.user' <<<"$ecmd" >/dev/null; then bad "case $case: the exporter logs in although auth is off"; fi
  if grep -F -- '--user ' <<<"$rcmd" >/dev/null; then bad "case $case: an ACL user is defined although auth is off"; fi
  [ "$(q '.secrets')" = "null" ] || bad "case $case: a secret is declared although auth is off"
  exit "$fail"
fi

# ── auth on: the exporter's ACL user ──────────────────────────────────────────────────
[ "$(q "$e.secrets | join(\" \")")" = "redis_exporter_password" ] || bad "the exporter does not mount exactly its own secret"
grep -F 'export REDIS_PASSWORD="$$(cat /run/secrets/redis_exporter_password)";' <<<"$ecmd" >/dev/null \
  || bad "the exporter does not read its password from the mounted secret"
grep -F -- '--redis.user=exporter' <<<"$ecmd" >/dev/null || bad "the exporter does not log in as the exporter user"
[ "$(q '.services.redis.secrets | join(" ")')" = "redis_password redis_exporter_password" ] \
  || bad "redis does not mount the exporter secret it hashes"
[ "$(q '.secrets.redis_exporter_password.external')" = "true" ] || bad "redis_exporter_password is not external"

grep -F "h=\"\$\$(printf '%s' \"\$\$(cat /run/secrets/redis_exporter_password)\" | sha256sum | cut -d' ' -f1)\";" <<<"$rcmd" >/dev/null \
  || bad "the ACL password hash is not computed from the mounted secret as the exporter reads it"
grep -F 'test -s /run/secrets/redis_exporter_password ||' <<<"$rcmd" >/dev/null \
  || bad "an empty exporter secret does not stop the start"
# The user, its hashed password and the exact grant, in order: `on`, `#<hash>` quoted so
# the shell does not read it as a comment, everything revoked, then server-state reads.
want="--user 'exporter' on \"#\$\$h\" -@all '+client|setname' '+info' '+latency|latest' '+latency|histogram' '+slowlog|len' '+command|info'"
user_part="$(sed -n "s/.*\(--user .*\)$/\1/p" <<<"$rcmd")"
[ "$user_part" = "$want" ] || bad "the exporter's ACL user is not exactly: $want (got: ${user_part:-<none>})"
# The --user directive must come after `exec … redis-server`, i.e. be a redis-server argument.
grep -E 'exec docker-entrypoint\.sh redis-server .* --user ' <<<"$rcmd" >/dev/null \
  || bad "--user is not passed to redis-server"

exit "$fail"
