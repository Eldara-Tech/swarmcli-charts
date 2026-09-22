#!/usr/bin/env bash
#
# e2e smoke check for the gitlab-runner chart. scripts/e2e-test.sh runs this once the
# release has converged:
#   $1 = release name (== Docker stack name)   $2 = chart directory   $3 = fixture case
# Exit 0 = healthy, non-zero = failure.
#
# Convergence is a weak signal for this chart and the checks below exist because of it: a
# runner with an EMPTY token, a bogus token or an unresolvable url starts, mints a system
# ID and sits there reporting Running. So every case asserts what the container actually
# wrote and what the swarm actually holds, and the `mock` case goes further — it stands up
# a mock GitLab on this release's own overlay and reads back the token the runner presented,
# which is the only way to prove the whole path: Swarm secret -> RUNNER_TOKEN ->
# ${RUNNER_TOKEN} in config.toml -> authenticated API call.
#
# No check pipes into `grep -q`: under the `pipefail` below that turns a check that DID
# match into "no match" (scripts/lint.sh enforces this repo-wide). `docker logs` output can
# also lag the process, so log assertions capture to a file and retry rather than reading
# a stream once.
set -euo pipefail

release="$1"
dir="$2"
case="${3:-}"

svc="${release}_gitlab-runner"
fail=0
bad() { echo "  FAIL: $*" >&2; fail=1; }
note() { echo "  $*"; }

runner_cid() {
  docker ps -q -f "label=com.docker.swarm.service.name=${svc}" | sed -n 1p
}

# ── the task must be up, with its config written ──────────────────────────────────────
cid=""
for _ in $(seq 1 30); do
  cid="$(runner_cid)"
  [ -n "$cid" ] && break
  sleep 2
done
if [ -z "$cid" ]; then
  bad "no running container for service $svc"
  docker service ps "$svc" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi

# The container generates config.toml at start; if the wrapper died, this is empty.
config=""
for _ in $(seq 1 20); do
  config="$(docker exec "$cid" cat /etc/gitlab-runner/config.toml 2>/dev/null || true)"
  [ -n "$config" ] && break
  sleep 2
done
[ -n "$config" ] || bad "/etc/gitlab-runner/config.toml is missing or empty inside the container"

# "Configuration loaded" is the runner's own word for "the TOML I was given parsed".
logfile="$(mktemp)"
loaded=0
for _ in $(seq 1 30); do
  docker service logs --raw "$svc" > "$logfile" 2>&1 || docker logs "$cid" > "$logfile" 2>&1 || true
  if grep -aF 'Configuration loaded' "$logfile" >/dev/null; then
    loaded=1
    break
  fi
  sleep 2
done
if [ "$loaded" -ne 1 ]; then
  bad "the runner never logged 'Configuration loaded' — the generated config.toml did not parse"
  sed -n '1,25p' "$logfile" | sed 's/^/    /'
fi

# ── the token must have reached the file as a reference, and the file as a value ──────
token="$(docker exec "$cid" cat /run/secrets/gitlab-runner-token 2>/dev/null || true)"
[ -n "$token" ] || bad "the token secret is not mounted in the container"
# The manifest side of the contract: the service spec must carry the reference, never the
# secret's contents. This is the assertion that would catch a `$`-escaping regression.
spec="$(docker service inspect "$svc" 2>/dev/null || true)"
if [ -n "$token" ] && grep -aF "$token" <<<"$spec" >/dev/null; then
  bad "the token's plaintext appears in the service spec — it must only ever be a secret reference"
fi
grep -aF '${RUNNER_TOKEN}' <<<"$config" >/dev/null \
  || bad "config.toml does not carry the \${RUNNER_TOKEN} reference the runner expands at load"

# ── cache credentials are appended by the container, not rendered into the manifest ───
if [ "$case" = "cache" ]; then
  access="$(docker exec "$cid" cat /run/secrets/gitlab-runner-cache-access-key 2>/dev/null || true)"
  secret="$(docker exec "$cid" cat /run/secrets/gitlab-runner-cache-secret-key 2>/dev/null || true)"
  [ -n "$access" ] && [ -n "$secret" ] || bad "the cache credential secrets are not mounted"
  if [ -n "$access" ]; then
    grep -aF "AccessKey = '$access'" <<<"$config" >/dev/null \
      || bad "config.toml has no AccessKey line for the mounted access key — the append step did not run"
    if grep -aF "$access" <<<"$spec" >/dev/null; then
      bad "the cache access key's plaintext appears in the service spec"
    fi
  fi
  if [ -n "$secret" ]; then
    # The e2e secret deliberately contains / and +, the characters a real base64 secret key
    # carries: this is what proves the TOML literal-string quoting holds.
    grep -aF "SecretKey = '$secret'" <<<"$config" >/dev/null \
      || bad "config.toml has no SecretKey line matching the mounted secret key"
    if grep -aF "$secret" <<<"$spec" >/dev/null; then
      bad "the cache secret key's plaintext appears in the service spec"
    fi
  fi
  # The appended keys must sit under the s3 table, or the runner reads them as something
  # else entirely (it ignores keys it does not recognise, silently).
  tail_table="$(grep -aE '^ *\[+runners' <<<"$config" | sed -n '$p' | sed 's/^ *//')"
  [ "$tail_table" = "[runners.cache.s3]" ] \
    || bad "the last table before the appended credentials is '$tail_table', not [runners.cache.s3]"
  note "cache: credentials appended under [runners.cache.s3], absent from the service spec"
fi

# ── the mock case: prove the runner really authenticates with that token ──────────────
if [ "$case" = "mock" ]; then
  # The mock joins THIS release's overlay, which only exists now that the stack is up.
  docker service rm mock-gitlab >/dev/null 2>&1 || true
  docker config rm gitlab-runner-mock-js >/dev/null 2>&1 || true
  docker config create gitlab-runner-mock-js "$dir/ci/mock-gitlab.js" >/dev/null
  docker service create --name mock-gitlab --network "${release}_default" \
    --config source=gitlab-runner-mock-js,target=/mock.js \
    node:22-alpine node /mock.js >/dev/null

  for _ in $(seq 1 40); do
    state="$(docker service ps mock-gitlab --filter desired-state=running \
      --format '{{.CurrentState}}' 2>/dev/null | sed -n 1p)"
    case "$state" in Running*) break ;; esac
    sleep 3
  done

  # check_interval is 3s, so a poll should arrive almost at once; allow for the image pull
  # and for docker's log delivery lagging the process.
  mocklog="$(mktemp)"
  seen=0
  for _ in $(seq 1 40); do
    docker service logs --raw mock-gitlab > "$mocklog" 2>&1 || true
    if grep -aF 'MOCK-GITLAB POST /api/v4/jobs/request' "$mocklog" >/dev/null; then
      seen=1
      break
    fi
    sleep 3
  done

  if [ "$seen" -ne 1 ]; then
    bad "the runner never polled the mock GitLab for jobs"
    sed -n '1,20p' "$mocklog" | sed 's/^/    /'
  else
    # The token the runner PRESENTED, as the server saw it. This is the end of the chain.
    presented="$(grep -aF 'MOCK-GITLAB POST /api/v4/jobs/request' "$mocklog" \
      | sed -n 's/.*token=\([^ ]*\).*/\1/p' | sed -n 1p)"
    if [ "$presented" = "$token" ]; then
      note "mock: the runner authenticated with exactly the token from the Swarm secret"
    else
      bad "the runner presented token '$presented', but the mounted secret holds '$token'"
    fi
    # An empty token would still have produced a poll, so this is checked separately.
    [ -n "$presented" ] || bad "the runner polled with an EMPTY token"
  fi

  docker service rm mock-gitlab >/dev/null 2>&1 || true
  docker config rm gitlab-runner-mock-js >/dev/null 2>&1 || true
  rm -f "$mocklog"
fi

rm -f "$logfile"
exit "$fail"
