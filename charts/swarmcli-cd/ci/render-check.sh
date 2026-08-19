#!/usr/bin/env bash
#
# Render-time assertions for the swarmcli-cd chart, run by scripts/test-charts.sh after a
# fixture renders + validates:  $1 = rendered stack file   $2 = fixture case name
# Exit 0 = OK, non-zero = fail. Data-only (no deploy), so it rides charts.yml / make test.
#
# Everything below is a way this chart can render, compose-validate and deploy perfectly
# and still be wrong — the failure landing minutes later as a Pending task or a
# CrashLoop whose log names something else.
set -euo pipefail

out="$1"
case="$2"
fail=0
bad() { echo "  FAIL: $*"; fail=1; }

constraints() { yq -r "(.services.$1.deploy.placement.constraints // [])[]" "$out"; }
nodelabels() { constraints "$1" | grep -E '^node\.labels\.' || true; }

# No check below pipes into `grep -q`: under the `pipefail` above that makes a check
# that DID match report "no match". Match with `| grep … >/dev/null`; a here-string
# (`grep -q … <<<"$x"`) is fine — no pipe, no SIGPIPE. scripts/lint.sh has the why.

# 1. The manager pin is not a value. The controller talks to the swarm's own API, which
#    only a manager serves; on a worker every apply fails, and the task itself looks
#    healthy while it does.
constraints controller | grep -x 'node.role == manager' >/dev/null \
  || bad "the controller carries no 'node.role == manager' constraint — on a worker every apply fails"

# 2. The node pin must never outlive the volume it exists for (#55). With no node-local
#    volume rendered, a pin only strands the task Pending on a label nothing carries.
volumes=$(yq -r '(.volumes // {}) | keys | .[]' "$out")
binds=$(yq -r '(.services.controller.volumes // [])[] | select(test("^/") and (test("docker\\.sock") | not))' "$out")
if [ -z "$volumes" ] && [ -z "$binds" ]; then
  [ -z "$(nodelabels controller)" ] \
    || bad "no volume is rendered, but the controller is still pinned to a node label — it would sit Pending forever"
fi

# 3. Both ends of a shared volume must land on the same node, and a Swarm volume is
#    node-local: a git-sync sidecar scheduled anywhere else publishes the app set onto a
#    volume the controller never reads, and the controller reports an app set that never
#    arrives rather than a placement problem.
if [ "$(yq -r '.services | has("git-sync")' "$out")" = "true" ]; then
  [ "$(nodelabels controller)" = "$(nodelabels git-sync)" ] \
    || bad "controller and git-sync are pinned differently — they can be scheduled onto different nodes and the shared volume is node-local"

  # 4. The sidecar clones a repository. It has no business reaching the daemon.
  yq -r '(.services.git-sync.volumes // [])[]' "$out" | grep 'docker\.sock' >/dev/null \
    && bad "the git-sync sidecar mounts the Docker socket"

  # 5. The controller reads the file the sidecar writes — by the name it writes it under.
  #    These two are set in different halves of the template, and disagreeing is a
  #    controller that starts fine and never finds an app set.
  published=$(yq -r '.services["git-sync"].command[0]' "$out" \
    | sed -n 's|^ *mv -f [^ ]* /out/\(.*\)$|\1|p')
  wanted=$(yq -r '.services.controller.command | to_entries | .[] | select(.value == "--appset-path") | .key + 1' "$out")
  wanted=$(yq -r ".services.controller.command[$wanted]" "$out")
  [ -n "$published" ] && [ "$published" = "$wanted" ] \
    || bad "the sidecar publishes '$published' but the controller reads '$wanted'"
fi

# 6. Static mode: the mounted config and the --config argument are written in two places,
#    and a controller pointed at a path nothing mounted exits before the listener binds.
target=$(yq -r '(.services.controller.configs // [])[0].target // ""' "$out")
if [ -n "$target" ]; then
  cfg=$(yq -r '.services.controller.command | to_entries | .[] | select(.value == "--config") | .key + 1' "$out")
  cfg=$(yq -r ".services.controller.command[$cfg]" "$out")
  [ "$target" = "$cfg" ] \
    || bad "the applications config is mounted at $target but --config says $cfg"
fi

# 7. The admin token only ever arrives as a file path. A token in the environment is a
#    token in `docker service inspect`.
yq -r '(.services.controller.environment // {}) | keys | .[]' "$out" | grep -x 'SWARMCLI_CD_ADMIN_TOKEN' >/dev/null \
  && bad "the admin token is passed as a value — it must be SWARMCLI_CD_ADMIN_TOKEN_FILE"

# 8. extra_hosts is a shape Docker converts, not a string it passes through: `docker stack
#    deploy` splits each entry at the FIRST colon into SwarmKit's "<ip> <hostname>" and
#    DROPS any entry it cannot split (docker/cli convertExtraHosts). A hostname with no
#    address, or the address:hostname order, therefore renders, compose-validates, deploys
#    — and resolves nothing. values.schema.json refuses that shape in the values; this is
#    the same rule asserted on what actually came out.
hosts_of() { yq -r "(.services[\"$1\"].extra_hosts // [])[]" "$out"; }
for svc in $(yq -r '.services | keys | .[]' "$out"); do
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [[ "$entry" =~ ^[^:[:space:]]+:[0-9A-Fa-f.:]+$ ]] \
      || bad "$svc extra_hosts entry '$entry' is not <hostname>:<ip> — docker drops such an entry without saying so"
  done <<<"$(hosts_of "$svc")"
done

# 9. Both halves resolve the same names. In git-sync mode the SIDECAR is what dials the
#    forge — the controller never fetches the app set — so a mapping rendered onto the
#    controller alone leaves the one service that needs it unable to resolve the remote,
#    and the failure arrives as a sidecar retrying a DNS lookup for ever.
if [ "$(yq -r '.services | has("git-sync")' "$out")" = "true" ]; then
  [ "$(hosts_of controller)" = "$(hosts_of git-sync)" ] \
    || bad "controller and git-sync carry different extra_hosts — in git-sync mode the sidecar is what resolves the forge"
fi

# 10. …and the fixtures that exist to exercise all of that must still carry an entry. An
#     extraHosts silently dropped from one of them leaves 8 and 9 passing on empty lists.
case "$case" in
  git-sync | published)
    [ -n "$(hosts_of controller)" ] \
      || bad "the $case fixture sets extraHosts, but nothing rendered onto the controller"
    ;;
esac

# 11. A controller that will not come up must be reverted, not left as the state of the
#     swarm. Swarm's default failure_action is `pause`, and this service is one replica
#     updated stop-first: a bad image pauses the rollout with ZERO controllers running.
#     That is recoverable while a human is running the deploy and not recoverable when the
#     controller deployed ITSELF from the app set, because what would apply the fix is
#     what is gone. Asserted here because it renders, validates and deploys perfectly
#     without it — right up until the one deploy where it matters.
[ "$(yq -r '.services.controller.deploy.update_config.failure_action' "$out")" = "rollback" ] \
  || bad "the controller's update_config.failure_action is not 'rollback' — a bad image would leave the swarm with no controller and no way back"

# 12. TLS on the controller implies an https SWARMCLI_CD_SERVER. The healthcheck is a
#     separate process invocation that knows nothing about --tls-cert: it probes whatever
#     that variable names, defaulting to http://127.0.0.1:8080, and a Go TLS listener
#     answers a plaintext request with 400. Without this the chart renders a controller
#     swarm restarts every interval while it works perfectly, and `docker inspect` says
#     "400 bad request" with nothing about TLS.
cmdline() { yq -r '(.services.controller.command // [])[]' "$out"; }
env_of() { yq -r ".services.controller.environment.$1 // \"\"" "$out"; }

if cmdline | grep -x -- '--tls-cert' >/dev/null; then
  case "$(env_of SWARMCLI_CD_SERVER)" in
    https://*) ;;
    *) bad "the controller serves TLS but SWARMCLI_CD_SERVER is '$(env_of SWARMCLI_CD_SERVER)' — the healthcheck would probe plaintext and swarm would restart a working controller" ;;
  esac

  # 13. …and that both halves of the pair are actually delivered. A flag naming a path
  #     nothing mounts is a controller that exits before its listener binds, which from
  #     outside is indistinguishable from a bad certificate.
  mounted() { yq -r "(.services.controller.secrets // [])[] | (.source // .)" "$out"; }
  for flag in --tls-cert --tls-key; do
    path=$(cmdline | grep -A1 -x -- "$flag" | tail -1)
    name=${path##*/}
    mounted | grep -x "$name" >/dev/null \
      || bad "$flag names /run/secrets/$name but the service mounts no secret '$name'"
  done
fi

# 14. The callback path is the one the controller serves and the one the provider was
#     registered with. A redirect URL ending anywhere else authenticates nobody, and the
#     failure arrives as a provider error page rather than as anything in this stack.
redirect=$(env_of SWARMCLI_CD_OIDC_REDIRECT_URL)
if [ -n "$redirect" ]; then
  case "$redirect" in
    */auth/callback) ;;
    *) bad "SWARMCLI_CD_OIDC_REDIRECT_URL is '$redirect', which does not end in /auth/callback — the controller serves exactly one callback path" ;;
  esac
fi

[ "$fail" -eq 0 ] || exit 1
echo "  placement: manager pin + node pin consistent; secrets by file path; self-update reverts; TLS probe consistent ($case)"
