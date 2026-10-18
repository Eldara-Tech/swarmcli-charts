#!/usr/bin/env bash
#
# Render assertions for the rustfs chart in distributed mode. ci/render-check.sh hands every
# distributed-* case here:
#   $1 = the rendered stack file   $2 = the fixture case name, without the prefix
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# What it guards is mostly what a deploy cannot see: every one of these mistakes still
# converges to healthy tasks.
#
#   * The peers must be ONE cluster: every peer starts with the same volume list, names
#     itself in it by its own alias, and has its own volume, node pin and identity. Four
#     peers that each formed a store of their own report healthy too.
#   * A peer's healthcheck must answer without the other peers (/health/live), or no peer
#     ever enters DNS; the peers must keep endpoint_mode vip, which network aliases need, and
#     carry the sequential-rollout label, or an upgrade stops every peer at once.
#   * Everything ci/render-check.sh guards on the standalone service holds on every peer
#     here: the credentials reach RustFS as *_FILE paths and the wrapper refuses an empty or
#     default key; the console exists and is exposed only when asked for; no single `$`
#     reaches Docker; the OIDC client secret never reaches environment:; metrics go through
#     a collector of their own that no peer shares an overlay with.
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
case "$case" in multi-drive) peers=6; drives=2 ;; *) peers=4; drives=1 ;; esac
PEERS="$(seq 1 "$peers" | tr '\n' ' ')"
monitor=2m; [ "$case" = "lifecycle" ] && monitor=20s
p() { echo ".services.\"rustfs-$1\""; }
env_() { q "$(p "$1").environment.$2"; }

# ── the services: one per peer, plus the collector with metrics ───────────────────────
services="$(q '.services | keys | join(" ")')"
want_services="$(for n in $PEERS; do printf 'rustfs-%s ' "$n"; done)"
[ "$case" = "metrics" ] && want_services="${want_services}rustfs-distributed-metrics "
[ "$services " = "$(echo "$want_services" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ')" ] \
  || bad "services are '$services', expected $want_services"

# ── one cluster: the same volume list everywhere, each peer naming itself in it ───────
vols="$(env_ 1 RUSTFS_VOLUMES)"
want_vols="http://ci-rustfs-{1...$peers}:9000/data/rustfs0"
[ "$drives" -gt 1 ] && want_vols="http://ci-rustfs-{1...$peers}:9000/data/rustfs{0...$((drives - 1))}"
[ "$vols" = "$want_vols" ] || bad "RUSTFS_VOLUMES is '$vols', expected '$want_vols' (ellipsis form, every peer's alias, s3.port)"
idents=""
for n in $PEERS; do
  s="$(p "$n")"
  [ "$(env_ "$n" RUSTFS_VOLUMES)" = "$vols" ] || bad "peer $n starts with RUSTFS_VOLUMES '$(env_ "$n" RUSTFS_VOLUMES)', not peer 1's '$vols'"
  [ "$(env_ "$n" RUSTFS_LOCAL_ENDPOINT_HOST)" = "ci-rustfs-$n" ] \
    || bad "peer $n's RUSTFS_LOCAL_ENDPOINT_HOST is '$(env_ "$n" RUSTFS_LOCAL_ENDPOINT_HOST)', not its alias ci-rustfs-$n — it would resolve every peer before opening a port"
  [ "$(env_ "$n" RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE)" = "orchestrated" ] \
    || bad "peer $n's RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE is not orchestrated — RustFS refuses an explicit local host otherwise, and bounded mode exits while peers are slow"
  [ "$(q "$s.networks.\"rustfs-net\".aliases | join(\" \")")" = "ci-rustfs-$n ci-rustfs" ] \
    || bad "peer $n's aliases on rustfs-net are '$(q "$s.networks.\"rustfs-net\".aliases | join(\" \")")', expected 'ci-rustfs-$n ci-rustfs'"
  [ "$(q "$s.hostname")" = "null" ] || bad "peer $n sets a hostname: one equal to its alias makes the alias resolve to the task IP as well as the VIP"
  [ "$(q "$s.deploy.endpoint_mode")" = "vip" ] || bad "peer $n's endpoint_mode is not vip — dnsrr drops the network aliases the peers dial each other by"
  [ "$(q "$s.deploy.replicas")" = "1" ] || bad "peer $n's replicas is not 1: two servers would share its drives"
  [ "$(q "$s.deploy.update_config.order")" = "stop-first" ] \
    || bad "peer $n's update_config.order is not stop-first: old and new tasks would briefly share its drives"
  [ "$(q "$s.deploy.update_config.monitor")" = "$monitor" ] || bad "peer $n's update_config.monitor is not healthcheck.monitor ($monitor)"
  [ "$(q "$s.deploy.restart_policy.condition")" = "any" ] || bad "peer $n's restart_policy is not any"
  grep -Fx 'com.swarmcli.rollout=sequential' <<<"$(q "$s.deploy.labels[]")" >/dev/null \
    || bad "peer $n lacks com.swarmcli.rollout=sequential: an upgrade would stop every peer at once"
  [ "$(q "$s.healthcheck.test | join(\" \")")" = "CMD curl -fsS -o /dev/null http://127.0.0.1:9000/health/live" ] \
    || bad "peer $n's healthcheck does not probe /health/live (got: $(q "$s.healthcheck.test | join(\" \")")) — /health/ready needs peers that are not in DNS before their own check passes"
  idents="$idents $(env_ "$n" RUSTFS_LOCAL_ENDPOINT_HOST)"
done
[ "$(printf '%s\n' $idents | sort -u | wc -l | tr -d ' ')" = "$peers" ] || bad "the peers' identities are not distinct:$idents"

# ── the wrapper and its exec target, on every peer ────────────────────────────────────
for n in $PEERS; do
  s="$(p "$n")"
  script="$(q "$s.command[0]")"
  [ -n "$script" ] && [ "$script" != "null" ] || { bad "peer $n has no start-up script — every check below would pass vacuously"; continue; }
  [ "$(q "$s.entrypoint | join(\" \")")" = "/bin/sh -c" ] || bad "peer $n's entrypoint is not [/bin/sh, -c]; the start-up script would not run"
  [ "$(q "$s.command | length")" = "1" ] || bad "peer $n's command has more than the script; the extra words would become \$0 and \$@"
  grep -E 'exec /entrypoint.sh rustfs$' <<<"$script" >/dev/null \
    || bad "peer $n's wrapper does not end by exec'ing the image entrypoint — rustfs would not be PID 1, or would not start"
  grep -F 'for f in "$$RUSTFS_ACCESS_KEY_FILE" "$$RUSTFS_SECRET_KEY_FILE"; do' <<<"$script" >/dev/null \
    && grep -F 'if [ "$${w:-0}" != 1 ]; then echo' <<<"$script" >/dev/null \
    && grep -F 'if [ "$$(LC_ALL=C tr -cd '"'"'[:alnum:]'"'"' < "$$f")" = rustfsadmin ]; then echo' <<<"$script" >/dev/null \
    || bad "peer $n's wrapper does not refuse an empty key, one with whitespace inside it, or the public default rustfsadmin"
  if grep -E -- '(--user|-u) ' <<<"$script" >/dev/null; then
    bad "peer $n's wrapper passes credentials to curl as an argument; feed them through -K - instead"
  fi
  if grep -E '(^|[^$])\$[({A-Za-z@]' <<<"$script" >/dev/null; then
    bad "peer $n's start-up script has an unescaped \$ ($(grep -oE '(^|[^$])\$[({A-Za-z@][^ ]{0,20}' <<<"$script" | sed -n 1p)): Docker would interpolate it at deploy time"
  fi
  # Buckets: peer 1 creates them; the cluster gives every peer the same buckets.
  if [ "$n" != 1 ] && grep -F 'for b in' <<<"$script" >/dev/null; then bad "peer $n runs a bucket loop; only peer 1 does"; fi
done

# ── credentials, the same on every peer ───────────────────────────────────────────────
for n in $PEERS; do
  s="$(p "$n")"
  [ "$(q "$s.secrets[0]")" = "rustfs-access-key" ] && [ "$(q "$s.secrets[1]")" = "rustfs-secret-key" ] \
    || bad "peer $n does not mount the two credential secrets (got '$(q "$s.secrets[0]")' / '$(q "$s.secrets[1]")')"
  [ "$(env_ "$n" RUSTFS_ACCESS_KEY_FILE)" = "/run/secrets/rustfs-access-key" ] \
    || bad "peer $n's RUSTFS_ACCESS_KEY_FILE is not /run/secrets/rustfs-access-key — RustFS would fall back to rustfsadmin"
  [ "$(env_ "$n" RUSTFS_SECRET_KEY_FILE)" = "/run/secrets/rustfs-secret-key" ] || bad "peer $n's RUSTFS_SECRET_KEY_FILE is not /run/secrets/rustfs-secret-key"
  for v in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY RUSTFS_ROOT_USER RUSTFS_ROOT_PASSWORD \
           MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_ROOT_USER MINIO_ROOT_PASSWORD \
           MINIO_ACCESS_KEY_FILE MINIO_SECRET_KEY_FILE; do
    [ "$(env_ "$n" "$v")" = "null" ] || bad "peer $n sets $v in environment:, where it lands in the manifest and docker inspect"
  done
  if [ "$(q "$s.environment | keys | .[]" | grep -E 'IDENTITY_OPENID_CLIENT_SECRET' || true)" != "" ]; then
    bad "case $case: peer $n sets an OIDC client secret in environment:, where it lands in the manifest and docker inspect"
  fi
  [ "$(env_ "$n" RUSTFS_ADDRESS)" = ":9000" ] || bad "peer $n's RUSTFS_ADDRESS is not :9000"
  [ "$(env_ "$n" RUSTFS_OBS_LOG_DIRECTORY)" = "" ] || bad "peer $n's RUSTFS_OBS_LOG_DIRECTORY is not empty: its log would go to a file inside the container"
  [ "$(env_ "$n" RUSTFS_CHECK_UPDATE)" = "false" ] || bad "peer $n's RUSTFS_CHECK_UPDATE is not false"
  [ "$(q "$s.ulimits.nofile.soft")" = "65536" ] || bad "peer $n's nofile ulimit is not raised; RustFS disables its fd cache below 16384"
  [ "$(q "$s.stop_grace_period")" != "null" ] || bad "peer $n has no stop_grace_period"
done
for s in rustfs-access-key rustfs-secret-key; do
  [ "$(q ".secrets.\"$s\".external")" = "true" ] || bad "secret $s is not declared external: true"
done

# ── persistence and placement: one volume and one pin per peer, all distinct ──────────
mounts_all=""; pins_all=""
for n in $PEERS; do
  s="$(p "$n")"
  mounts="$(q "$s.volumes[]")"
  constraints="$(q "$s.deploy.placement.constraints[]")"
  case "$case" in
    ephemeral)
      [ "$(q "$s.volumes")" = "null" ] || bad "case $case: peer $n mounts a volume although persistence is off"
      [ "$(q "$s.deploy.placement")" = "null" ] || bad "case $case: peer $n has a placement block although persistence is off"
      ;;
    bind-mount)
      [ "$mounts" = "/tmp/rustfs-distributed-e2e/$n:/data/rustfs0" ] || bad "case $case: peer $n mounts '$mounts', expected its host path at /data/rustfs0"
      ;;
    multi-drive)
      [ "$mounts" = "$(printf '/mnt/disk1/rustfs:/data/rustfs0\n/mnt/disk2/rustfs:/data/rustfs1')" ] \
        || bad "case $case: peer $n mounts '$(echo $mounts)', expected its two host paths at /data/rustfs0 and /data/rustfs1"
      ;;
    *)
      [ "$mounts" = "rustfs-data-$n:/data" ] || bad "case $case: peer $n mounts '$mounts', expected its own named volume rustfs-data-$n at /data"
      [ "$(q ".volumes.\"rustfs-data-$n\"")" != "null" ] || bad "case $case: the named volume rustfs-data-$n is not declared at the top level"
      ;;
  esac
  case "$case" in
    ephemeral) ;;
    unpinned)
      [ "$(q "$s.deploy.placement")" = "null" ] || bad "case $case: peer $n is pinned although nodeLabelPrefix is empty"
      ;;
    *)
      grep -Fx "node.labels.rustfs-$n == true" <<<"$constraints" >/dev/null || bad "case $case: peer $n is not pinned by node.labels.rustfs-$n"
      ;;
  esac
  [ "$case" = "buckets" ] && { grep -Fx 'node.role == manager' <<<"$constraints" >/dev/null || bad "case $case: placement.constraints was not applied to peer $n"; }
  mounts_all="$mounts_all $mounts"; pins_all="$pins_all $(grep -F 'node.labels.' <<<"$constraints" || true)"
done
case "$case" in
  ephemeral) [ "$(q ".volumes")" = "null" ] || bad "case $case: a top-level volume is declared although persistence is off" ;;
  bind-mount|multi-drive) [ "$(q ".volumes")" = "null" ] || bad "case $case: a named volume is declared although volumePaths takes precedence" ;;
esac
# Distinct per peer: two peers on one volume, or pinned by one label, share their drives.
# multi-drive repeats its paths on purpose: every peer is on its own node there.
if [ "$case" != "multi-drive" ] && [ "$case" != "ephemeral" ]; then
  [ "$(printf '%s\n' $mounts_all | sort -u | wc -l | tr -d ' ')" = "$peers" ] || bad "case $case: the peers' volumes are not distinct:$mounts_all"
fi
case "$case" in ephemeral|unpinned) ;; *)
  [ "$(printf '%s\n' $pins_all | grep -c 'node.labels' | tr -d ' ')" = "$peers" ] \
    && [ "$(printf '%s\n' $pins_all | grep 'node.labels' | sort -u | wc -l | tr -d ' ')" = "$peers" ] \
    || bad "case $case: the peers' node pins are not one distinct label each:$pins_all"
esac

# ── networks ──────────────────────────────────────────────────────────────────────────
[ "$(q '.networks."rustfs-net".external')" = "true" ] || bad "rustfs-net is not external — it would be stack-scoped and unreachable by name from other stacks"
labels1="$(q "$(p 1).deploy.labels[]")"
nets="$(q "$(p 1).networks | keys | .[]")"

# ── the console: a second listener with the full API, only when asked for ─────────────
case "$case" in traefik|published|console-edge|oidc) console=1 ;; *) console="" ;; esac
for n in $PEERS; do
  if [ -n "$console" ]; then
    [ "$(env_ "$n" RUSTFS_CONSOLE_ENABLE)" = "true" ] && [ "$(env_ "$n" RUSTFS_CONSOLE_ADDRESS)" = ":9001" ] \
      || bad "case $case: console.enabled but peer $n's console is not on at :9001"
  else
    [ "$(env_ "$n" RUSTFS_CONSOLE_ENABLE)" = "false" ] \
      || bad "case $case: peer $n's RUSTFS_CONSOLE_ENABLE is not false — RustFS turns the console ON when it is unset"
    [ "$(env_ "$n" RUSTFS_CONSOLE_ADDRESS)" = "null" ] || bad "case $case: peer $n has a console address although the console is off"
  fi
done
if [ -z "$console" ] && grep -F 'console' <<<"$labels1" >/dev/null; then bad "case $case: a console router is rendered although the console is off"; fi

# ── exposure: the same on every peer ──────────────────────────────────────────────────
for n in $(seq 2 "$peers"); do
  [ "$(q "$(p "$n").deploy.labels | join(\" \")")" = "$(q "$(p 1).deploy.labels | join(\" \")")" ] \
    || bad "case $case: peer $n's deploy labels differ from peer 1's; Traefik would not merge their routers"
  [ "$(q "$(p "$n").ports")" = "$(q "$(p 1).ports")" ] || bad "case $case: peer $n's ports differ from peer 1's"
done
case "$case" in
  traefik|edge|console-edge|oidc)
    grep -Fx traefik-public <<<"$nets" >/dev/null || bad "case $case: not attached to traefik-public"
    for l in 'traefik.enable=true' 'traefik.swarm.network=traefik-public' 'traefik.constraint-label=traefik-public'; do
      grep -Fx "$l" <<<"$labels1" >/dev/null || bad "case $case: label $l is missing"
    done
    [ "$(q "$(p 1).ports")" = "null" ] || bad "case $case: a port is published in traefik mode"
    [ "$(env_ 1 RUSTFS_HTTP1_HEADER_READ_TIMEOUT)" = "120" ] \
      || bad "case $case: RustFS's idle timeout is not raised above Traefik's 90s upstream keep-alive"
    ;;
  published)
    for n in $PEERS; do
      [ "$(q "$(p "$n").ports | map(.target + \":\" + .published + \":\" + .mode) | join(\" \")")" = "9000:19000:host 9001:19001:host" ] \
        || bad "case $case: peer $n does not publish 19000 -> 9000 and 19001 -> 9001 in host mode (got: $(q "$(p "$n").ports | map(.target + \":\" + .published + \":\" + .mode) | join(\" \")"))"
    done
    ;;
  *)
    [ "$(q "$(p 1).ports")" = "null" ] || bad "case $case: a port is published although exposure.mode is none"
    if grep -F 'traefik.' <<<"$labels1" >/dev/null; then bad "case $case: Traefik labels rendered although exposure.mode is none"; fi
    [ "$nets" = "rustfs-net" ] || bad "case $case: attached to more than network.name: $(tr '\n' ' ' <<<"$nets")"
    [ "$(env_ 1 RUSTFS_HTTP1_HEADER_READ_TIMEOUT)" = "null" ] || bad "case $case: the idle timeout is raised outside traefik mode"
    ;;
esac
case "$case" in
  traefik|edge)
    for l in 'traefik.http.services.ci.loadbalancer.server.port=9000' 'traefik.http.routers.ci-http.service=ci'; do
      grep -Fx "$l" <<<"$labels1" >/dev/null || bad "case $case: label $l is missing"
    done
    ;;
  *)
    if grep -E '^traefik\.http\.(routers\.ci-https?|services\.ci)\.' <<<"$labels1" >/dev/null; then
      bad "case $case: an S3 router or service is rendered although exposure.mode does not route the S3 API"
    fi
    ;;
esac
case "$case" in
  traefik)
    for l in 'traefik.http.routers.ci-http.middlewares=https-redirect' 'traefik.http.routers.ci-https.rule=Host(`s3-cluster.example.com`)' \
             'traefik.http.routers.ci-https.tls.certresolver=le' 'traefik.http.routers.ci-https.service=ci' \
             'traefik.http.routers.ci-console-https.rule=Host(`rustfs-console.example.com`)' \
             'traefik.http.routers.ci-console-https.service=ci-console' 'traefik.http.routers.ci-console-http.middlewares=https-redirect' \
             'traefik.http.services.ci-console.loadbalancer.server.port=9001'; do
      grep -Fx "$l" <<<"$labels1" >/dev/null || bad "case $case: label $l is missing"
    done
    ;;
  edge)
    if grep -F 'https' <<<"$labels1" >/dev/null; then bad "case $case: tls is off but an https router or redirect is rendered"; fi
    grep -Fx 'traefik.http.routers.ci-http.rule=Host(`s3-cluster.e2e.test`)' <<<"$labels1" >/dev/null || bad "case $case: no HTTP router for ingress.host"
    ;;
  console-edge)
    if grep -F 'https' <<<"$labels1" >/dev/null; then bad "case $case: console.ingress.tls is off but an https router or redirect is rendered"; fi
    for l in 'traefik.http.routers.ci-console-http.rule=Host(`rustfs-cluster-console.e2e.test`)' \
             'traefik.http.routers.ci-console-http.service=ci-console' 'traefik.http.services.ci-console.loadbalancer.server.port=9001'; do
      grep -Fx "$l" <<<"$labels1" >/dev/null || bad "case $case: console label $l is missing"
    done
    ;;
esac
# A routed console keeps a browser on one peer: each peer holds a sign-in's state in memory.
case "$case" in
  traefik|console-edge|oidc)
    for l in 'traefik.http.services.ci-console.loadbalancer.sticky.cookie=true' 'traefik.http.services.ci-console.loadbalancer.sticky.cookie.httponly=true'; do
      grep -Fx "$l" <<<"$labels1" >/dev/null || bad "case $case: the routed console lacks $l; a single sign-on's callback could reach another peer"
    done
    ;;
  *)
    if grep -F 'sticky' <<<"$labels1" >/dev/null; then bad "case $case: a sticky cookie is rendered although the console is not routed"; fi
    ;;
esac

# ── single sign-on: the client secret only through the wrapper, on every peer ────────
for n in $PEERS; do
  script="$(q "$(p "$n").command[0]")"
  if [ "$case" = "oidc" ]; then
    [ "$(env_ "$n" RUSTFS_IDENTITY_OPENID_CONFIG_URL)" = "http://rustfs-e2e-idp:8080/realms/e2e/.well-known/openid-configuration" ] \
      && [ "$(env_ "$n" RUSTFS_IDENTITY_OPENID_CLIENT_ID)" = "rustfs-e2e" ] \
      && [ "$(env_ "$n" RUSTFS_IDENTITY_OPENID_DISPLAY_NAME)" = "SSO" ] \
      && [ "$(env_ "$n" RUSTFS_BROWSER_REDIRECT_URL)" = "https://rustfs-cluster-console.e2e.test" ] \
      && [ "$(env_ "$n" RUSTFS_IDENTITY_OPENID_REDIRECT_URI_DYNAMIC)" = "off" ] \
      && [ "$(env_ "$n" RUSTFS_OUTBOUND_ALLOW_ORIGINS)" = "http://rustfs-e2e-idp:8080" ] \
      || bad "case $case: peer $n's OIDC settings are not console.oidc.* (config URL, client id, label, callback base, no dynamic redirect, the provider's origin allow-listed)"
    [ "$(q "$(p "$n").secrets[2]")" = "rustfs-oidc-client-secret" ] || bad "case $case: peer $n does not mount the OIDC client secret"
    grep -F 'done; f=/run/secrets/rustfs-oidc-client-secret; RUSTFS_IDENTITY_OPENID_CLIENT_SECRET="$$(cat "$$f" 2>/dev/null || true)"; if [ -z "$$RUSTFS_IDENTITY_OPENID_CLIENT_SECRET" ]; then echo' <<<"$script" >/dev/null \
      && grep -F 'export RUSTFS_IDENTITY_OPENID_CLIENT_SECRET;' <<<"$script" >/dev/null \
      || bad "case $case: peer $n's wrapper does not export the client secret from /run/secrets/rustfs-oidc-client-secret, refusing an empty one"
  else
    for v in RUSTFS_IDENTITY_OPENID_CONFIG_URL RUSTFS_IDENTITY_OPENID_CLIENT_ID RUSTFS_IDENTITY_OPENID_REDIRECT_URI_DYNAMIC \
             RUSTFS_IDENTITY_OPENID_DISPLAY_NAME RUSTFS_BROWSER_REDIRECT_URL RUSTFS_OUTBOUND_ALLOW_ORIGINS; do
      [ "$(env_ "$n" "$v")" = "null" ] || bad "case $case: peer $n sets $v although oidc is off"
    done
    [ "$(q "$(p "$n").secrets | length")" = "2" ] || bad "case $case: peer $n mounts a third secret although oidc is off"
    if grep -F 'CLIENT_SECRET' <<<"$script" >/dev/null; then bad "case $case: peer $n's wrapper reads an OIDC client secret although oidc is off"; fi
  fi
done
[ "$case" = "oidc" ] && { [ "$(q '.secrets."rustfs-oidc-client-secret".external')" = "true" ] || bad "case $case: the OIDC client secret is not declared external"; }

# ── buckets: peer 1's bootstrap ───────────────────────────────────────────────────────
case "$case" in
  buckets) want='runner-cache e2e.second-bucket' ;;
  traefik|edge) want='runner-cache' ;;
  ephemeral) want='scratch' ;;
  lifecycle) want='lifecycle' ;;
  *) want='' ;;
esac
script="$(q "$(p 1).command[0]")"
if [ -n "$want" ]; then
  grep -F "for b in $want; do" <<<"$script" >/dev/null || bad "case $case: peer 1's bootstrap loop does not iterate exactly '$want'"
  grep -F '"http://127.0.0.1:9000/$$b"' <<<"$script" >/dev/null || bad "case $case: buckets are not created against the S3 port 9000"
  grep -F '| curl -K - ' <<<"$script" >/dev/null && grep -F -- '--aws-sigv4' <<<"$script" >/dev/null \
    || bad "case $case: bucket creation is not signed with the key pair read from a config on stdin"
  grep -F '[ "$$code" = 200 ] || [ "$$code" = 409 ]' <<<"$script" >/dev/null || bad "case $case: 200 and 409 are not both treated as done"
  grep -F ') & exec /entrypoint.sh' <<<"$script" >/dev/null || bad "case $case: the bootstrap loop does not run in the background — it would block the server it waits for"
else
  if grep -F 'for b in' <<<"$script" >/dev/null; then bad "case $case: a bucket loop is rendered with no buckets"; fi
fi

# ── metrics: a collector every peer pushes to, the only service on the metrics overlay ─
m='.services."rustfs-distributed-metrics"'
obs="RUSTFS_OBS_ENDPOINT RUSTFS_OBS_TRACES_EXPORT_ENABLED RUSTFS_OBS_LOGS_EXPORT_ENABLED RUSTFS_OBS_LOG_STDOUT_ENABLED"
if [ "$case" != "metrics" ]; then
  [ "$(q '.networks.monitoring')" = "null" ] || bad "case $case: the monitoring overlay is declared although metrics are off"
  for v in $obs; do [ "$(env_ 1 "$v")" = "null" ] || bad "case $case: $v is set although metrics are off"; done
else
  for n in $PEERS; do
    if grep -Fx monitoring <<<"$(q "$(p "$n").networks | keys | .[]")" >/dev/null; then bad "peer $n joins the monitoring overlay; everything on it could reach the S3 port"; fi
    [ "$(env_ "$n" RUSTFS_OBS_ENDPOINT)" = "http://ci-rustfs-metrics:4318" ] \
      && [ "$(env_ "$n" RUSTFS_OBS_TRACES_EXPORT_ENABLED)" = "false" ] && [ "$(env_ "$n" RUSTFS_OBS_LOGS_EXPORT_ENABLED)" = "false" ] \
      && [ "$(env_ "$n" RUSTFS_OBS_LOG_STDOUT_ENABLED)" = "true" ] \
      || bad "peer $n does not push only metrics to the collector's alias on rustfs-net with its log kept on stdout"
  done
  [ "$(q '.networks.monitoring.external')" = "true" ] || bad "the monitoring overlay is not declared external"
  [ "$(q "$m.image")" = "otel/opentelemetry-collector:$(yq -r '.metrics.image.tag' "$(dirname "$0")/../values.yaml")" ] \
    || bad "the collector image is not values.yaml's metrics.image (got '$(q "$m.image")')"
  [ "$(q "$m.command | join(\" \")")" = "--config=env:COLLECTOR_CONFIG" ] || bad "the collector does not read its config from COLLECTOR_CONFIG"
  cfg="$(q "$m.environment.COLLECTOR_CONFIG")"
  [ "$(yq -r '.receivers.otlp.protocols.http.endpoint' <<<"$cfg")" = "0.0.0.0:4318" ] \
    && [ "$(yq -r '.receivers.otlp.protocols | keys | join(" ")' <<<"$cfg")" = "http" ] \
    && [ "$(yq -r '.exporters.prometheus.endpoint' <<<"$cfg")" = "0.0.0.0:8889" ] \
    && [ "$(yq -r '.service.pipelines | keys | join(" ")' <<<"$cfg")" = "metrics" ] \
    && [ "$(yq -r '.service.pipelines.metrics.processors[0]' <<<"$cfg")" = "memory_limiter" ] \
    && [ "$(yq -r '.processors.memory_limiter | [.check_interval, .limit_mib, .spike_limit_mib] | join(" ")' <<<"$cfg")" = "1s 200 50" ] \
    || bad "the collector's config is not one metrics pipeline, OTLP/HTTP on :4318 through a 200 MiB memory_limiter to Prometheus on :8889"
  [ "$(q "$m.deploy.resources.limits.memory")" = "256M" ] || bad "the collector's memory limit is not 256M"
  [ "$(q "$m.deploy.labels | join(\" \")")" = "prometheus.io/scrape=true prometheus.io/port=8889" ] \
    || bad "collector deploy labels are '$(q "$m.deploy.labels | join(\" \")")', expected exactly the two discovery labels"
  [ "$(q "$m.networks | keys | join(\" \")")" = "monitoring rustfs-net" ] || bad "the collector is not on exactly rustfs-net and monitoring"
  [ "$(q "$m.networks.\"rustfs-net\".aliases | join(\" \")")" = "ci-rustfs-metrics" ] || bad "the collector's alias on rustfs-net is not ci-rustfs-metrics, the name the peers dial"
  [ "$(q "$m.ports // [] | length")" = "0" ] || bad "the collector publishes a port; neither of its listeners authenticates"
fi

# ── refusals and one-off renders (from the default fixture only) ────────────────────────
if [ "$case" = "default" ]; then
  chart="$(cd "$(dirname "$0")/.." && pwd)"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.err" "$tmp.values"' EXIT
  sc="${SWARMCLI:?render-check needs SWARMCLI to render the refusals}"
  render() { "$sc" charts template ci "$chart" --set mode=distributed "$@" >"$tmp" 2>"$tmp.err"; }
  refused() {
    local want="$1"; shift
    if render "$@"; then
      bad "rendered with $* — it must be refused"
    elif ! grep -F "$want" "$tmp.err" >/dev/null; then
      bad "$* failed, but not with \"$want\": $(tr '\n' ' ' <"$tmp.err")"
    fi
  }
  y() { yq -r "$1" "$tmp"; }

  kc=https://kc.example.com/realms/r/.well-known/openid-configuration
  kco=(--set console.enabled=true --set console.oidc.enabled=true --set "console.oidc.configUrl=$kc" --set console.oidc.browserUrl=https://c.example.com)

  # A release name with '_' and '.' gets aliases, and a volume list, without them.
  if "$sc" charts template my_s3.x "$chart" --set mode=distributed >"$tmp" 2>"$tmp.err"; then
    [ "$(y '.services."rustfs-2".networks."rustfs-net".aliases | join(" ")')" = "my-s3-x-rustfs-2 my-s3-x-rustfs" ] \
      && [ "$(y '.services."rustfs-2".environment.RUSTFS_VOLUMES')" = "http://my-s3-x-rustfs-{1...4}:9000/data/rustfs0" ] \
      && [ "$(y '.services."rustfs-2".environment.RUSTFS_LOCAL_ENDPOINT_HOST')" = "my-s3-x-rustfs-2" ] \
      || bad "release my_s3.x: the aliases, volume list or local host keep a '_' or '.'"
  else
    bad "release my_s3.x was refused: $(tr '\n' ' ' <"$tmp.err")"
  fi
  # Another port reaches the listener, the volume list and the probe alike.
  render --set s3.port=9100 && [ "$(y '.services."rustfs-3".environment.RUSTFS_VOLUMES')" = "http://ci-rustfs-{1...4}:9100/data/rustfs0" ] \
    && [ "$(y '.services."rustfs-3".environment.RUSTFS_ADDRESS')" = ":9100" ] \
    && [ "$(y '.services."rustfs-3".healthcheck.test[5]')" = "http://127.0.0.1:9100/health/live" ] \
    || bad "s3.port=9100 does not reach RUSTFS_ADDRESS, RUSTFS_VOLUMES and the healthcheck together"

  # The cluster's shape. Valid ones render with the set width RustFS will pick; the rest fail.
  for shape in "5 1" "6 1" "16 1" "4 4" "6 3" "8 2" "32 1"; do
    np="${shape% *}"; nd="${shape#* }"
    {
      printf 'cluster:\n  peers: %s\n  drivesPerPeer: %s\n' "$np" "$nd"
      if [ "$nd" -gt 1 ]; then
        printf 'persistence:\n  volumePaths:\n'
        for _ in $(seq 1 "$np"); do printf '    - [%s]\n' "$(seq 1 "$nd" | sed "s#^#/disk#; s#\$#/rustfs#" | paste -sd, -)"; done
      fi
    } >"$tmp.values"
    render -f "$tmp.values" || bad "$np peers x $nd drives was refused: $(tr '\n' ' ' <"$tmp.err")"
  done
  refused 'cluster.peers 17 x cluster.drivesPerPeer 1 = 17 drives cannot form an erasure set' --set cluster.peers=17
  refused 'cluster.peers 19 x cluster.drivesPerPeer 1 = 19 drives cannot form an erasure set' --set cluster.peers=19
  refused '/cluster/peers' --set cluster.peers=3
  refused '/cluster/drivesPerPeer' --set cluster.drivesPerPeer=0
  refused 'more than one drive per peer needs persistence.volumePaths' --set cluster.drivesPerPeer=2
  refused 'more than one drive per peer needs persistence.volumePaths' --set cluster.drivesPerPeer=2 --set persistence.enabled=false
  refused 'persistence.volumePaths has 3 entries but cluster.peers is 4' \
    --set 'persistence.volumePaths[0]=/a' --set 'persistence.volumePaths[1]=/b' --set 'persistence.volumePaths[2]=/c'
  printf '%s\n' 'cluster:' '  drivesPerPeer: 2' 'persistence:' '  volumePaths:' '    - [/a1, /a2]' '    - [/b1, /b2]' '    - [/c1]' '    - [/d1, /d2]' >"$tmp.values"
  refused 'persistence.volumePaths entry 2 (peer 3) has 1 paths but cluster.drivesPerPeer is 2' -f "$tmp.values"
  printf '%s\n' 'cluster:' '  drivesPerPeer: 2' 'persistence:' '  volumePaths:' '    - [/a1, /a2]' '    - [/b1, /b1]' '    - [/c1, /c2]' '    - [/d1, /d2]' >"$tmp.values"
  refused 'persistence.volumePaths entry 1 (peer 2) names one path twice' -f "$tmp.values"
  printf '%s\n' 'persistence:' '  nodeLabelPrefix: ""' '  volumePaths: [/a, /b, /a, /d]' >"$tmp.values"
  refused 'persistence.volumePaths names one host path for two peers while persistence.nodeLabelPrefix is ""' -f "$tmp.values"
  # Compared as paths, not strings.
  printf '%s\n' 'persistence:' '  nodeLabelPrefix: ""' '  volumePaths: [/srv/a, /srv/a/, /srv/./a, /srv/b]' >"$tmp.values"
  refused 'persistence.volumePaths names one host path for two peers while persistence.nodeLabelPrefix is ""' -f "$tmp.values"
  printf '%s\n' 'cluster:' '  drivesPerPeer: 2' 'persistence:' '  volumePaths:' '    - [/a1, /a1/]' '    - [/b1, /b2]' '    - [/c1, /c2]' '    - [/d1, /d2]' >"$tmp.values"
  refused 'persistence.volumePaths entry 0 (peer 1) names one path twice' -f "$tmp.values"
  # ...which pinned peers may do: each is on a node of its own.
  printf '%s\n' 'persistence:' '  volumePaths: [/srv/rustfs, /srv/rustfs, /srv/rustfs, /srv/rustfs]' >"$tmp.values"
  render -f "$tmp.values" || bad "pinned peers with the same host path were refused: $(tr '\n' ' ' <"$tmp.err")"
  refused '/persistence/volumePaths/0' --set 'persistence.volumePaths[0]=relative/path'
  refused '/persistence/volumePrefix' --set persistence.volumePrefix=a/b
  refused 'publish.mode must be host in distributed mode' --set exposure.mode=published --set publish.mode=ingress
  refused 'console.publish.mode must be host in distributed mode' --set console.enabled=true --set console.exposure.mode=published --set console.publish.mode=ingress
  # The standalone store's host path is refused rather than ignored.
  refused 'persistence.volumePath is the standalone store' --set persistence.volumePath=/srv/rustfs
  for k in RUSTFS_VOLUMES MINIO_VOLUMES RUSTFS_LOCAL_ENDPOINT_HOST RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE MINIO_STARTUP_TOPOLOGY_WAIT_MODE; do
    refused "extraEnv: $k is set by the chart from cluster.* and s3.port" --set "extraEnv.$k=x"
  done
  for k in RUSTFS_ERASURE_SET_DRIVE_COUNT MINIO_ERASURE_SET_DRIVE_COUNT; do
    refused "extraEnv: $k would override the erasure set width RustFS derives" --set "extraEnv.$k=4"
  done
  # The peers' internode secret, which RustFS derives from the key pair: a value would be in the manifest.
  refused 'extraEnv: RUSTFS_RPC_SECRET is a credential' --set extraEnv.RUSTFS_RPC_SECRET=x
  for k in RUSTFS_UNSAFE_BYPASS_DISK_CHECK MINIO_UNSAFE_BYPASS_DISK_CHECK MINIO_CI; do
    refused "extraEnv: $k turns off RustFS's refusal of two drives on one disk" --set "extraEnv.$k=true"
  done
  # Neighbouring settings stay open: the topology wait's timeout and the parity.
  render --set extraEnv.RUSTFS_STARTUP_TOPOLOGY_WAIT_TIMEOUT=10m --set extraEnv.RUSTFS_STORAGE_CLASS_STANDARD=EC:1 \
    && [ "$(y '.services."rustfs-4".environment.RUSTFS_STORAGE_CLASS_STANDARD')" = "EC:1" ] \
    || bad "extraEnv RUSTFS_STARTUP_TOPOLOGY_WAIT_TIMEOUT / RUSTFS_STORAGE_CLASS_STANDARD were refused or not passed on to every peer: $(tr '\n' ' ' <"$tmp.err")"

  # The standalone store's refusals, which hold in distributed mode too.
  refused 'metrics.network must differ from network.name and exposure.network' --set metrics.enabled=true --set metrics.network=rustfs-net
  for k in RUSTFS_OBS_ENDPOINT RUSTFS_OBS_LOG_STDOUT_ENABLED; do
    refused "extraEnv: $k is set by the chart while metrics.enabled" --set metrics.enabled=true --set "extraEnv.$k=x"
  done
  refused 'extraEnv: RUSTFS_OBS_METER_INTERVAL cannot be set while metrics.enabled' --set metrics.enabled=true --set extraEnv.RUSTFS_OBS_METER_INTERVAL=x
  refused 'extraEnv: RUSTFS_SECRET_KEY is a credential' --set extraEnv.RUSTFS_SECRET_KEY=x
  refused 'extraEnv: RUSTFS_ADDRESS is set by the chart from s3.port and console.*' --set extraEnv.RUSTFS_ADDRESS=:1
  printf '%s\n' 'extraEnv:' '  "X: y\n    cap_add: [SYS_ADMIN]\n    Z": z' >"$tmp.values"
  refused 'is not an environment variable name' -f "$tmp.values"
  refused 's3.accessKeySecret and s3.secretKeySecret must name two different secrets' --set s3.secretKeySecret=rustfs-access-key
  refused '/buckets/0' --set 'buckets={Bad_Name}'
  refused 'console.ingress.host is required' --set console.enabled=true --set console.exposure.mode=traefik
  refused 'console.port must differ from s3.port' --set console.enabled=true --set console.port=9000
  refused 'console.oidc.enabled needs console.enabled' --set console.oidc.enabled=true --set console.oidc.configUrl=$kc
  refused 'console.oidc.browserUrl is required' --set console.enabled=true --set console.oidc.enabled=true --set console.oidc.configUrl=$kc
  refused 'extraEnv: RUSTFS_IDENTITY_OPENID_REDIRECT_URI is not an OIDC setting extraEnv may tune' "${kco[@]}" --set extraEnv.RUSTFS_IDENTITY_OPENID_REDIRECT_URI=x

  # A disabled console is exposed nowhere, whatever console.exposure says.
  for mode in traefik published; do
    if render --set console.exposure.mode="$mode"; then
      [ "$(y '.services."rustfs-2".deploy.labels | join(" ")')" = "com.swarmcli.rollout=sequential" ] && [ "$(y '.services."rustfs-2".ports')" = "null" ] \
        || bad "console.exposure.mode=$mode with the console off still routes or publishes"
    else
      bad "console.exposure.mode=$mode with the console off was refused: $(tr '\n' ' ' <"$tmp.err")"
    fi
  done
  # The healthcheck off: still stop-first, and still the monitor window that spaces the rollout.
  render --set healthcheck.enabled=false && [ "$(y '.services."rustfs-1".healthcheck')" = "null" ] \
    && [ "$(y '.services."rustfs-1".deploy.update_config | .order + " " + (.monitor // "none")')" = "stop-first 2m" ] \
    || bad "healthcheck.enabled=false does not drop the healthcheck alone, keeping stop-first and the 2m monitor window"
fi

exit "$fail"
