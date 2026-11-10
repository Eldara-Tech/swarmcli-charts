#!/usr/bin/env bash
#
# Render assertions for nodeProxy, shared by ci/render-check.sh and
# ci/render-check-distributed.sh for every case that turns it on:
#   $1 = the rendered stack file   $2 = the number of peers (1 = standalone)
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
[ "$(q "$s.entrypoint | join(\" \")")" = "/bin/sh -c" ] \
  && grep -F 'printf '"'"'%s\n'"'"' "$$HAPROXY_CFG" > /tmp/haproxy.cfg; exec haproxy -f /tmp/haproxy.cfg -db' <<<"$(q "$s.command[0]")" >/dev/null \
  || bad "the wrapper does not write \$\$HAPROXY_CFG out and exec haproxy in the foreground"

# The routing: every peer, each checked for readiness, over Docker's DNS.
want="$(if [ "$peers" = 1 ]; then echo 'server ci-rustfs ci-rustfs:9000 check'; else
  for n in $(seq 1 "$peers"); do echo "server ci-rustfs-$n ci-rustfs-$n:9000 check"; done; fi)"
[ "$(grep -E '^ *server ' <<<"$cfg" | sed 's/^ *//')" = "$want" ] \
  || bad "its servers are not exactly every peer by alias on 9000 with a check: $(grep -E '^ *server ' <<<"$cfg" | sed 's/^ *//' | tr '\n' ';')"
for l in 'mode tcp' 'bind :9000' 'option httpchk GET /health/ready' 'http-check expect status 200' \
         'nameserver dns 127.0.0.11:53' 'bind :8405' 'monitor-uri /healthz'; do
  grep -Ex " *$l" <<<"$cfg" >/dev/null || bad "HAPROXY_CFG lacks '$l'"
done
grep -E '^ *default-server .*resolvers docker.* init-addr none' <<<"$cfg" >/dev/null \
  || bad "the servers are not resolved through Docker's DNS, or the proxy cannot start before a peer is in DNS"
if grep -vE '^ *#' <<<"$cfg" | grep -F 'shutdown-sessions' >/dev/null; then bad "a peer that stops being ready would cut the transfers already running on it"; fi
[ "$(q "$s.healthcheck.test | join(\" \")")" = "CMD bash -c exec 3<>/dev/tcp/127.0.0.1/8405" ] \
  || bad "the container healthcheck does not ask the health frontend on 8405"

exit "$fail"
