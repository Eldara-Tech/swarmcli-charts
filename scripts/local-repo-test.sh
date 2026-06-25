#!/usr/bin/env bash
#
# Integration test for the local chart-repo flow (scripts/local-repo.sh).
#
# It stands up the throwaway HTTP repo and drives the real consumer path a
# contributor uses for an UNPUBLISHED chart — `repo add` -> `update` ->
# `search` -> assert each chart is listed as `localrepo/<name>` -> tear down.
# This guards the packaging + index generation + serving that `make e2e`
# (which installs the local chart *directory*) never exercises.
#
# It needs Docker (to run the nginx server) and the swarmcli binary, but NOT a
# Swarm: repo add/update/search only do HTTP + local state, they never deploy.
# That is why this runs on a plain Linux CI runner (see .github/workflows/
# integration.yml) while `make e2e` stays local-only.
#
# A Linux runner shares the Docker daemon's filesystem and forwards published
# ports instantly, so it cannot reproduce the Docker-Desktop/WSL2/rootless quirks
# the serving path guards against — it verifies the flow's *logic*, not every
# environment. The macOS path is confirmed by a maintainer running `make
# local-repo` directly.
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/local-repo-test.sh [chart ...]
#   Defaults to all charts under charts/*.
#   Env: LOCALREPO_PORT  host port for the repo (default 8879)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWARMCLI="${SWARMCLI:-swarmcli}"
PORT="${LOCALREPO_PORT:-8879}"
URL="http://localhost:${PORT}"

command -v docker >/dev/null 2>&1 \
  || { echo "ERROR: docker is required to run the local-repo integration test"; exit 2; }

charts=("$@")
if [ "${#charts[@]}" -eq 0 ]; then
  for d in charts/*/; do charts+=("$(basename "$d")"); done
fi

# The chart name as it lands in index.yaml / search — mirrors local-repo.sh's
# field() so the assertion matches what the server actually published.
chart_name() {
  local n
  n="$(sed -n 's/^name:[[:space:]]*//p' "charts/$1/Chart.yaml" | head -1 | sed 's/^"//; s/"$//' | tr -d '\r')"
  printf '%s' "${n:-$1}"
}

# Isolate swarmcli's repo state in a throwaway dir so the test is reproducible and
# leaves no config behind (swarmcli's chartsStateDir honours XDG_STATE_HOME).
STATE="$(mktemp -d)"
export XDG_STATE_HOME="$STATE"

server_pid=""
cleanup() {
  # Remove the container first: that unblocks the server's `docker logs -f` so it
  # runs its own trap and exits, which `wait` then reaps (no orphan in CI).
  docker rm -f swarmcli-localrepo >/dev/null 2>&1 || true
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$STATE"
}
trap cleanup EXIT INT TERM

# Start the real server (it packages, serves, and blocks) in the background.
LOCALREPO_PORT="$PORT" scripts/local-repo.sh "${charts[@]}" &
server_pid=$!

# Wait until the index is fetchable from the host. (--noproxy: a stray http_proxy
# must not intercept a localhost request.)
ready=
for _ in $(seq 1 30); do
  if curl -fsS --noproxy '*' -o /dev/null "${URL}/index.yaml" 2>/dev/null; then
    ready=1
    break
  fi
  kill -0 "$server_pid" 2>/dev/null || { echo "ERROR: local-repo server exited before serving"; exit 1; }
  sleep 1
done
[ -n "$ready" ] || { echo "ERROR: ${URL}/index.yaml never became reachable"; exit 1; }

fail=0
note() {  # note <PASS|FAIL> <message>
  echo "  $1: $2"
  if [ "$1" = FAIL ]; then fail=1; fi
}

echo "== consumer flow against ${URL} =="
if "$SWARMCLI" charts repo add localrepo "$URL"; then note PASS "repo add"; else note FAIL "repo add"; fi
if "$SWARMCLI" charts repo update;            then note PASS "repo update"; else note FAIL "repo update"; fi

search_out="$("$SWARMCLI" charts search 2>&1 || true)"
printf '%s\n' "$search_out" | sed 's/^/    /'
for chart in "${charts[@]}"; do
  name="$(chart_name "$chart")"
  # Match `localrepo/<name>` bounded by whitespace or end-of-line (POSIX, so it
  # works with BSD grep too) — avoids a prefix matching `localrepo/<name>2`.
  if printf '%s\n' "$search_out" | grep -qE "localrepo/${name}([[:space:]]|\$)"; then
    note PASS "search lists localrepo/${name}"
  else
    note FAIL "search did not list localrepo/${name}"
  fi
done

"$SWARMCLI" charts repo remove localrepo >/dev/null 2>&1 || true

if [ "$fail" -ne 0 ]; then
  echo "local-repo integration test FAILED"
  exit 1
fi
echo "local-repo integration test PASSED"
