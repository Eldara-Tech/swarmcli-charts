#!/usr/bin/env bash
#
# e2e smoke check for the prometheus-stack chart. scripts/e2e-test.sh runs this after the
# release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence proves six processes started, which says little here: a discovery job that
# finds nothing, a proxy that refuses Prometheus, a dashboard provisioned against a missing
# datasource, or an alert that never reaches Alertmanager all converge just the same. So the
# default case follows the data end to end: exporters discovered through the proxy and
# scraped, rules evaluated, the Watchdog alert delivered, Grafana reading both datasources.
#
# Probes run in the relevant task's network namespace (`--network container:<id>`): the
# stack's own overlay is not attachable, and the namespace behaves the same on a Linux
# runner and on a Docker-in-VM laptop. No jq: every PromQL query is shaped to return one
# number, and JSON bodies are matched as text.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

CURL_IMAGE="${PROMSTACK_E2E_CURL_IMAGE:-curlimages/curl:latest}"
ADMIN="admin:e2e-admin-password"   # the secret ci/e2e-setup.sh creates

cid() { docker ps -q -f "label=com.docker.swarm.service.name=${release}_$1" | sed -n 1p; }

# curl from inside <service>'s network namespace. The container is re-resolved per call, so
# a task replaced under us does not leave later probes talking to a dead namespace.
in_ns() {
  local svc="$1" c
  shift
  c="$(cid "$svc")"
  [ -n "$c" ] || return 1
  docker run --rm --network "container:$c" "$CURL_IMAGE" -sS --max-time 15 "$@"
}
code() { in_ns "$@" -o /dev/null -w '%{http_code}' 2>/dev/null || true; }

diagnose() {
  echo "  --- diagnostics ---"
  docker stack ps "$release" --no-trunc 2>/dev/null | sed -n '1,12p' | sed 's/^/    /' || true
  for svc in $(docker stack services "$release" --format '{{.Name}}' 2>/dev/null); do
    echo "    --- $svc (tail 15) ---"
    docker service logs --tail 15 "$svc" 2>&1 | sed 's/^/      /' || true
  done
}
fail() { echo "  FAIL: $*"; diagnose; exit 1; }

# wait_for <description> <command...>: retry for ~3 minutes (scrape and discovery both run
# every 30s, so the first samples of a target take up to a minute and a half).
wait_for() {
  local desc="$1"
  shift
  LAST=""
  for _ in $(seq 1 36); do
    if "$@" >/dev/null 2>&1; then echo "  $desc"; return 0; fi
    sleep 5
  done
  fail "$desc: never true${LAST:+ (last: $LAST)}"
}

promql() { in_ns prometheus -G "http://127.0.0.1:9090/api/v1/query" --data-urlencode "query=$1" 2>/dev/null; }
# The value of a single-sample result, or nothing.
promval() { promql "$1" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'; }
LAST=""
prom_is() { LAST="$(promval "$1")"; [ "$LAST" = "$2" ]; }
body_has() { local b; b="$("${@:2}" 2>/dev/null || true)"; grep -F -- "$1" <<<"$b" >/dev/null; }
code_is() { [ "$(code "${@:2}")" = "$1" ]; }

has_am=1; has_gf=1
[ "$case" = minimal ] && { has_am=0; has_gf=0; }

# ------------------------------------------------------------------ readiness
wait_for "prometheus: /-/ready" code_is 200 prometheus http://127.0.0.1:9090/-/ready
if [ "$has_am" = 1 ]; then
  wait_for "alertmanager: /-/ready" code_is 200 alertmanager http://127.0.0.1:9093/-/ready
fi
if [ "$has_gf" = 1 ]; then
  wait_for "grafana: /api/health" code_is 200 grafana http://127.0.0.1:3000/api/health
fi

# ------------------------------------------ config validity, inside the running tasks
# Only Swarm can evaluate the golang template, so this is the one place the RENDERED
# prometheus.yml exists.
case "$case" in
  default|alertmanager-config)
    out="$(docker exec "$(cid prometheus)" promtool check config /etc/prometheus/prometheus.yml 2>&1)" \
      || fail "promtool rejects the rendered prometheus.yml: $out"
    echo "  prometheus: promtool check config OK"
    out="$(docker exec "$(cid alertmanager)" amtool check-config /etc/alertmanager/alertmanager.yml 2>&1)" \
      || fail "amtool rejects the alertmanager config: $out"
    echo "  alertmanager: amtool check-config OK"
    ;;
esac

# Grafana's secrets never appear in plain in the service spec. Read from the daemon, not
# from /proc/1/environ: the image's run.sh exports the password into the process
# environment itself, which is the image's business, not the chart's.
if [ "$has_gf" = 1 ]; then
  env_spec="$(docker service inspect "${release}_grafana" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}')"
  grep -F 'e2e-admin-password' <<<"$env_spec" >/dev/null && fail "the admin password is in grafana's service spec"
  grep -F 'GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password' <<<"$env_spec" >/dev/null \
    || fail "grafana's service spec does not carry GF_SECURITY_ADMIN_PASSWORD__FILE"
fi

nodes="$(docker node ls -q | wc -l | tr -d ' ')"
host="$(docker node inspect self --format '{{.Description.Hostname}}')"

case "$case" in
  default)
    # --- discovery through the proxy, and the data behind it ---
    wait_for "node-exporter: up on all $nodes node(s)" prom_is 'count(up{job="node-exporter"} == 1)' "$nodes"
    wait_for "cadvisor: up on all $nodes node(s)" prom_is 'count(up{job="cadvisor"} == 1)' "$nodes"
    wait_for "cadvisor: container series carry the swarm service label" \
      prom_is "count(container_last_seen{container_label_com_docker_swarm_service_name=\"${release}_prometheus\"}) > bool 0" 1
    wait_for "node label: node-exporter on this node is node=\"$host\"" \
      prom_is "count(up{job=\"node-exporter\",node=\"$host\"} == 1)" 1
    wait_for "prometheus: one Alertmanager discovered" prom_is 'prometheus_notifications_alertmanagers_discovered' 1
    wait_for "alertmanager: the Watchdog alert arrived" \
      body_has '"alertname":"Watchdog"' in_ns alertmanager http://127.0.0.1:9093/api/v2/alerts

    # --- Grafana ---
    [ "$(code grafana http://127.0.0.1:3000/api/datasources)" = 401 ] || fail "grafana answers /api/datasources without credentials"
    [ "$(code grafana -u "$ADMIN" http://127.0.0.1:3000/api/datasources)" = 200 ] || fail "grafana refuses the admin password from the secret"
    echo "  grafana: 401 without credentials, 200 with the secret's password"
    wait_for "grafana: the Prometheus datasource is healthy" \
      body_has '"status":"OK"' in_ns grafana -u "$ADMIN" http://127.0.0.1:3000/api/datasources/uid/prometheus/health
    wait_for "grafana: the Alertmanager datasource reaches Alertmanager" \
      code_is 200 grafana -u "$ADMIN" http://127.0.0.1:3000/api/datasources/proxy/uid/alertmanager/api/v2/status
    search="$(in_ns grafana -u "$ADMIN" 'http://127.0.0.1:3000/api/search?type=dash-db' 2>/dev/null || true)"
    grep -F '"uid":"rYdddlPWk"' <<<"$search" >/dev/null || fail "grafana does not list Node Exporter Full: $search"
    grep -F '"uid":"swarm-services"' <<<"$search" >/dev/null || fail "grafana does not list Swarm services: $search"
    echo "  grafana: both dashboards provisioned"

    # --- the socket-proxy, probed from the Prometheus task it admits ---
    proxy="http://${release}_socket-proxy:2375"
    api="$(in_ns prometheus -I "$proxy/_ping" 2>/dev/null | tr -d '\r' | sed -n 's/^[Aa]pi-[Vv]ersion: *//p')"
    [ -n "$api" ] || fail "the socket-proxy's /_ping carries no Api-Version header"
    [ "$(code prometheus "$proxy/v$api/tasks")" = 200 ] || fail "the socket-proxy refuses GET /v$api/tasks"
    [ "$(code prometheus "$proxy/v$api/containers/json")" = 403 ] || fail "the socket-proxy serves /v$api/containers/json"
    [ "$(code prometheus "$proxy/v$api/tasks/x/logs")" = 403 ] || fail "the socket-proxy serves a task logs path"
    [ "$(code prometheus "$proxy/tasks")" = 403 ] || fail "the socket-proxy serves the unversioned /tasks: the allow-list is not anchored"
    [ "$(code prometheus -X POST "$proxy/v$api/services/create")" = 405 ] || fail "the socket-proxy accepts a POST"
    echo "  socket-proxy: 200 on /v$api/tasks; 403 on containers, logs and unversioned paths; 405 on POST"
    ;;

  alertmanager-config)
    wait_for "alertmanager: runs the operator's config (webhook url_file)" \
      body_has 'url_file: /run/secrets/prometheus-stack-e2e-webhook' in_ns alertmanager http://127.0.0.1:9093/api/v2/status
    wait_for "alertmanager: the Watchdog alert arrived" \
      body_has '"alertname":"Watchdog"' in_ns alertmanager http://127.0.0.1:9093/api/v2/alerts
    ;;

  discovery)
    wait_for "discovery: both labelled services are up" \
      prom_is 'count(up{job=~"e2e-labelled|e2e-extra"} == 1)' 2
    # The pre-relabel count equals what the daemon's label filter returns: every task of
    # every opted-in service in the swarm (running or not; stopped tasks keep their network
    # attachments), times its addresses. The unlabelled twin, on the same network as the
    # labelled one, must not be in it. Computed, not hard-coded, and re-read each round.
    expected_sd() {
      local total=0 svc ports m t n a
      for svc in $(docker service ls -q --filter label=prometheus.io/scrape=true); do
        ports="$(docker service inspect "$svc" --format '{{range .Endpoint.Ports}}{{if eq .Protocol "tcp"}}x{{end}}{{end}}' 2>/dev/null || true)"
        m=${#ports}; [ "$m" -gt 0 ] || m=1
        for t in $(docker service ps -q --no-trunc "$svc" 2>/dev/null); do
          n="$(docker inspect --type task "$t" --format '{{range .NetworksAttachments}}{{len .Addresses}} {{end}}' 2>/dev/null || true)"
          for a in $n; do total=$((total + a * m)); done
          n="$(docker inspect --type task "$t" --format '{{range .Status.PortStatus.Ports}}{{if eq .Protocol "tcp"}}x{{end}}{{end}}' 2>/dev/null || true)"
          total=$((total + ${#n}))
        done
      done
      echo "$total"
    }
    sd_matches() {
      local want got
      want="$(expected_sd)"
      got="$(promval 'sum(prometheus_sd_discovered_targets{config="swarm-tasks"})')"
      LAST="discovered=$got expected=$want"
      [ -n "$got" ] && [ "$got" = "$want" ]
    }
    wait_for "discovery: pre-relabel target count equals the opted-in tasks alone" sd_matches
    echo "    ($LAST)"
    ;;

  edge)
    . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
    edge_assert_routed grafana.e2e.test /api/health 200 || fail "grafana is not routed through the edge"
    edge_assert_routed prometheus.e2e.test /-/ready 401 || fail "prometheus is routed without basic auth"
    authed="$(docker run --rm --network "$EDGE_NETWORK" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -u e2e:e2e-secret -H 'Host: prometheus.e2e.test' "http://${EDGE_TARGET}:80/-/ready" 2>/dev/null || true)"
    [ "$authed" = 200 ] || fail "prometheus through the edge with credentials returned ${authed:-<none>}, want 200"
    echo "  edge: prometheus 401 without credentials, 200 with"
    ;;

  published)
    ports="$(docker service inspect "${release}_grafana" \
      --format '{{range .Endpoint.Ports}}{{.PublishMode}}:{{.PublishedPort}}->{{.TargetPort}} {{end}}')"
    grep -F 'ingress:3000->3000' <<<"$ports" >/dev/null || fail "grafana does not publish 3000 on the routing mesh: $ports"
    echo "  grafana: port 3000 published (ingress)"
    ;;

  loki)
    wait_for "grafana: the Loki datasource points at the configured URL" \
      body_has '"url":"http://e2e-loki_loki:3100"' in_ns grafana -u "$ADMIN" http://127.0.0.1:3000/api/datasources/uid/loki
    ;;

  extras)
    env_spec="$(docker service inspect "${release}_grafana" --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}')"
    grep -F 'GF_SMTP_PASSWORD__FILE=/run/secrets/prometheus-stack-e2e-smtp' <<<"$env_spec" >/dev/null \
      || fail "grafana.extraSecrets did not arrive as GF_SMTP_PASSWORD__FILE"
    grep -F 'e2e-smtp-password' <<<"$env_spec" >/dev/null && fail "the extra secret's value is in grafana's service spec"
    grep -F 'GF_SMTP_HOST=smtp.e2e.test:587' <<<"$env_spec" >/dev/null || fail "grafana.extraEnv did not arrive"
    echo "  grafana: extraSecrets as __FILE with no plaintext, extraEnv set"
    wait_for "prometheus: the extra scrape job is up" prom_is 'count(up{job="e2e-extra-scrape"} == 1)' 1
    wait_for "prometheus: the extra rule is loaded" \
      body_has 'e2e:extra_rule:up' in_ns prometheus http://127.0.0.1:9090/api/v1/rules
    ;;
esac
