#!/usr/bin/env bash
#
# e2e smoke check for the swarmcli-cd chart. scripts/e2e-test.sh runs this after the
# release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence only proves the container's own healthcheck passed, and that healthcheck is
# `/swarmcli-cd healthcheck` hitting the UNAUTHENTICATED /healthz — it says something is
# listening and nothing else. What is asserted here is the part of the chart that can be
# wrong while the task is green:
#
#   * the app set the chart mounted is the app set the controller loaded (Mode, and for the
#     static fixtures the application count — a config mounted at the wrong path, or a
#     --config pointing at nothing, is a controller that never sees an application);
#   * a controller whose app set has NOT arrived stays up and retries rather than
#     crash-looping (the dir fixture, whose external volume is deliberately empty);
#   * the admin-token gate is real — a wrong token is refused, so the 200s above are not a
#     controller that started with authorization off (it cannot, but a chart that mounted
#     the wrong secret would look identical from outside).
#
# The probe is the image's own binary, which is a client as well as a server, run inside
# the task: it reads SWARMCLI_CD_ADMIN_TOKEN_FILE from the environment the chart already
# set, so nothing has to be smuggled in here. That also keeps the check working for the
# `none` exposure default, where there is nothing published to curl.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

cid=""
for _ in $(seq 1 20); do
  cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_controller" | sed -n 1p)"
  [ -n "$cid" ] && break
  sleep 3
done
if [ -z "$cid" ]; then
  echo "  FAIL: no running container for ${release}_controller"
  docker service ps "${release}_controller" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi

status=""
for _ in $(seq 1 20); do
  if status="$(docker exec "$cid" /swarmcli-cd status 2>&1)"; then
    break
  fi
  status=""
  sleep 3
done
if [ -z "$status" ]; then
  echo "  FAIL: ${release}_controller never answered 'swarmcli-cd status'"
  docker service logs --tail 60 "${release}_controller" 2>&1 | sed 's/^/    /' || true
  exit 1
fi
printf '%s\n' "$status" | sed 's/^/    /'

# path mode is what --appset-dir reports; every other fixture here is static.
want_mode=static
[ "$case" = "dir" ] && want_mode=path
printf '%s\n' "$status" | grep -E "^Mode +${want_mode}\b" >/dev/null \
  || { echo "  FAIL: expected the app set to load in ${want_mode} mode"; exit 1; }

if [ "$want_mode" = "static" ]; then
  printf '%s\n' "$status" | grep -E '^Applications +1$' >/dev/null \
    || { echo "  FAIL: the mounted applications config declares 1 application, the controller sees another number"; exit 1; }
fi

# The token gate. TOKEN_FILE takes precedence when set, so it is emptied for this call and
# a deliberately wrong token offered in its place; a 0 exit here would mean the API answers
# without a valid credential.
if docker exec -e SWARMCLI_CD_ADMIN_TOKEN_FILE= -e SWARMCLI_CD_ADMIN_TOKEN=not-the-token \
     "$cid" /swarmcli-cd status >/dev/null 2>&1; then
  echo "  FAIL: the API answered a wrong admin token"
  exit 1
fi
echo "    token gate: a wrong admin token is refused"

# published fixture: extraHosts. The rendered `extra_hosts:` key proves nothing on its own
# — `docker stack deploy` rewrites each "<hostname>:<ip>" into SwarmKit's "<ip> <hostname>"
# and silently drops whatever it cannot split at a colon — so the mapping is read back off
# the deployed spec, and then out of the file the container actually resolves against.
if [ "$case" = "published" ]; then
  spec="$(docker service inspect --format '{{ json .Spec.TaskTemplate.ContainerSpec.Hosts }}' "${release}_controller")"
  grep -F '"192.0.2.10 forge.e2e.test"' <<<"$spec" >/dev/null \
    || { echo "  FAIL: the controller's spec carries no host entry for forge.e2e.test (Hosts: $spec)"; exit 1; }
  etc_hosts="$(docker exec "$cid" cat /etc/hosts)"
  grep -E '^192\.0\.2\.10[[:space:]]+forge\.e2e\.test$' <<<"$etc_hosts" >/dev/null \
    || { echo "  FAIL: forge.e2e.test is missing from the task's /etc/hosts"; printf '%s\n' "$etc_hosts" | sed 's/^/    /'; exit 1; }
  echo "    extraHosts: forge.e2e.test resolves to 192.0.2.10 inside the task"
fi

# edge fixture: prove a request routes THROUGH the stood-up traefik edge (issue #63).
# /healthz is the endpoint to use — it is the only one that needs no credential, so what is
# being tested is the routing and not curl's ability to carry a header.
if [ "$case" = "edge" ]; then
  . "$dir/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed swarmcli-cd.e2e.test /healthz 200 || exit 1
  edge_assert_unrouted no-such-host.invalid || exit 1
fi

exit 0
