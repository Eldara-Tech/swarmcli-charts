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
#     the slow log and nothing else. A wider grant (a key pattern, CONFIG — which returns
#     requirepass —, a category) works just as well, so only this check would notice; an
#     empty-after-trim secret must stop the start, not become an empty password.
#   * The guards refuse what they promise to (rendered below with $SWARMCLI).
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

# ── sentinel mode ─────────────────────────────────────────────────────────────────────
# Every mistake here still converges: peers sharing a volume or a node label, a peer
# announcing another's alias, Sentinels monitoring different first masters, a Sentinel's
# default user allowed to repoint its clients. So each peer and Sentinel is checked against
# its own number, and the refusals are rendered.
case "$case" in
sentinel*)
  peers=3; members=3
  [ "$case" = sentinel-two-peers ] && peers=2
  persistent=yes; metrics=no
  case "$case" in sentinel-ephemeral|sentinel-metrics) persistent=no ;; esac
  [ "$case" = sentinel-metrics ] && metrics=yes
  want=""
  for n in $(seq 1 "$peers"); do want="$want redis-$n"; [ "$metrics" = yes ] && want="$want redis-exporter-$n"; done
  for n in $(seq 1 "$members"); do want="$want sentinel-$n"; done
  want="$(tr ' ' '\n' <<<"$want" | sed '/^$/d' | sort | tr '\n' ' ')"
  got="$(q '.services | keys | .[]' | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || bad "services are '$got', expected '$want'"
  sentinels="ci-sentinel-1 ci-sentinel-2 ci-sentinel-3"
  acl='user default on nopass resetchannels &+switch-master &+replica-reconf-done -@all +ping +client|setname +client|setinfo +subscribe +unsubscribe +sentinel|get-master-addr-by-name +sentinel|sentinels +sentinel|replicas +sentinel|master'

  # $1 = service, $2 = N, $3 = alias, $4 = volume
  common() {
    local s=".services.\"$1\""
    [ "$(q "$s.deploy.replicas")" = 1 ] || bad "$1: replicas is not 1"
    [ "$(q "$s.deploy.endpoint_mode")" = vip ] || bad "$1: endpoint_mode is not vip (dnsrr drops the alias)"
    [ "$(q "$s.networks | keys | join(\" \")")" = redis-net ] || bad "$1: networks are not exactly redis-net"
    [ "$(q "$s.networks.\"redis-net\".aliases | join(\" \")")" = "$3" ] || bad "$1: aliases are not exactly $3"
    [ "$(q "$s.deploy.labels | join(\" \")")" = com.swarmcli.rollout=sequential ] || bad "$1: deploy labels are not exactly the sequential rollout"
    [ "$(q "$s.ports // [] | length")" = 0 ] || bad "$1 publishes a port"
    [ "$(q "$s.secrets | join(\" \")")" = "redis_password$([ "$metrics" = yes ] && [ "${1%%-*}" = redis ] && echo ' redis_exporter_password')" ] \
      || bad "$1: secrets are $(q "$s.secrets | join(\" \")")"
    if [ "$persistent" = yes ]; then
      [ "$(q "$s.volumes | join(\" \")")" = "$4:/data" ] || bad "$1: volumes are not exactly $4:/data"
      [ "$(q "$s.deploy.placement.constraints | join(\",\")")" = "node.labels.redis-data-$2 == true" ] || bad "$1: not pinned by exactly node label redis-data-$2"
    else
      [ "$(q "$s.volumes")" = null ] || bad "$1 mounts a volume although persistence is off"
      [ "$(q "$s.deploy.placement")" = null ] || bad "$1 is pinned although persistence is off"
    fi
  }

  for n in $(seq 1 "$peers"); do
    common "redis-$n" "$n" "ci-redis-$n" "redis-data-$n"
    cmd="$(q ".services.\"redis-$n\".command[2]")"
    for want in "me=ci-redis-$n" "ss=\"$sentinels\"" \
        'sentinel get-master-addr-by-name mymaster' '[ "$$m" != "$$me" ] && break' '[ -n "$$(ls -A /data)" ] && break' \
        'sentinel replicas mymaster' '[ "$$r" -eq 0 ] && break' '[ "$$m" = "$$me" ] || role="--replicaof $$m 6379"' \
        '--requirepass "$$(cat /run/secrets/redis_password)"' \
        '--masterauth "$$(cat /run/secrets/redis_password)" --replica-announce-ip "$$me" $$role'; do
      grep -F -- "$want" <<<"$cmd" >/dev/null || bad "redis-$n's start does not contain: $want"
    done
    if [ "$metrics" = yes ]; then
      e=".services.\"redis-exporter-$n\""
      grep -F -- "--redis.addr=redis://tasks.ci_redis-$n:6379" <<<"$(q "$e.command[0]")" >/dev/null || bad "redis-exporter-$n does not scrape tasks.ci_redis-$n"
      grep -F -- "--user 'exporter' on" <<<"$cmd" >/dev/null || bad "redis-$n does not define the exporter's ACL user"
      [ "$(q "$e.deploy.labels | sort | join(\",\")")" = "prometheus.io/port=9121,prometheus.io/scrape=true" ] || bad "redis-exporter-$n carries more than the discovery labels"
      [ "$(q "$e.networks | sort | join(\" \")")" = "monitoring redis-net" ] || bad "redis-exporter-$n networks are not redis-net and monitoring"
    fi
  done

  for n in $(seq 1 "$members"); do
    common "sentinel-$n" "$n" "ci-sentinel-$n" "redis-data-sentinel-$n"
    cmd="$(q ".services.\"sentinel-$n\".command[2]")"
    others="$(tr ' ' '\n' <<<"$sentinels" | grep -vx "ci-sentinel-$n" | tr '\n' ' ' | sed 's/ $//')"
    for want in "me=ci-sentinel-$n" "ss=\"$others\"" 'echo "sentinel announce-ip $$me"' 'echo "sentinel announce-hostnames yes"' \
        'echo "sentinel myid $$(printf '"'%s'"' "$$me" | sha1sum | cut -c1-40)"' "echo \"$acl\"" 'echo "user admin on #$$h ~* &* +@all"' \
        'echo "sentinel monitor mymaster $${m:-ci-redis-1} 6379 2"' 'echo "sentinel auth-pass mymaster \"$$q\""' \
        'exec docker-entrypoint.sh redis-server "$$c" --sentinel'; do
      grep -F -- "$want" <<<"$cmd" >/dev/null || bad "sentinel-$n's start does not contain: $want"
    done
    # Hostnames resolve only once resolve-hostnames is on, so it must precede the monitor line.
    r="$(grep -n 'resolve-hostnames yes' <<<"$cmd" | cut -d: -f1 || true)"; m="$(grep -n 'sentinel monitor' <<<"$cmd" | cut -d: -f1 || true)"
    [ -n "$r" ] && [ -n "$m" ] && [ "$r" -lt "$m" ] || bad "sentinel-$n: resolve-hostnames does not precede the monitor line"
  done

  vols="$(q '.volumes // {} | keys | .[]' | sort | tr '\n' ' ')"
  if [ "$persistent" = yes ]; then
    want=""; for n in $(seq 1 "$peers"); do want="$want redis-data-$n"; done; for n in $(seq 1 "$members"); do want="$want redis-data-sentinel-$n"; done
    want="$(tr ' ' '\n' <<<"$want" | sed '/^$/d' | sort | tr '\n' ' ')"
    [ "$vols" = "$want" ] || bad "volumes are '$vols', expected '$want'"
  else
    [ -z "$vols" ] || bad "volumes '$vols' are declared although persistence is off"
  fi

  if [ "$case" = sentinel ]; then
    chart="$(cd "$(dirname "$0")/.." && pwd)"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    srefused() {
      local want="$1"; shift
      if "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" -f "$chart/ci/sentinel-values.yaml" "$@" >/dev/null 2>"$tmp/err"; then
        bad "rendered with $* — it must be refused"
      elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
        bad "$* failed, but not with \"$want\": $(tail -1 "$tmp/err")"
      fi
    }
    srefused "/mode" --set mode=cluster
    srefused "/cluster/peers" --set cluster.peers=1
    srefused "/cluster/peers" --set cluster.peers=6
    srefused "/sentinel/members" --set sentinel.members=4
    srefused "/sentinel/masterName" --set 'sentinel.masterName=a b'
    srefused "mode=sentinel requires auth.enabled" --set auth.enabled=false
    srefused "exposure.enabled is standalone only" --set exposure.enabled=true
    srefused "persistence.volumePath is standalone only" --set persistence.volumePath=/srv/redis
    out="$("$SWARMCLI" charts template r "$chart" -f "$chart/ci/sentinel-values.yaml" --set sentinel.members=5 --set cluster.peers=5 2>/dev/null)"
    grep -F 'echo "sentinel monitor mymaster $${m:-r-redis-1} 6379 3"' <<<"$out" >/dev/null || bad "five Sentinels do not use a quorum of 3"
  fi
  exit "$fail"
  ;;
esac

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
grep -F "p=\"\$\$(cat /run/secrets/redis_exporter_password)\"; [ -n \"\$\$(printf '%s' \"\$\$p\" | tr -d '[:space:]')\" ] || { echo 'redis_exporter_password secret is empty' >&2; exit 1; }; export REDIS_PASSWORD=\"\$\$p\";" <<<"$ecmd" >/dev/null \
  || bad "the exporter does not read its password from the mounted secret, refusing an empty one"
grep -F -- '--redis.user=exporter' <<<"$ecmd" >/dev/null || bad "the exporter does not log in as the exporter user"
[ "$(q '.services.redis.secrets | join(" ")')" = "redis_password redis_exporter_password" ] \
  || bad "redis does not mount the exporter secret it hashes"
[ "$(q '.secrets.redis_exporter_password.external')" = "true" ] || bad "redis_exporter_password is not external"

grep -F "e=\"\$\$(cat /run/secrets/redis_exporter_password)\"; [ -n \"\$\$(printf '%s' \"\$\$e\" | tr -d '[:space:]')\" ] || { echo 'redis_exporter_password secret is empty' >&2; exit 1; };" <<<"$rcmd" >/dev/null \
  || bad "an empty or whitespace-only exporter secret does not stop the start — it would become an empty ACL password"
grep -F "h=\"\$\$(printf '%s' \"\$\$e\" | sha256sum | cut -d' ' -f1)\";" <<<"$rcmd" >/dev/null \
  || bad "the ACL password hash is not computed from the mounted secret as the exporter reads it"
# The user, its hashed password and the exact grant, in order: `on`, `#<hash>` quoted so
# the shell does not read it as a comment, everything revoked, then server-state reads.
want="--user 'exporter' on \"#\$\$h\" -@all '+client|setname' '+info' '+latency|latest' '+latency|histogram' '+slowlog|len' '+slowlog|get' '+command|info'"
user_part="$(sed -n "s/.*\(--user .*\)$/\1/p" <<<"$rcmd")"
[ "$user_part" = "$want" ] || bad "the exporter's ACL user is not exactly: $want (got: ${user_part:-<none>})"
# The --user directive must come after `exec … redis-server`, i.e. be a redis-server argument.
grep -E 'exec docker-entrypoint\.sh redis-server .* --user ' <<<"$rcmd" >/dev/null \
  || bad "--user is not passed to redis-server"

# ── the refusals, rendered from this chart with SWARMCLI (test-charts.sh sets it) ─────
chart="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() { "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" -f "$chart/ci/metrics-values.yaml" "$@"; }
refused() {
  local want="$1"; shift
  if render "$@" >/dev/null 2>"$tmp/err"; then
    bad "rendered with $* — it must be refused"
  elif ! grep -F -- "$want" "$tmp/err" >/dev/null; then
    bad "$* failed, but not with \"$want\": $(tail -1 "$tmp/err")"
  fi
}
render >/dev/null 2>"$tmp/err" || bad "the metrics fixture itself does not render: $(tail -1 "$tmp/err")"
refused "/metrics/username" --set metrics.username=default
refused "/metrics/username" --set 'metrics.username=a b'
refused "metrics.secretName must differ from auth.secretName" --set metrics.secretName=redis_password
refused "metrics.network must differ from network.name" --set metrics.network=redis-net
refused "refuses to start with both command-line users and an aclfile" --set 'extraConfig[0]=--aclfile /etc/redis/users.acl'
refused "refuses to start with both command-line users and an aclfile" --set 'extraConfig[0]=--save 900 1 --aclfile=/x'
# Without auth there is no command-line user, so an ACL file is fine.
render --set auth.enabled=false --set 'extraConfig[0]=--aclfile /x' >/dev/null 2>"$tmp/err" \
  || bad "an aclfile with auth off is refused, but there is no command-line user to clash with: $(tail -1 "$tmp/err")"

exit "$fail"
