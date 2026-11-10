#!/usr/bin/env bash
#
# Render assertions for nodeProxy, shared by ci/render-check.sh and
# ci/render-check-distributed.sh for every case that turns it on:
#   $1 = the rendered stack file   $2 = the number of peers (1 = standalone)
#   $3 = "shaped" for the fixtures that set nodeProxy.placement and .resources
# Exit 0 = OK.
#
# What a deploy cannot see: a proxy that converges but sends connections to one peer only,
# never checks readiness, or publishes through the routing mesh still reports healthy.
#
# No check pipes into `grep -q` (scripts/lint.sh enforces it): match with `grep … >/dev/null`
# or a here-string.
set -euo pipefail

rendered="${1:?rendered stack file}"
peers="${2:?number of peers}"
shaped="${3:-}"

fail=0
bad() { echo "    FAIL(nodeProxy): $*" >&2; fail=1; }
s='.services."rustfs-node-proxy"'
q() { yq -r "$1" "$rendered"; }

[ "$(q "$s")" != "null" ] || { bad "nodeProxy.enabled renders no rustfs-node-proxy service"; exit 1; }
cfg="$(q "$s.environment.HAPROXY_CFG")"

[ "$(q "$s.image")" = "haproxy:3.4" ] || bad "the image is '$(q "$s.image")', not nodeProxy.image (haproxy:3.4)"
[ "$(q "$s.deploy.mode")" = "global" ] || bad "it is not a global service, so not every node gets a task"
[ "$(q "$s.deploy.update_config.order")" = "stop-first" ] \
  || bad "its update is not stop-first; the new task cannot bind the node's port while the old one holds it"
[ "$(q "$s.ports | map(.target + \":\" + .published + \":\" + .mode + \":\" + .protocol) | join(\" \")")" = "9000:9002:host:tcp" ] \
  || bad "it does not publish 9002 -> 9000 in host mode alone (got: $(q "$s.ports | map(.target + \":\" + .published + \":\" + .mode) | join(\" \")"))"
[ "$(q "$s.networks | keys | join(\" \")")" = "rustfs-net" ] \
  || bad "it joins '$(q "$s.networks | keys | join(" ")")', not network.name alone"
[ "$(q "$s.networks.\"rustfs-net\".aliases")" = "null" ] \
  || bad "it carries a network alias; the peers' alias on it would resolve to the proxy as well"
[ "$(q "$s.deploy.labels")" = "null" ] || bad "it carries deploy labels, Traefik's or the chart's labels"
if [ "$shaped" = shaped ]; then
  [ "$(q "$s.deploy.placement.constraints | join(\",\")")" = "node.labels.geesefs == true" ] \
    || bad "nodeProxy.placement.constraints is not its placement (got '$(q "$s.deploy.placement.constraints")')"
  [ "$(q "$s.deploy.resources.limits.memory")" = "64M" ] || bad "nodeProxy.resources.limits.memory is not its memory limit"
else
  [ "$(q "$s.deploy.placement")" = "null" ] && [ "$(q "$s.deploy.resources")" = "null" ] \
    || bad "it is placed or limited although nodeProxy.placement and .resources are empty"
fi
[ "$(q "$s.entrypoint | join(\" \")")" = "/bin/sh -c" ] \
  && grep -F 'printf '"'"'%s\n'"'"' "$$HAPROXY_CFG" > /tmp/haproxy.cfg; exec haproxy -f /tmp/haproxy.cfg -db' <<<"$(q "$s.command[0]")" >/dev/null \
  || bad "the wrapper does not write \$\$HAPROXY_CFG out and exec haproxy in the foreground"

# The routing: every peer by its task's own address, each checked for readiness, over
# Docker's DNS.
want="$(if [ "$peers" = 1 ]; then echo 'server rustfs tasks.ci_rustfs:9000 check'; else
  for n in $(seq 1 "$peers"); do echo "server rustfs-$n tasks.ci_rustfs-$n:9000 check"; done; fi)"
[ "$(grep -E '^ *server ' <<<"$cfg" | sed 's/^ *//')" = "$want" ] \
  || bad "its servers are not exactly every peer's task on 9000 with a check: $(grep -E '^ *server ' <<<"$cfg" | sed 's/^ *//' | tr '\n' ';')"
for l in 'mode tcp' 'bind :9000' 'option httpchk GET /health/ready' 'http-check expect status 200' \
         'nameserver dns 127.0.0.11:53' 'bind :8405' 'monitor-uri /healthz' 'option dontlognull' \
         'timeout connect 1s' 'retries 3' 'option redispatch 1'; do
  grep -Ex " *$l" <<<"$cfg" >/dev/null || bad "HAPROXY_CFG lacks '$l'"
done
d="$(grep -E '^ *default-server ' <<<"$cfg" || true)"
for w in 'observe layer4 error-limit 1 on-error mark-down' 'on-marked-down shutdown-sessions' 'resolvers docker' 'init-addr none'; do
  grep -F " $w" <<<"$d" >/dev/null || bad "default-server lacks '$w'"
done
[ "$(q "$s.healthcheck.test | join(\" \")")" = "CMD bash -c exec 3<>/dev/tcp/127.0.0.1/8405" ] \
  || bad "the container healthcheck does not ask the health frontend on 8405"

exit "$fail"
