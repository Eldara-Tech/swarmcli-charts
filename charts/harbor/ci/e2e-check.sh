#!/usr/bin/env bash
#
# e2e smoke check for the harbor chart. scripts/e2e-test.sh runs this after the release
# converged:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# Convergence proves little here: every service passes its healthcheck long before it can
# talk to the others. So every case first waits for Harbor's own health API to report all
# components healthy, then:
#   published  pushes an image with docker through nginx -> core -> registry, reads it back
#              through the API, pulls it again and has Trivy scan it;
#   metrics    scrapes core, jobservice, the registry and the exporter from the monitoring
#              overlay, as Prometheus would, and runs promtool on monitoring/;
#   oidc       follows a login to the stub provider's authorization endpoint and checks that
#              CONFIG_OVERWRITE_JSON applied the settings and made them read-only.
# The published port is reached from a container on the host network, i.e. from the swarm
# node, so the check runs the same against a remote daemon (colima) as on a CI runner.
set -euo pipefail

release="$1"
dir="$2"
case="$3"
port=18080
base="http://127.0.0.1:$port"
admin='admin:e2e-admin-Passw0rd'

fail=0
bad() { echo "  FAIL: $*"; fail=1; }
hcurl() { docker run --rm --network host curlimages/curl:latest -s --max-time 30 "$@"; }

# ── all components healthy ────────────────────────────────────────────────────────────
# Healthy overall, no component unhealthy, and the component list there at all.
healthy() { case "$1" in *unhealthy*) return 1 ;; *'"components":[{'*'"status":"healthy"'*) return 0 ;; esac; return 1; }
health=""
for _ in $(seq 1 60); do
  health="$(hcurl "$base/api/v2.0/health" || true)"
  if healthy "$health"; then break; fi
  sleep 5
done
if healthy "$health"; then echo "  health: all components healthy"; else echo "  FAIL: Harbor never reported healthy: $health"; exit 1; fi
[ "$(hcurl -o /dev/null -w '%{http_code}' "$base/v1/")" = "404" ] || bad "nginx does not answer /v1/ with 404; it is not running the chart's config"

if [ "$case" = "published" ]; then
  code="$(hcurl -o /dev/null -w '%{http_code}' -u "$admin" -H 'Content-Type: application/json' \
    -d '{"project_name":"e2e","public":false}' "$base/api/v2.0/projects")"
  case "$code" in 201|409) echo "  api: project e2e ($code)" ;; *) bad "creating project e2e answered $code" ;; esac

  # A DOCKER_CONFIG of its own, with the credentials inline: `docker login` would store them
  # in the invoking user's credential helper (the macOS keychain). It also hides the current
  # docker context, so the daemon it points at is passed on as DOCKER_HOST.
  DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
  export DOCKER_HOST
  cfg="$(mktemp -d)"
  trap 'rm -rf "$cfg"' EXIT
  printf '{"auths":{"127.0.0.1:%s":{"auth":"%s"}}}\n' "$port" "$(printf '%s' "$admin" | base64 | tr -d '\n')" >"$cfg/config.json"
  img="127.0.0.1:$port/e2e/busybox:e2e"
  docker pull -q busybox:1.37 >/dev/null
  docker tag busybox:1.37 "$img"
  if DOCKER_CONFIG="$cfg" docker push -q "$img" >/dev/null; then
    echo "  push: $img"
  else
    bad "docker push $img failed"
  fi
  tags="$(hcurl -u "$admin" "$base/api/v2.0/projects/e2e/repositories/busybox/artifacts?with_tag=true" || true)"
  case "$tags" in *'"name":"e2e"'*) echo "  api: the artifact is listed with tag e2e" ;; *) bad "the pushed artifact is not listed: $tags" ;; esac
  [ "$(hcurl -o /dev/null -w '%{http_code}' "$base/v2/e2e/busybox/manifests/e2e")" = "401" ] \
    || bad "an anonymous manifest read of the private project was not refused with 401"
  docker rmi -f "$img" >/dev/null
  if DOCKER_CONFIG="$cfg" docker pull -q "$img" >/dev/null; then echo "  pull: $img"; else bad "docker pull $img failed"; fi
  docker rmi -f "$img" >/dev/null 2>&1 || true

  # Trivy downloads its database on the first scan, so this waits a while.
  code="$(hcurl -o /dev/null -w '%{http_code}' -u "$admin" -X POST "$base/api/v2.0/projects/e2e/repositories/busybox/artifacts/e2e/scan")"
  status="not started (HTTP $code)"
  [ "$code" = "202" ] && for _ in $(seq 1 60); do
    art="$(hcurl -u "$admin" "$base/api/v2.0/projects/e2e/repositories/busybox/artifacts/e2e?with_scan_overview=true" || true)"
    status="$(sed -n 's/.*"scan_status":"\([A-Za-z]*\)".*/\1/p' <<<"$art")"
    case "$status" in Success|Error|Stopped) break ;; esac
    sleep 5
  done
  if [ "$status" = "Success" ]; then echo "  scan: Trivy finished (Success)"; else bad "the Trivy scan ended '$status'"; fi
fi

if [ "$case" = "metrics" ]; then
  for t in core:harbor_core_ jobservice:harbor_jobservice_ registry:registry_ exporter:harbor_up; do
    svc="${t%%:*}"; want="${t#*:}"
    body="$(docker run --rm --network monitoring curlimages/curl:latest -fsS --max-time 30 \
      "http://${release}_${svc}:8001/metrics" 2>&1 || true)"
    if grep -E "^${want}" <<<"$body" >/dev/null; then
      echo "  metrics: ${svc} serves ${want}*"
    else
      bad "${release}_${svc}:8001/metrics has no ${want}* from the monitoring overlay: $(sed -n 1,3p <<<"$body" | tr '\n' ' ')"
    fi
  done

  # Nothing deploys monitoring/, so nothing else would notice the rules broke.
  chart_abs="$(cd "$dir" && pwd)"
  prom_tag="$(sed -n 's/^appVersion: *"\(.*\)"$/\1/p' "$chart_abs/../prometheus-stack/Chart.yaml")"
  promtool_image="${HARBOR_E2E_PROMTOOL_IMAGE:-prom/prometheus:${prom_tag:?no appVersion in charts/prometheus-stack/Chart.yaml}}"
  if ! out="$(docker run --rm --entrypoint promtool -v "$chart_abs:/chart:ro" "$promtool_image" \
      test rules /chart/ci/harbor-rules-test.yml 2>&1)"; then
    bad "promtool test rules failed: $out"
  else
    echo "  promtool: monitoring/harbor-rules.yml passes ci/harbor-rules-test.yml"
  fi
fi

if [ "$case" = "oidc" ]; then
  info="$(hcurl "$base/api/v2.0/systeminfo" || true)"
  case "$info" in *'"auth_mode":"oidc_auth"'*) echo "  systeminfo: auth_mode oidc_auth" ;; *) bad "auth_mode is not oidc_auth: $info" ;; esac
  loc="$(hcurl -o /dev/null -w '%{redirect_url}' "$base/c/oidc/login" || true)"
  case "$loc" in
    http://harbor-e2e-idp:8080/realms/e2e/protocol/openid-connect/auth\?*client_id=harbor*)
      case "$loc" in
        *redirect_uri=http%3A%2F%2F127.0.0.1%3A$port%2Fc%2Foidc%2Fcallback*) echo "  login: redirected to the provider with the callback" ;;
        *) bad "the login redirect does not carry the callback $base/c/oidc/callback: $loc" ;;
      esac
      ;;
    *) bad "the login does not redirect to the provider's authorization endpoint: '$loc'" ;;
  esac
  cfgs="$(hcurl -u "$admin" "$base/api/v2.0/configurations" || true)"
  pcr="$(grep -o '"project_creation_restriction":{[^}]*}' <<<"$cfgs" || true)"
  case "$pcr" in
    *'"value":"adminonly"'*) case "$pcr" in *'"editable":false'*) echo "  settings: config applied, read-only" ;; *) bad "project_creation_restriction is editable: $pcr" ;; esac ;;
    *) bad "project_creation_restriction is not adminonly: '$pcr'" ;;
  esac
  case "$cfgs" in *'e2e-oidc-client-secret'*) bad "the configuration API returns the OIDC client secret" ;; esac
  # The splice itself: docker exec sees the service's environment, not the wrapper's exports,
  # so read core's PID 1, which the wrapper exec'd into.
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_core" | sed -n 1p)"
  penv="$(docker exec "$cid" cat /proc/1/environ | tr '\0' '\n')"
  if grep -F '"oidc_client_secret":"e2e-oidc-client-secret"' <<<"$(grep '^CONFIG_OVERWRITE_JSON=' <<<"$penv")" >/dev/null; then
    echo "  wrapper: core runs with the client secret spliced into CONFIG_OVERWRITE_JSON"
  else
    bad "core's CONFIG_OVERWRITE_JSON does not carry the client secret from the Swarm secret"
  fi
  if grep '^HARBOR_OIDC_CLIENT_SECRET=' <<<"$penv" >/dev/null; then bad "the wrapper left HARBOR_OIDC_CLIENT_SECRET in core's environment"; fi
fi

exit "$fail"
