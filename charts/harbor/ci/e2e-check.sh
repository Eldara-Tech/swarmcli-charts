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
#              overlay, as Prometheus would (the exporter's project count proves its
#              read-only role can read core's tables), and runs promtool on monitoring/;
#   oidc       follows a login to the stub provider's authorization endpoint and checks that
#              CONFIG_OVERWRITE_JSON applied the settings and made them read-only;
#   ha         does what published does, then: two running tasks of each replicated service;
#              keys on the Redis master in every database Harbor uses, which only a client
#              that found the master through the Sentinels writes; pushes and pulls in a loop
#              while core's tasks are replaced one at a time, with none failing; one core and
#              one registry task killed together, pushing and pulling through the rest; and
#              the Redis master stopped, after which a push lands on the new master and a scan
#              succeeds. CI's single node cannot show a node drain: killing tasks stands in.
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
# core's job hooks are unauthenticated: nginx answers them 404, also when a '#' tries to carry
# the path past that location (a variable in proxy_pass would forward it raw).
for t in /service/notifications/tasks/1 '/api/x#/../../service/notifications/tasks/1'; do
  code="$(hcurl -o /dev/null -w '%{http_code}' -X POST --request-target "$t" "$base/")"
  [ "$code" = "404" ] || bad "POST $t answered $code; the job hooks must stay unreachable through nginx"
done

# Has Trivy scan e2e/busybox:<tag>; it downloads its database on the first scan, so this waits
# a while.
scan() {
  local code status art
  code="$(hcurl -o /dev/null -w '%{http_code}' -u "$admin" -X POST "$base/api/v2.0/projects/e2e/repositories/busybox/artifacts/$1/scan")"
  status="not started (HTTP $code)"
  [ "$code" = "202" ] && for _ in $(seq 1 60); do
    art="$(hcurl -u "$admin" "$base/api/v2.0/projects/e2e/repositories/busybox/artifacts/$1?with_scan_overview=true" || true)"
    status="$(sed -n 's/.*"scan_status":"\([A-Za-z]*\)".*/\1/p' <<<"$art")"
    case "$status" in Success|Error|Stopped) break ;; esac
    sleep 5
  done
  if [ "$status" = "Success" ]; then echo "  scan: Trivy finished $1 (Success)"; else bad "the Trivy scan of $1 ended '$status'"; fi
}

if [ "$case" = "published" ] || [ "$case" = "ha" ]; then
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

  scan e2e
fi

if [ "$case" = "ha" ]; then
  rr=harbor-e2e-redis   # the redis chart's release, ci/e2e-setup.sh
  cid_of() { docker ps -q -f "label=com.docker.swarm.service.name=$1" | sed -n 1p; }
  running() { docker service ps "$1" --filter desired-state=running --format '{{.ID}} {{.CurrentState}}' | sed -n 's/ Running.*//p' | sort | tr '\n' ' '; }
  # shellcheck disable=SC2086  # splitting the space-separated task IDs is the point
  count() { set -- $1; echo $#; }
  master() { docker exec "$(cid_of "${rr}_sentinel-1")" redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster | sed -n 1p; }
  # redis-cli on the Redis overlay, from a Sentinel's container; the password is the one the
  # data peers mount.
  rpw="$(docker exec "$(cid_of "${rr}_redis-1")" cat /run/secrets/redis_password)"
  rcli() { local h="$1"; shift; docker exec -e REDISCLI_AUTH="$rpw" "$(cid_of "${rr}_sentinel-1")" redis-cli -h "$h" -p 6379 "$@"; }
  push_pull() {  # pull the image and push it under a new tag; $1 = the tag
    DOCKER_CONFIG="$cfg" docker pull -q "$img" >/dev/null 2>&1 \
      && docker tag "$img" "${img%:*}:$1" \
      && DOCKER_CONFIG="$cfg" docker push -q "${img%:*}:$1" >/dev/null 2>&1 \
      && docker rmi -f "$img" "${img%:*}:$1" >/dev/null 2>&1
  }
  # Layers only in $img, so every pull below fetches them through Harbor again.
  docker rmi -f busybox:1.37 >/dev/null 2>&1 || true

  for s in nginx core portal jobservice registry registryctl; do
    n="$(count "$(running "${release}_$s")")"
    if [ "$n" = 2 ]; then echo "  replicas: ${s} runs 2 tasks"; else bad "${release}_$s runs $n tasks, not 2"; fi
  done

  # A UI login, so core stores a session (database 0).
  code="$(docker run --rm --network host curlimages/curl:latest sh -c '
    curl -s -c /tmp/j -D /tmp/h -o /dev/null "$0/api/v2.0/systeminfo"
    t="$(sed -n "s/^[Xx]-[Hh]arbor-[Cc][Ss][Rr][Ff]-[Tt]oken: *//p" /tmp/h | tr -d "\r")"
    curl -s -b /tmp/j -c /tmp/j -o /dev/null -w "%{http_code}" -H "X-Harbor-CSRF-Token: $t" \
      --data-urlencode principal=admin --data-urlencode "password=$1" "$0/c/login"' "$base" "${admin#admin:}" || true)"
  [ "$code" = "200" ] || bad "the UI login answered '$code'"
  m="$(master)"
  echo "  redis: the Sentinels name $m as the master"
  for d in "0:core's sessions" "1:the registry's blob cache" "2:jobservice's queue" "5:Trivy's store"; do
    n="$(rcli "$m" -n "${d%%:*}" dbsize 2>/dev/null || true)"
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then echo "  redis: database ${d%%:*} on the master holds $n keys (${d#*:})"; else bad "database ${d%%:*} on the master $m is empty (${d#*:}): '$n'"; fi
  done
  blobs="$(rcli "$m" -n 1 --scan --pattern 'blobs::*' | wc -l | tr -d ' ')"
  [ "$blobs" -gt 0 ] || bad "the registry cached no blob descriptor on the master"

  # Core's tasks replaced one at a time, while pushes and pulls keep going: none may fail.
  log="$cfg/loop"; : >"$log"
  ( i=0; while [ ! -e "$log.stop" ]; do i=$((i+1)); if push_pull "loop-$i"; then echo ok; else echo FAIL; fi >>"$log"; done ) &
  loop=$!
  old="$(running "${release}_core")"
  docker service update --detach --force "${release}_core" >/dev/null
  state=""
  for _ in $(seq 1 120); do
    state="$(docker service inspect -f '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' "${release}_core")"
    case "$state" in completed|paused|rollback_*) break ;; esac
    sleep 5
  done
  touch "$log.stop"; wait "$loop" || true
  new="$(running "${release}_core")"
  oks="$(grep -c '^ok$' "$log" || true)"; fails="$(grep -c '^FAIL$' "$log" || true)"
  [ "$state" = "completed" ] || bad "core's forced update ended '$state'"
  for t in $old; do case " $new " in *" $t "*) bad "core task $t survived the forced update" ;; esac; done
  [ "$(count "$new")" = 2 ] || bad "core runs '$new' after the update, not 2 tasks"
  if [ "$fails" = 0 ] && [ "$oks" -gt 0 ]; then echo "  update: $oks push/pulls during core's rolling update, none failed"; else bad "$fails of $((oks + fails)) push/pulls failed during core's rolling update"; fi

  # One core and one registry task killed at once: the others serve. A client retries a
  # request cut off mid-flight, so three tries.
  docker kill "$(cid_of "${release}_core")" "$(cid_of "${release}_registry")" >/dev/null
  ok=0
  for t in 1 2 3; do if push_pull "killed-$t"; then ok=$t; break; fi; sleep 5; done
  if [ "$ok" != 0 ]; then echo "  kill: push/pull worked with a core and a registry task killed (try $ok)"; else bad "push/pull failed three times with a core and a registry task killed"; fi
  for s in core registry; do
    for _ in $(seq 1 60); do [ "$(count "$(running "${release}_$s")")" = 2 ] && break; sleep 5; done
    [ "$(count "$(running "${release}_$s")")" = 2 ] || bad "${release}_$s did not get back to 2 tasks"
  done
  push_pull replaced || bad "push/pull failed once the killed tasks were replaced"

  # The Redis master stopped: the Sentinels promote a replica, and Harbor follows them.
  peer="${rr}_redis-${m##*-}"
  docker service scale --detach "$peer=0" >/dev/null
  m2=""
  for _ in $(seq 1 60); do m2="$(master 2>/dev/null || true)"; [ -n "$m2" ] && [ "$m2" != "$m" ] && break; sleep 3; done
  if [ -n "$m2" ] && [ "$m2" != "$m" ]; then echo "  failover: the Sentinels promoted $m2"; else bad "no failover from $m (master still '$m2')"; fi
  health=""
  for _ in $(seq 1 60); do health="$(hcurl "$base/api/v2.0/health" || true)"; healthy "$health" && break; sleep 5; done
  healthy "$health" || bad "Harbor is not healthy after the failover: $health"
  before="$(rcli "$m2" -n 1 --scan --pattern 'blobs::*' | wc -l | tr -d ' ')"
  # A layer no image had before, so the push writes new descriptors.
  stamp="${release}-e2e-stamp"
  docker rm -f "$stamp" >/dev/null 2>&1 || true
  DOCKER_CONFIG="$cfg" docker pull -q "$img" >/dev/null
  docker run --name "$stamp" "$img" sh -c 'date > /stamp' >/dev/null
  docker commit "$stamp" "${img%:*}:failover" >/dev/null
  docker rm -f "$stamp" >/dev/null
  if DOCKER_CONFIG="$cfg" docker push -q "${img%:*}:failover" >/dev/null; then echo "  failover: pushed ${img%:*}:failover"; else bad "the push after the failover failed"; fi
  after="$(rcli "$m2" -n 1 --scan --pattern 'blobs::*' | wc -l | tr -d ' ')"
  if [ "$after" -gt "$before" ]; then echo "  failover: the registry cached the new blobs on $m2 ($before -> $after)"; else bad "the registry wrote no blob descriptor to the new master $m2 ($before -> $after)"; fi
  scan failover
  docker rmi -f "$img" "${img%:*}:failover" >/dev/null 2>&1 || true
  docker service scale --detach "$peer=1" >/dev/null
fi

if [ "$case" = "metrics" ]; then
  for t in core:harbor_core_ jobservice:harbor_jobservice_ registry:registry_ exporter:harbor_up exporter:harbor_project_total; do
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
