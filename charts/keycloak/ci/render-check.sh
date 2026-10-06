#!/usr/bin/env bash
#
# Render assertions for the keycloak chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# It guards metrics.enabled, where every mistake still converges to a healthy task:
#
#   * Off by default. Opting in attaches Keycloak to the monitoring overlay, which makes
#     :8080 reachable from everything on it, and hands every deploy label of the service
#     to anyone who can query Prometheus. No fixture but `metrics` may do either.
#   * The discovery labels must name the port the management interface (and the
#     healthcheck) really listens on, or Prometheus scrapes nothing and says only "down".
#   * The management interface must stay plain HTTP: the swarm-tasks job has no scheme
#     label, so an HTTPS :9000 (Keycloak's default once it holds a certificate) would
#     fail every scrape — and the /dev/tcp healthcheck with it.
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

svc='.services.keycloak'
q() { yq -r "$1" "$rendered"; }

[ "$(q "$svc.image")" != "null" ] || bad "no keycloak service rendered — every check below would pass vacuously"

labels="$(q "$svc.deploy.labels // [] | .[]")"
nets="$(q "$svc.networks // [] | .[]")"
prom="$(grep -E '^prometheus\.io/' <<<"$labels" || true)"

# ── the management interface stays plain HTTP, in every fixture ───────────────────────
if [ "$(q "$svc.environment.KC_HTTPS_CERTIFICATE_FILE")" != "null" ] \
   && [ "$(q "$svc.environment.KC_HTTP_MANAGEMENT_SCHEME")" != "http" ]; then
  bad "Keycloak holds a certificate but KC_HTTP_MANAGEMENT_SCHEME is not http: :9000 would serve HTTPS, which neither the healthcheck nor a scrape speaks"
fi

if [ "$case" = "metrics" ]; then
  [ "$(q "$svc.environment.KC_METRICS_ENABLED")" = "true" ] \
    || bad "case $case: KC_METRICS_ENABLED is not \"true\" — :9000/metrics would 404"
  [ "$(sort <<<"$prom" | tr '\n' ',')" = "prometheus.io/port=9000,prometheus.io/scrape=true," ] \
    || bad "case $case: discovery labels are '$(tr '\n' ' ' <<<"$prom")', expected exactly scrape=true and port=9000"
  q "$svc.healthcheck.test[3]" | grep -F 'exec 3<>/dev/tcp/127.0.0.1/9000' >/dev/null \
    || bad "case $case: the healthcheck no longer probes :9000, so port=9000 is not known to be the management port"
  grep -Fx monitoring <<<"$nets" >/dev/null || bad "case $case: the service is not on the monitoring overlay; Prometheus cannot reach it"
  [ "$(q '.networks.monitoring.external')" = "true" ] || bad "case $case: monitoring is not declared external: true"
  for n in traefik-public keycloak-db-net; do
    grep -Fx "$n" <<<"$nets" >/dev/null || bad "case $case: joining monitoring dropped $n"
  done
  [ "$(grep -c . <<<"$nets")" = "$(sort -u <<<"$nets" | grep -c .)" ] || bad "case $case: a network is listed twice"
  [ "$(q "$svc.ports")" = "null" ] || bad "case $case: a port is published; /metrics has no authentication"
  grep -Fx 'team=iam' <<<"$labels" >/dev/null || bad "case $case: the user's labels were dropped"
else
  [ "$(q "$svc.environment.KC_METRICS_ENABLED")" = "null" ] || bad "case $case: KC_METRICS_ENABLED is set; metrics must be opt-in"
  [ -z "$prom" ] || bad "case $case: discovery labels rendered ($(tr '\n' ' ' <<<"$prom")); metrics must be opt-in"
  if grep -Fx monitoring <<<"$nets" >/dev/null || [ "$(q '.networks.monitoring')" != "null" ]; then
    bad "case $case: the monitoring overlay is attached; metrics must be opt-in"
  fi
fi

exit "$fail"
