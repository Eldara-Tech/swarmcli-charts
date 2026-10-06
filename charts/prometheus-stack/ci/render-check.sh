#!/usr/bin/env bash
#
# Render-time assertions for the prometheus-stack chart, run by scripts/test-charts.sh after a
# fixture renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so every fixture is checked here,
# including the ones e2e never deploys.
#
# What a render can get silently wrong and a deploy would not report:
#   * a shipped config under a stable name, which turns the next edit into a failed upgrade;
#   * the template driver on a rule file, where Swarm would eat the $labels templates;
#   * who holds the Docker socket and the host's root filesystem. The security scan cannot
#     see a `/` bind at all, and flags a socket without saying where it is;
#   * the socket-proxy's reach: managers only, alone with Prometheus on an internal overlay,
#     one anchored allow-list entry per path, callers limited to Prometheus's own tasks;
#   * which components sit on the ingress overlay, and where basic auth lands;
#   * peer addresses: a short alias on a shared overlay can resolve to another stack's service;
#   * the discovery job's two gates on the chart's own prometheus.yml (see the end).
#
# Expectations come from the CASE NAME, not from the render, so a template that stops
# honouring a value cannot make its own check pass.
set -euo pipefail

out="$1"
case="${2:-}"
rel="${RELEASE:-ci}"
dir="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
bad() { echo "  FAIL($case): $*"; fail=1; }

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -i mikefarah >/dev/null; then
  echo "  FAIL: mikefarah yq v4 is required by the prometheus-stack render checks" >&2
  exit 1
fi

# No check pipes into `grep -q` (a match reads as no match under pipefail; scripts/lint.sh
# has the why). Values are collected first and matched with here-strings.
q() { yq -r "$1" "$out"; }
has_svc() { [ "$(q ".services | has(\"$1\")")" = "true" ]; }
lines() { q "$1 // [] | .[]"; }
contains() { grep -xF -- "$2" <<<"$1" >/dev/null; }

# ------------------------------------------------------------------ expectations
on=1; persist=1; gf_mode=traefik; prom_routed=0; am_routed=0; loki=0
case "$case" in
  minimal) on=0; gf_mode=off ;;
  ephemeral) persist=0 ;;
  published) gf_mode=published ;;
  edge) prom_routed=1 ;;
  extras) am_routed=1 ;;
  loki) loki=1 ;;
esac

for svc in prometheus alertmanager grafana node-exporter cadvisor socket-proxy; do
  want=$on; [ "$svc" = prometheus ] && want=1
  if has_svc "$svc"; then got=1; else got=0; fi
  [ "$got" = "$want" ] || bad "service $svc rendered=$got, expected $want"
done

# ------------------------------------------------ configs: rotation and the driver
# A file the chart ships is named after the chart version; a file the operator supplies
# (values/) after its content. Either way new content means a new name.
cfgs="$(q '.configs // {} | to_entries | .[] | .value.file + " " + .value.name')"
while read -r file name; do
  [ -n "$file" ] || continue
  case "$file" in
    files/*) [[ "$name" =~ ^${rel}_[a-z-]+_[0-9]+\.[0-9]+\.[0-9]+$ ]] \
               || bad "config from $file is named '$name', not <release>_<x>_<semver>" ;;
    values/*) [[ "$name" =~ ^${rel}_[a-z0-9-]+_[0-9a-f]{12}$ ]] \
               || bad "config from $file is named '$name', not <release>_<x>_<12 hex>" ;;
    *) bad "config from '$file' is neither a chart file nor an operator value" ;;
  esac
done <<<"$cfgs"
case "$case" in
  extras) want_values="values/prometheus.extraRules.e2e values/prometheus.extraRules.e2e-second
                       values/prometheus.extraScrapeConfigs.e2e values/grafana.dashboards.e2e" ;;
  alertmanager-config) want_values="values/alertmanager.config" ;;
  *) want_values="" ;;
esac
for v in $want_values; do
  contains "$(q '.configs[].file')" "$v" || bad "the operator's $v is not mounted"
done

# Each exporter's absent-alert file is mounted exactly while the exporter is enabled: without
# it an exporter that vanishes goes unnoticed, and with its exporter off it fires forever.
rules="$(q '.services.prometheus.configs[] | .source + ">" + .target')"
for pair in "node-exporter:prometheus-rules-node-exporter>/etc/prometheus/rules/node-exporter.yml" \
            "cadvisor:prometheus-rules-cadvisor>/etc/prometheus/rules/cadvisor.yml"; do
  if contains "$rules" "${pair#*:}"; then got=1; else got=0; fi
  [ "$got" = "$on" ] || bad "the ${pair%%:*} absent-alert rule file mounted=$got, expected $on"
done
# The Galera rules ship in every configuration: they are inert without mysqld_exporter
# targets (asserted on the file below), and nobody remembers to switch alerts on.
contains "$rules" "prometheus-rules-galera>/etc/prometheus/rules/galera.yml" \
  || bad "prometheus does not mount the Galera rule file"

# Each operator entry is mounted under its own key, and the operator's dashboards bring a
# provider of their own, mounted only while there is a dashboard for it to provide.
gconfs="$(q '.services.grafana.configs // [] | .[] | .source + ">" + .target')"
if [ "$case" = extras ]; then
  for m in "prometheus-extra-rules-e2e>/etc/prometheus/rules/extra-e2e.yml" \
           "prometheus-extra-rules-e2e-second>/etc/prometheus/rules/extra-e2e-second.yml" \
           "prometheus-extra-scrape-e2e>/etc/prometheus/scrape/extra-e2e.yml"; do
    contains "$rules" "$m" || bad "prometheus does not mount $m"
  done
  for m in "grafana-dashboards-extra>/etc/grafana/provisioning/dashboards/extra.yml" \
           "dashboard-extra-e2e>/etc/grafana/dashboards-extra/e2e.json"; do
    contains "$gconfs" "$m" || bad "grafana does not mount $m"
  done
else
  grep -F 'grafana-dashboards-extra>' <<<"$gconfs" >/dev/null \
    && bad "the extra dashboard provider is mounted with no dashboard to provide"
fi
if [ "$gf_mode" != off ]; then
  contains "$gconfs" "dashboard-galera>/etc/grafana/dashboards/galera.json" \
    || bad "grafana does not mount the Galera dashboard"
fi

# Only prometheus.yml is rendered by Swarm: the rule files contain $labels templates that
# the golang driver would evaluate.
[ "$(q '[.configs // {} | to_entries | .[] | select(.value.template_driver) | .key] | join(",")')" = "prometheus-config" ] \
  || bad "template_driver is set on something other than exactly prometheus-config"
[ "$(q '.configs.prometheus-config.template_driver + " " + .configs.prometheus-config.file')" = "golang files/prometheus/prometheus.yml" ] \
  || bad "prometheus-config is not files/prometheus/prometheus.yml under the golang driver"

# ----------------------------------------------------- Docker API and host access
sock="$(q '[.services | to_entries | .[] | select((.value.volumes // []) | map(select(test("docker\.sock"))) | length > 0) | .key] | sort | join(",")')"
if [ "$on" = 1 ]; then
  [ "$sock" = "cadvisor,socket-proxy" ] || bad "the Docker socket is mounted by [$sock], expected exactly [cadvisor,socket-proxy]"
else
  [ "$sock" = "" ] || bad "the Docker socket is mounted by [$sock] with discovery and the exporters off"
fi
csock="$(q '[.services | to_entries | .[] | select((.value.volumes // []) | map(select(test("containerd\.sock"))) | length > 0) | .key] | join(",")')"
[ "$csock" = "$( [ "$on" = 1 ] && echo cadvisor)" ] || bad "the containerd socket is mounted by [$csock]"
# The host binds of the three services that hold any, compared WHOLE: source, target and
# mode. A dropped `:ro` (`/:/host:rslave` is the host root read-write), a widened source
# or an extra bind all fail here. /var/lib/docker is the other half of the storage-driver
# split: on overlay2 cAdvisor reads each container's layer there and drops every
# container it cannot (seen in CI).
want_binds() {  # want_binds <service> <expected bind>...
  local svc="$1" got want
  shift
  got="$(lines ".services.$svc.volumes" | sort)"
  want="$(printf '%s\n' "$@" | sort)"
  [ "$got" = "$want" ] || bad "$svc binds [$(tr '\n' ' ' <<<"$got")], expected exactly [$(tr '\n' ' ' <<<"$want")]"
}
if [ "$on" = 1 ]; then
  want_binds node-exporter "/:/host:ro,rslave"
  want_binds cadvisor "/var/run/docker.sock:/var/run/docker.sock:ro" \
    "/run/containerd/containerd.sock:/run/containerd/containerd.sock:ro" \
    "/var/lib/docker:/rootfs/var/lib/docker:ro" "/sys:/sys:ro" "/proc:/rootfs/proc:ro"
  want_binds socket-proxy "/var/run/docker.sock:/var/run/docker.sock:ro"
fi

# node-exporter's bind of the host's whole root filesystem. The security scan cannot see it.
root="$(q '[.services | to_entries | .[] | select((.value.volumes // []) | map(select(test("^/:"))) | length > 0) | .key] | join(",")')"
[ "$root" = "$( [ "$on" = 1 ] && echo node-exporter)" ] || bad "a / bind is on [$root]"

if [ "$case" = minimal ]; then
  grep -F 'docker.sock' "$out" >/dev/null && bad "minimal still references a Docker socket"
  hostbinds="$(q '.services[].volumes // [] | .[] | select(test("^/"))')"
  [ -z "$hostbinds" ] || bad "minimal still binds host paths: $(tr '\n' ' ' <<<"$hostbinds")"
fi

if [ "$on" = 1 ]; then
  [ "$(q '.services.socket-proxy.deploy.placement.constraints | join(",")')" = "node.role == manager" ] \
    || bad "the socket-proxy is not constrained to node.role == manager (only)"
  [ "$(q '.services.socket-proxy.networks | join(",")')" = "discovery" ] \
    || bad "the socket-proxy is on networks other than [discovery]"
  [ "$(q '.networks.discovery.internal')" = "true" ] \
    || bad "the discovery overlay is not internal: true"
  pcmd="$(lines '.services.socket-proxy.command')"
  # The caller check matches client IPs, which only works with dnsrr (a VIP hides them).
  contains "$pcmd" "-allowfrom=tasks.${rel}_prometheus" || bad "the socket-proxy does not admit only tasks.${rel}_prometheus"
  [ "$(q '.services.socket-proxy.deploy.endpoint_mode')" = "dnsrr" ] || bad "the socket-proxy is not endpoint_mode dnsrr"
  # One anchored regex per path, compared literally: a combined alternation let a logs
  # path through (spike S2), and any other method or path widens the proxy.
  allows="$(grep -E '^-allow' <<<"$pcmd" || true)"
  want_allows="$(printf '%s\n' '-allowfrom=tasks.'"$rel"'_prometheus' \
    '-allowGET=/v1\.[0-9]+/tasks' '-allowGET=/v1\.[0-9]+/services' \
    '-allowGET=/v1\.[0-9]+/nodes' '-allowGET=/v1\.[0-9]+/networks' \
    '-allowGET=/_ping' '-allowHEAD=/_ping')"
  [ "$allows" = "$want_allows" ] || bad "the socket-proxy allow-list is not exactly the expected seven lines: $(tr '\n' ' ' <<<"$allows")"
  [ "$(q '.services.node-exporter.hostname')" = '{{.Node.Hostname}}' ] \
    || bad "node-exporter's hostname is not the literal {{.Node.Hostname}} Swarm template"
fi

# Every service with a healthcheck keeps Swarm watching its rollout for at least as long as
# the healthcheck needs to fail (start_period + interval x retries). Swarm's default
# monitor is 5s, and past it an unhealthy task no longer fails the deploy.
dur_s() {  # "1m30s" -> 90; prints -1 for anything it cannot read
  local d="$1" t=0 n
  while [[ $d =~ ^([0-9]+)(h|m|s)(.*)$ ]]; do
    n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in h) t=$((t + n * 3600)) ;; m) t=$((t + n * 60)) ;; s) t=$((t + n)) ;; esac
    d="${BASH_REMATCH[3]}"
  done
  if [ -z "$d" ]; then echo "$t"; else echo -1; fi
}
for svc in $(q '.services | to_entries | .[] | select(.value.healthcheck) | .key'); do
  hc="$(q ".services.\"$svc\".healthcheck | (.start_period // \"0s\") + \" \" + .interval + \" \" + (.retries | tostring)")"
  read -r start interval retries <<<"$hc"
  need=$(( $(dur_s "$start") + $(dur_s "$interval") * retries ))
  mon="$(q ".services.\"$svc\".deploy.update_config.monitor // \"5s\"")"
  [ "$(dur_s "$mon")" -ge "$need" ] \
    || bad "$svc: update_config.monitor is $mon, shorter than the ${need}s its healthcheck needs to fail"
done

# Nothing exposes Prometheus's lifecycle, admin or remote-write endpoints.
grep -E -- '--web\.enable-(lifecycle|admin-api|remote-write-receiver)' "$out" >/dev/null \
  && bad "a --web.enable-* flag is rendered"

# ------------------------------------------------------------------ persistence
pin="node.labels.prometheus-stack-data == true"
for svc in prometheus alertmanager grafana; do
  has_svc "$svc" || continue
  cons="$(lines ".services.$svc.deploy.placement.constraints")"
  if [ "$persist" = 1 ]; then
    contains "$cons" "$pin" || bad "$svc is not pinned to the data node"
  else
    [ -z "$cons" ] || bad "$svc keeps a placement constraint with persistence off: $cons"
    [ -z "$(lines ".services.$svc.volumes")" ] || bad "$svc mounts a volume with persistence off"
  fi
done
for svc in node-exporter cadvisor; do
  has_svc "$svc" || continue
  [ "$(q ".services.$svc.deploy.placement.constraints | join(\",\")")" = "node.platform.os == linux" ] \
    || bad "$svc (global) carries a constraint other than node.platform.os == linux"
done
if [ "$case" = bind-mount ]; then
  for pair in prometheus:/prometheus alertmanager:/alertmanager grafana:/var/lib/grafana; do
    svc="${pair%%:*}"
    contains "$(lines ".services.$svc.volumes")" "/tmp/prometheus-stack-e2e/$svc:${pair#*:}" \
      || bad "$svc is not bind-mounted from its volumePath"
  done
  [ "$(q '.volumes // "none"')" = "none" ] || bad "host-path persistence still declared named volumes"
fi

# ------------------------------------------------------------ exposure and routers
tp="traefik-public"
on_net() { contains "$(lines ".services.$1.networks")" "$2"; }
labels_of() { lines ".services.$1.deploy.labels"; }
for svc in prometheus alertmanager grafana; do
  has_svc "$svc" || continue
  case "$svc" in
    prometheus) routed=$prom_routed ;;
    alertmanager) routed=$am_routed ;;
    grafana) routed=0; [ "$gf_mode" = traefik ] && routed=1 ;;
  esac
  l="$(labels_of "$svc")"
  r="${rel}-${svc}"
  if [ "$routed" = 0 ]; then
    on_net "$svc" "$tp" && bad "$svc is not routed but sits on $tp"
    grep -F 'traefik.' <<<"$l" >/dev/null && bad "$svc is not routed but carries Traefik labels"
    continue
  fi
  on_net "$svc" "$tp" || bad "$svc is routed but not on $tp"
  # Every router this service defines is <release>-<component>-(http|https).
  routers="$(sed -nE 's/^traefik\.http\.routers\.([^.]+)\..*/\1/p' <<<"$l" | sort -u)"
  while read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$r-http" ] || [ "$name" = "$r-https" ] || bad "$svc defines router '$name', not $r-http/-https"
  done <<<"$routers"
  tls="$(q ".services.$svc.deploy.labels // [] | map(select(test(\"^traefik.http.routers.$r-https.tls=true\"))) | length")"
  auth="$(grep -E "^traefik\.http\.routers\.[^.]+\.middlewares=$r-auth$" <<<"$l" || true)"
  if [ "$svc" = grafana ]; then
    [ -z "$auth" ] || bad "grafana carries a basic-auth middleware; it authenticates itself"
  elif [ "$tls" = 1 ]; then
    [ "$auth" = "traefik.http.routers.$r-https.middlewares=$r-auth" ] || bad "$svc basic auth is not on (only) the public HTTPS router"
    contains "$l" "traefik.http.routers.$r-http.middlewares=https-redirect" || bad "$svc HTTP router does not redirect"
  else
    [ "$auth" = "traefik.http.routers.$r-http.middlewares=$r-auth" ] || bad "$svc basic auth is not on the public HTTP router"
  fi
done
# Routers are distinct across components: one name owned by two services is a collision.
dups="$(q '.services[].deploy.labels // [] | .[]' | sed -nE 's/^traefik\.http\.routers\.([^.]+)\.rule=.*/\1/p' | sort | uniq -d)"
[ -z "$dups" ] || bad "router names collide across services: $dups"

if has_svc grafana; then
  if [ "$loki" = 1 ]; then on_net grafana monitoring || bad "the Loki datasource is on but grafana is not on monitoring"
  else on_net grafana monitoring && bad "grafana is on monitoring without the Loki datasource"; fi
  ports="$(q '.services.grafana.ports // [] | length')"
  if [ "$gf_mode" = published ]; then
    [ "$(q '.services.grafana.ports[0].published')" = "3000" ] || bad "published mode does not publish 3000"
  else
    [ "$ports" = 0 ] || bad "grafana publishes a port outside published mode"
  fi
fi
[ "$case" != minimal ] && { on_net prometheus monitoring || bad "prometheus is not on monitoring"; }

# ------------------------------------------------------------ secrets and peers
if has_svc grafana; then
  genv="$(q '.services.grafana.environment | to_entries | .[] | .key + "=" + .value')"
  contains "$genv" "GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password" || bad "grafana does not read its admin password from the secret"
  contains "$genv" "GF_SECURITY_SECRET_KEY__FILE=/run/secrets/grafana_secret_key" || bad "grafana does not read its secret key from the secret"
  # Nothing credential-shaped is set in plain: every such key must be a __FILE.
  plain="$(grep -E '^[A-Z0-9_]*(PASSWORD|SECRET|SECRET_KEY|TOKEN)=' <<<"$genv" || true)"
  [ -z "$plain" ] || bad "grafana sets a credential in plain environment: $plain"
  if [ "$case" = extras ]; then
    contains "$genv" "GF_SMTP_PASSWORD__FILE=/run/secrets/prometheus-stack-e2e-smtp" || bad "extraSecrets did not become GF_SMTP_PASSWORD__FILE"
  fi
  contains "$genv" "PROMSTACK_PROMETHEUS_URL=http://${rel}_prometheus:9090" || bad "grafana does not address Prometheus by its full name"
  contains "$genv" "GF_SNAPSHOTS_EXTERNAL_ENABLED=false" || bad "grafana may publish snapshots to an external service"
  # Secure cookies exactly where users arrive over TLS: routed with tls. On plain HTTP a
  # secure cookie is never sent back and nobody can log in.
  cookie="$(grep -E '^GF_SECURITY_COOKIE_SECURE=' <<<"$genv" || true)"
  if [ "$gf_mode" = traefik ] && [ "$case" != edge ]; then
    [ "$cookie" = "GF_SECURITY_COOKIE_SECURE=true" ] || bad "grafana is routed over TLS without secure cookies"
  else
    [ -z "$cookie" ] || bad "grafana sets $cookie without TLS in front of it"
  fi
  if [ "$on" = 1 ]; then
    contains "$genv" "PROMSTACK_ALERTMANAGER_URL=http://${rel}_alertmanager:9093" || bad "grafana does not address Alertmanager by its full name"
  fi
fi
penv="$(q '.services.prometheus.environment | to_entries | .[] | .key + "=" + .value')"
if [ "$on" = 1 ]; then
  contains "$penv" "PROMSTACK_ALERTMANAGER=${rel}_alertmanager:9093" || bad "prometheus does not address Alertmanager by its full name"
  contains "$penv" "PROMSTACK_SD_HOST=tcp://${rel}_socket-proxy:2375" || bad "prometheus does not address the socket-proxy by its full name"
else
  grep -E '^PROMSTACK_(ALERTMANAGER|SD_HOST)=' <<<"$penv" >/dev/null && bad "prometheus is handed a peer that is not deployed"
fi
if [ "$case" = discovery ]; then
  contains "$penv" "PROMSTACK_SCRAPE_NETWORKS=${rel}_internal|monitoring|prometheus-stack-e2e-extra" \
    || bad "the discovery job does not keep exactly the stack overlay, monitoring and the extra network"
  on_net prometheus prometheus-stack-e2e-extra || bad "prometheus did not join prometheus.extraNetworks"
fi
# No in-stack peer by its short alias, in any service. The Loki URL is the operator's.
short="$(q '.services[].environment // {} | to_entries | .[] | select(.key != "PROMSTACK_LOKI_URL") | .value' \
  | grep -E '(^|[/@])(prometheus|alertmanager|grafana|socket-proxy|node-exporter|cadvisor):[0-9]' || true)"
[ -z "$short" ] || bad "a peer is addressed by its short alias: $short"
# The same in every file the chart ships.
short="$(grep -rnE '(^|[^A-Za-z0-9_.-])(prometheus|alertmanager|grafana|socket-proxy|node-exporter|cadvisor):[0-9]' \
  "$dir/files" || true)"
[ -z "$short" ] || bad "a shipped file addresses a peer by its short alias: $short"

# ------------------------------------------- the discovery job, on the file itself
# Only the golang driver can evaluate prometheus.yml, so no render shows the job. Check
# the chart's file directly. The label filter keeps every non-opted-in task out of
# Prometheus server-side; the relabel keep still gates if the filter is ever mistyped.
# e2e cannot see the second while the first works.
pf="$dir/files/prometheus/prometheus.yml"
job='.scrape_configs[] | select(.job_name == "swarm-tasks")'
filter="$(yq -r "$job | .dockerswarm_sd_configs[].filters // [] | .[] | select(.name == \"label\") | .values[]" "$pf")"
contains "$filter" "prometheus.io/scrape=true" || bad "$pf: swarm-tasks has no label filter on prometheus.io/scrape=true"
keep="$(yq -r "$job | .relabel_configs[] | select(.action == \"keep\" and .regex == \"true\") | .source_labels | join(\",\")" "$pf")"
contains "$keep" "__meta_dockerswarm_service_label_prometheus_io_scrape" || bad "$pf: swarm-tasks has no relabel keep on prometheus_io_scrape"
# The stack label is how the Galera rules and dashboard tell one cluster from another.
[ "$(yq -r "$job | .relabel_configs[] | select(.target_label == \"stack\") | .source_labels | join(\",\")" "$pf")" \
  = "__meta_dockerswarm_service_label_com_docker_stack_namespace" ] \
  || bad "$pf: swarm-tasks does not set stack from com.docker.stack.namespace"

# Shipped unconditionally, so the Galera rules must stay inert on a swarm with no MySQL:
# an absent() there would fire forever. And every dashboard query is scoped to the
# selected cluster, or two releases' peers would mix in one panel.
gr="$dir/files/prometheus/rules/galera.yml"
yq -r '.groups[].rules[].expr' "$gr" | grep -F 'absent(' >/dev/null \
  && bad "$gr uses absent(); it ships to every stack, so it would fire with no MySQL"
gd="$dir/files/grafana/dashboards/galera.json"
unscoped="$(yq -p json -o yaml -r '.. | select(tag == "!!map" and has("expr")) | .expr' "$gd" | grep -vF 'stack="$stack"' || true)"
[ -z "$unscoped" ] || bad "$gd has queries not scoped to the selected cluster: $unscoped"

# The operator's dashboard provider reads exactly the directory they are mounted in, with
# deletion on: removing an entry from the values must remove the dashboard from Grafana.
xp="$dir/files/grafana/dashboards-extra.yml"
[ "$(yq -r '(.providers | length | tostring) + " " + .providers[0].options.path + " " + (.providers[0].disableDeletion | tostring)' "$xp")" \
  = "1 /etc/grafana/dashboards-extra false" ] \
  || bad "$xp is not one provider of /etc/grafana/dashboards-extra with deletion on"

[ "$fail" -eq 0 ] || exit 1
echo "  $case: render assertions OK"
