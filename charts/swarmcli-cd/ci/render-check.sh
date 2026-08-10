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

[ "$fail" -eq 0 ] || exit 1
echo "  placement: manager pin + node pin consistent; secrets by file path ($case)"
