#!/usr/bin/env bash
#
# Render-time assertions for the loki chart, run by scripts/test-charts.sh after a fixture
# renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so every fixture is checked here —
# including the five that never run in e2e.
#
# What is asserted is what a render can get silently wrong and a deploy would not report:
#
#   * the shipped config is mounted under a VERSIONED name. Swarm config data is immutable,
#     so a stable name turns an edited files/loki-config.yaml into a failed upgrade
#     ("only updates to Labels are allowed") rather than a rotation.
#   * retention flags. Nothing at deploy time says "this Loki will never delete anything" —
#     the volume just fills up weeks later.
#   * the basic-auth middleware sits on the PUBLIC router. With tls:true the HTTP router
#     only redirects, so auth belongs on the HTTPS one; putting it on the redirecting
#     router would serve the whole API unauthenticated over HTTPS.
#   * Alloy holds the Docker socket and must NOT be on the ingress overlay, and must reach
#     Loki over the stack-internal one.
set -euo pipefail

out="$1"
case="${2:-}"
fail=0

# The flags live in services.loki.command; join them so a single grep can match one.
cmd="$(yq -r '.services.loki.command | join(" ")' "$out")"

want_flag() {
  case " $cmd " in
    *" $1 "*) return 0 ;;
    *) echo "  FAIL($case): loki command is missing $1"; fail=1 ;;
  esac
}
deny_flag() {
  case " $cmd " in
    *" $1 "*) echo "  FAIL($case): loki command carries $1 and should not"; fail=1 ;;
  esac
}

# ---------------------------------------------------------------- every fixture
want_flag "-log.level=info"
want_flag "-reporting.enabled=false"

# Loki is single-replica everywhere: two processes over one filesystem store corrupt each
# other's index, so a fixture that raised it would be a data-loss bug, not a variant.
[ "$(yq -r '.services.loki.deploy.replicas' "$out")" = "1" ] \
  || { echo "  FAIL($case): loki is not a single replica"; fail=1; }

# ------------------------------------------------------- configuration delivery
case "$case" in
  external-config)
    [ "$(yq -r '.configs.loki-config.external' "$out")" = "true" ] \
      || { echo "  FAIL($case): loki-config is not an external Swarm config"; fail=1; }
    [ "$(yq -r '.configs.loki-config.file // "none"' "$out")" = "none" ] \
      || { echo "  FAIL($case): external mode still ships the chart's own config file"; fail=1; }
    want_flag "-config.file=/etc/loki/loki-config.yaml"
    ;;
  external-secret)
    [ "$(yq -r '.secrets.loki-config.external' "$out")" = "true" ] \
      || { echo "  FAIL($case): loki-config is not an external Swarm secret"; fail=1; }
    [ "$(yq -r '.configs.loki-config // "none"' "$out")" = "none" ] \
      || { echo "  FAIL($case): secret mode also rendered a config object"; fail=1; }
    # A secret is mounted under /run/secrets, so the flag has to follow it there.
    want_flag "-config.file=/run/secrets/loki-config"
    ;;
  *)
    [ "$(yq -r '.configs.loki-config.file' "$out")" = "files/loki-config.yaml" ] \
      || { echo "  FAIL($case): the chart's own config file is not mounted"; fail=1; }
    # Versioned name == rotation. A bare "<stack>_loki-config" would be refused on upgrade.
    yq -r '.configs.loki-config.name' "$out" | grep -E '_loki-config_[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null \
      || { echo "  FAIL($case): the config name carries no chart version, so changed contents cannot rotate"; fail=1; }
    want_flag "-config.file=/etc/loki/loki-config.yaml"
    ;;
esac

# ------------------------------------------------------------------- retention
if [ "$case" = "retention-off" ]; then
  want_flag "-compactor.retention-enabled=false"
  deny_flag "-store.retention=744h"
  grep -E '^ *- "?-store\.retention' "$out" >/dev/null \
    && { echo "  FAIL($case): retention is off but a -store.retention flag was rendered"; fail=1; }
else
  want_flag "-compactor.retention-enabled=true"
  want_flag "-store.retention=744h"
fi

# ----------------------------------------------------------------- persistence
case "$case" in
  ephemeral)
    [ "$(yq -r '.volumes // "none"' "$out")" = "none" ] \
      || { echo "  FAIL($case): persistence is off but a volume was declared"; fail=1; }
    [ "$(yq -r '.services.loki.volumes // "none"' "$out")" = "none" ] \
      || { echo "  FAIL($case): persistence is off but /loki was mounted"; fail=1; }
    # The pin must travel with the volume (#55): a constraint on a label nobody set leaves
    # the task Pending forever.
    [ "$(yq -r '.services.loki.deploy.placement // "none"' "$out")" = "none" ] \
      || { echo "  FAIL($case): persistence is off but the data-node pin survived"; fail=1; }
    ;;
  bind-mount)
    yq -r '.services.loki.volumes[]' "$out" | grep -x '/tmp/loki-e2e/data:/loki' >/dev/null \
      || { echo "  FAIL($case): /loki is not bind-mounted from the host path"; fail=1; }
    [ "$(yq -r '.volumes // "none"' "$out")" = "none" ] \
      || { echo "  FAIL($case): host-path persistence still declared a named volume"; fail=1; }
    ;;
  *)
    yq -r '.services.loki.deploy.placement.constraints[]' "$out" | grep -x 'node.labels.loki-data == true' >/dev/null \
      || { echo "  FAIL($case): the data volume is not pinned to the loki-data node"; fail=1; }
    ;;
esac

# -------------------------------------------------------------------- exposure
labels="$(yq -r '.services.loki.deploy.labels // [] | join("\n")' "$out")"
ports="$(yq -r '.services.loki.ports // [] | length' "$out")"

case "$case" in
  published|ephemeral|bind-mount|external-config|external-secret)
    [ "$ports" = "1" ] \
      || { echo "  FAIL($case): published mode did not publish exactly one port"; fail=1; }
    [ "$(yq -r '.services.loki.ports[0].target' "$out")" = "3100" ] \
      || { echo "  FAIL($case): the published port does not target Loki's HTTP port"; fail=1; }
    ;;
  edge)
    # tls:false => the HTTP router is the public one, so it carries the auth middleware.
    printf '%s\n' "$labels" | grep -x 'traefik.http.routers.ci-http.middlewares=ci-auth' >/dev/null \
      || { echo "  FAIL($case): the public HTTP router carries no basic-auth middleware"; fail=1; }
    printf '%s\n' "$labels" | grep 'routers.ci-https' >/dev/null \
      && { echo "  FAIL($case): tls is off but an HTTPS router was rendered"; fail=1; }
    [ "$ports" = "0" ] \
      || { echo "  FAIL($case): traefik mode also published a port"; fail=1; }
    ;;
  traefik-auth)
    # tls:true => the HTTP router only redirects; auth belongs on the HTTPS router.
    printf '%s\n' "$labels" | grep -x 'traefik.http.routers.ci-http.middlewares=https-redirect' >/dev/null \
      || { echo "  FAIL($case): the HTTP router does not redirect to HTTPS"; fail=1; }
    printf '%s\n' "$labels" | grep -x 'traefik.http.routers.ci-https.middlewares=ci-auth' >/dev/null \
      || { echo "  FAIL($case): the public HTTPS router carries no basic-auth middleware"; fail=1; }
    # The swarm provider discovers nothing without the constraint label (charts/traefik).
    printf '%s\n' "$labels" | grep -x 'traefik.constraint-label=traefik-public' >/dev/null \
      || { echo "  FAIL($case): the routed service carries no constraint label"; fail=1; }
    ;;
  default|shipper|retention-off)
    [ "$ports" = "0" ] \
      || { echo "  FAIL($case): exposure is none but a port was published"; fail=1; }
    [ "$labels" = "" ] \
      || { echo "  FAIL($case): exposure is none but Traefik labels were rendered"; fail=1; }
    ;;
esac

# --------------------------------------------------------------------- shipper
if [ "$case" = "shipper" ]; then
  [ "$(yq -r '.services.alloy.deploy.mode' "$out")" = "global" ] \
    || { echo "  FAIL($case): the shipper is not a global service, so some nodes ship nothing"; fail=1; }
  yq -r '.services.alloy.volumes[]' "$out" | grep -x '/var/run/docker.sock:/var/run/docker.sock:ro' >/dev/null \
    || { echo "  FAIL($case): the shipper does not mount the Docker socket read-only"; fail=1; }
  [ "$(yq -r '.services.alloy.environment.LOKI_PUSH_URL' "$out")" = "http://loki:3100/loki/api/v1/push" ] \
    || { echo "  FAIL($case): the shipper does not push to the in-stack Loki service"; fail=1; }
  # The socket holder stays off the ingress overlay and reaches Loki over the internal one.
  [ "$(yq -r '.services.alloy.networks | join(",")' "$out")" = "internal" ] \
    || { echo "  FAIL($case): the shipper is attached to something other than the internal overlay"; fail=1; }
  yq -r '.services.loki.networks[]' "$out" | grep -x 'internal' >/dev/null \
    || { echo "  FAIL($case): loki is not on the internal overlay, so the shipper cannot reach it"; fail=1; }
  [ "$(yq -r '.networks.internal // "none"' "$out")" != "none" ] \
    || { echo "  FAIL($case): the internal overlay is not declared"; fail=1; }
  # A Swarm service template the daemon resolves per task — not something this chart can
  # render, and the label is wrong on every node if it is lost.
  [ "$(yq -r '.services.alloy.environment.NODE_NAME' "$out")" = '{{.Node.Hostname}}' ] \
    || { echo "  FAIL($case): the shipper does not label lines with the node they came from"; fail=1; }
else
  [ "$(yq -r '.services.alloy // "none"' "$out")" = "none" ] \
    || { echo "  FAIL($case): the shipper is off but an alloy service was rendered"; fail=1; }
fi

[ "$fail" -eq 0 ] || exit 1
echo "  $case: render assertions OK"
