#!/usr/bin/env bash
#
# Render assertions for the traefik chart. scripts/test-charts.sh runs this after a
# successful render:
#   $1 = the rendered stack file   $2 = the fixture case name
# Exit 0 = OK. Data-only (no deploy), so it rides charts.yml / make test.
#
# It guards metrics.enabled, whose mistakes all still converge to a healthy edge:
#
#   * /metrics on Traefik's default `traefik` entrypoint shares a listener with the API,
#     and a published metrics port serves it to the internet without authentication.
#   * Once a service opts in to discovery, every one of its deploy labels is readable
#     through Prometheus's targets API, so a basic-auth hash must never sit beside the
#     discovery labels. The render refuses that; the refusals are checked here too.
#   * Off by default: no fixture but `metrics` may carry the labels or join monitoring.
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

svc='.services.traefik'
q() { yq -r "$1" "$rendered"; }

cmd="$(q "$svc.command[]")"
labels="$(q "$svc.deploy.labels[]")"
nets="$(q "$svc.networks[]" | sort | tr '\n' ' ')"
[ -n "$cmd" ] && [ -n "$labels" ] || bad "the traefik service has no command or no labels — every check below would pass vacuously"

# ── in every fixture ──────────────────────────────────────────────────────────────────
for p in $(q "$svc.ports // [] | .[] | .target"); do
  case "$p" in 80|443|2222) ;; *) bad "port $p is published; only the fixtures' entrypoints may be" ;; esac
done
if grep -E -- '^--(entrypoints|entryPoints)\.traefik\.|^--metrics\.prometheus\.entryPoint=traefik$' <<<"$cmd" >/dev/null; then
  bad "the default 'traefik' entrypoint is configured; it shares a listener with the API"
fi

if [ "$case" != "metrics" ]; then
  if grep -E '^prometheus\.io/' <<<"$labels" >/dev/null; then bad "case $case: discovery labels rendered although metrics are off"; fi
  if grep -F -- '--metrics.' <<<"$cmd" >/dev/null; then bad "case $case: a metrics flag is rendered although metrics are off"; fi
  [ "$nets" = "traefik-public " ] || bad "case $case: networks are '$nets', expected traefik-public alone"
  exit "$fail"
fi

# ── metrics ───────────────────────────────────────────────────────────────────────────
port="$(sed -n 's/^--entrypoints\.metrics\.address=:\([0-9]*\)$/\1/p' <<<"$cmd")"
[ -n "$port" ] || bad "no --entrypoints.metrics.address=:<port>"
grep -Fx -- '--metrics.prometheus=true' <<<"$cmd" >/dev/null || bad "--metrics.prometheus=true is missing"
grep -Fx -- '--metrics.prometheus.entryPoint=metrics' <<<"$cmd" >/dev/null \
  || bad "metrics are not served on the dedicated 'metrics' entrypoint"
grep -Fx -- '--api.insecure=false' <<<"$cmd" >/dev/null \
  || bad "the insecure API is on in the metrics fixture; the monitoring overlay would reach it"

disc="$(grep -E '^prometheus\.io/' <<<"$labels" | sort | tr '\n' ',')"
[ "$disc" = "prometheus.io/port=$port,prometheus.io/scrape=true," ] \
  || bad "discovery labels are '$disc', expected scrape=true and port=$port (the metrics entrypoint)"
for p in $(q "$svc.ports // [] | .[] | .target"); do
  [ "$p" != "$port" ] || bad "the metrics port $port is published; /metrics has no authentication"
done
[ "$nets" = "monitoring traefik-public " ] || bad "networks are '$nets', expected monitoring and traefik-public"
[ "$(q '.networks.monitoring.external')" = "true" ] || bad "monitoring is not declared external"

# No credential material in any label of a service Prometheus discovers.
if grep -Ei 'basicauth\.users=|digestauth\.users=' <<<"$labels" >/dev/null; then
  bad "a basic/digest-auth hash is in the labels of a service Prometheus discovers"
fi
grep -Fx 'traefik.http.middlewares.admin-auth.basicauth.usersfile=/run/secrets/traefik_dashboard_users' <<<"$labels" >/dev/null \
  || bad "the dashboard middleware does not read its users from the mounted secret"
grep -Fx 'traefik.http.routers.traefik-public-https.middlewares=admin-auth,hsts-header' <<<"$labels" >/dev/null \
  || bad "the dashboard router does not apply admin-auth"
[ "$(q "$svc.secrets[0]")" = "traefik_dashboard_users" ] || bad "the users secret is not mounted into traefik"
[ "$(q '.secrets.traefik_dashboard_users.external')" = "true" ] || bad "the users secret is not declared external"

# The refusals. Rendered from this fixture's chart with SWARMCLI, which test-charts.sh sets.
chart="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() { "${SWARMCLI:?render-check needs SWARMCLI to test the refusals}" charts template r "$chart" -f "$chart/ci/metrics-values.yaml" "$@"; }
refused() {
  local want="$1"; shift
  if render "$@" >/dev/null 2>"$tmp/err"; then
    bad "rendered with $* — it must be refused"
  elif ! grep -F "$want" "$tmp/err" >/dev/null; then
    bad "$* failed, but not with \"$want\": $(cat "$tmp/err")"
  fi
}
cat >"$tmp/users.yaml" <<'EOF'
traefik:
  dashboard:
    basicAuthSecret: ""
    basicAuthUsers: "admin:$$apr1$$x$$y"
EOF
cat >"$tmp/both.yaml" <<'EOF'
traefik:
  dashboard:
    basicAuthUsers: "admin:$$apr1$$x$$y"
EOF
cat >"$tmp/extra.yaml" <<'EOF'
extraLabels:
  traefik.http.middlewares.ops.BasicAuth.Users: "ops:$$apr1$$x$$y"
EOF
cat >"$tmp/off.yaml" <<'EOF'
metrics:
  enabled: false
traefik:
  dashboard:
    basicAuthSecret: ""
    basicAuthUsers: "admin:$$apr1$$x$$y"
EOF
refused 'set traefik.dashboard.basicAuthSecret instead' -f "$tmp/users.yaml"
refused 'are alternatives' -f "$tmp/both.yaml"
refused 'carries password hashes' -f "$tmp/extra.yaml"
render -f "$tmp/off.yaml" >/dev/null 2>"$tmp/err" \
  || bad "basicAuthUsers without metrics was refused; it must keep working: $(cat "$tmp/err")"

exit "$fail"
