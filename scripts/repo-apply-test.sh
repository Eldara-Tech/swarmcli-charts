#!/usr/bin/env bash
#
# Integration test for the REAL repository-consumer path a published index is
# meant to serve: resolve a chart from a repo index -> download its tarball ->
# verify the tarball digest against the index -> render -> (with a swarm) apply.
# This is the one flow neither other test drives — scripts/e2e-test.sh installs a
# local chart *directory* (no index, no URL, no digest) and scripts/local-repo-
# test.sh stops at `search` (never installs). So a change that published a subtly
# wrong index (an entry that no longer resolves, a digest that no longer matches
# its asset, a version that stops being a string) would ship green and only break
# downstream — the more so now that swarmcli fails an install closed on a digest
# mismatch (Eldara-Tech/swarmcli#447).
#
# It stands up a throwaway HTTP repo serving TWO versions of the whoami chart —
# built from the working tree, with real sha256 digests — and drives, in order:
#
#   No swarm (always — uses `charts template`, which resolves+downloads+verifies+
#   renders without ever touching swarm state):
#     A1  render the newer version FROM the repo asserts it resolves, its tarball
#         digest verifies, and it renders. The published-index happy path.
#     A2  the same after ONE hex digit of that version's digest is flipped in the
#         served index asserts it FAILS with a digest mismatch — the direct guard
#         for #447. The good index is then restored.
#
#   With a swarm (E2E_SWARM_INIT=1, or one already active — `charts apply` needs a
#   swarm to read deployed releases, so these are gated on one):
#     B1  `charts apply --diff` for the newer version plans an install and deploys
#         nothing.
#     B2  apply the OLDER version, converge, then `charts outdated` reports it
#         outdated (installed < the newer served version) — the Renovate signal.
#     B3  apply the newer version asserts an `upgrade`, converge; apply it AGAIN
#         asserts `unchanged` — the GitOps idempotence contract. Then uninstall.
#
# whoami is the chart because it converges solo (a single traefik/whoami service,
# its traefik-public overlay auto-created from requirements.yaml) with no external
# setup, so the swarm phase needs nothing provisioned.
#
# It reuses the same serving technique as scripts/local-repo.sh (nginx + `docker
# cp` into the docroot, never a bind mount — a bind mount surfaces empty whenever
# the Docker daemon does not share this host's filesystem: Docker Desktop, WSL2,
# rootless, a remote DOCKER_HOST). It needs Docker; the swarm phase (B) skips
# cleanly when no swarm is active and E2E_SWARM_INIT is unset, and B also skips on
# a swarmcli too old to have `charts apply` (Eldara-Tech/swarmcli#450).
#
# Usage: SWARMCLI=/path/to/swarmcli scripts/repo-apply-test.sh
#   Env: LOCALREPO_PORT  host port for the repo (default 8878)
#        E2E_SWARM_INIT  set to 1 to `docker swarm init` if no swarm is active
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWARMCLI="${SWARMCLI:-swarmcli}"
PORT="${LOCALREPO_PORT:-8878}"
URL="http://localhost:${PORT}"
CONTAINER="swarmcli-repo-apply"
RELEASE="ci-repo-apply-whoami"
CHART_SRC="charts/whoami"

command -v docker >/dev/null 2>&1 \
  || { echo "ERROR: docker is required to run the repo-apply integration test"; exit 2; }

# First value of a top-level Chart.yaml scalar key, surrounding quotes stripped —
# same reader as scripts/local-repo.sh so it sees the version the way the index does.
field() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 | sed 's/^"//; s/"$//' | tr -d '\r'; }

# The newer version is whatever the working tree declares; the older one is a
# synthetic floor guaranteed to sort below it, so `outdated` and the upgrade both
# have a real version gap to act on.
CURVER="$(field version "$CHART_SRC/Chart.yaml")"
OLDVER="0.0.1"
[ -n "$CURVER" ] || { echo "ERROR: could not read version from $CHART_SRC/Chart.yaml"; exit 1; }
[ "$CURVER" != "$OLDVER" ] || { echo "ERROR: working-tree whoami version is $OLDVER; the test needs it above the synthetic floor"; exit 1; }

# sha256 of a file — GNU coreutils, BSD/macOS, or openssl, whichever exists.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

STATE="$(mktemp -d)"      # isolates swarmcli's repo state (XDG_STATE_HOME) — no config left behind
WORK="$(mktemp -d)"       # chart staging + the served docroot
DOCROOT="$WORK/docroot"
export XDG_STATE_HOME="$STATE"
# Same opt-in as local-repo-test.sh: swarmcli refuses a plain-http repository by
# default (Eldara-Tech/swarmcli#531) and this one is a throwaway container on
# loopback. Needed for the whole run, not just `repo add` — `apply` downloads the
# tarball, and the scheme is re-checked there too.
export SWARMCLI_CHARTS_ALLOW_PLAINTEXT=1
mkdir -p "$DOCROOT"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # Remove the release however far the swarm phase got (best effort; no swarm => no-op).
  "$SWARMCLI" charts uninstall "$RELEASE" >/dev/null 2>&1 || docker stack rm "$RELEASE" >/dev/null 2>&1 || true
  rm -rf "$STATE" "$WORK"
}
trap cleanup EXIT INT TERM

# Package whoami at <version> into the docroot with a real digest, and echo the
# `sha256:`-prefixed digest. The chart is copied under a `whoami/` top directory
# (what a packaged chart wraps its contents in — swarmcli strips the leading dir)
# and its Chart.yaml version rewritten, so both tarballs are genuine whoami charts
# that differ only in the one field the index and the upgrade key on.
package() {  # package <version> -> stdout: sha256:<hex>
  local ver="$1" stage="$WORK/stage-$1"
  rm -rf "$stage"
  mkdir -p "$stage/whoami"
  cp -r "$CHART_SRC/." "$stage/whoami/"
  sed -i -E "s/^version:[[:space:]]*.*/version: ${ver}/" "$stage/whoami/Chart.yaml"
  tar -czf "$DOCROOT/whoami-${ver}.tgz" -C "$stage" whoami
  printf 'sha256:%s' "$(sha256 "$DOCROOT/whoami-${ver}.tgz")"
}

OLD_DIGEST="$(package "$OLDVER")"
CUR_DIGEST="$(package "$CURVER")"

# Write the served index. Two versions of whoami, newest first; digests are the
# real tarball sums so the happy path verifies and only the deliberate tamper in
# A2 breaks. This mirrors the shape `helm repo index` / generate-index.sh emit.
write_index() {  # write_index <cur-digest>  (lets A2 re-serve a tampered digest)
  cat >"$DOCROOT/index.yaml" <<EOF
apiVersion: v1
entries:
  whoami:
    - name: whoami
      version: "${CURVER}"
      urls:
        - whoami-${CURVER}.tgz
      digest: ${1}
    - name: whoami
      version: "${OLDVER}"
      urls:
        - whoami-${OLDVER}.tgz
      digest: ${OLD_DIGEST}
EOF
}

# Serve the docroot over nginx. `docker cp` (not a bind mount) so it serves the
# same wherever the daemon runs — see scripts/local-repo.sh for the why.
serve() { docker cp "$DOCROOT/." "$CONTAINER:/usr/share/nginx/html/"; }

write_index "$CUR_DIGEST"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p "${PORT}:80" nginx:alpine >/dev/null
serve

# Confirm nginx serves the index from its docroot before handing off — probed
# INSIDE the container so host-networking quirks cannot fail a working server.
served=
for _ in 1 2 3 4 5; do
  if docker exec "$CONTAINER" wget -q -O /dev/null http://localhost/index.yaml 2>/dev/null; then served=1; break; fi
  sleep 1
done
[ -n "$served" ] || { echo "ERROR: nginx is not serving index.yaml from its docroot"; exit 1; }

"$SWARMCLI" charts repo add localrepo "$URL" >/dev/null
"$SWARMCLI" charts repo update >/dev/null

fail=0
note() { echo "  $1: $2"; if [ "$1" = FAIL ]; then fail=1; fi; }

echo "== repo-apply against ${URL} (whoami ${OLDVER} -> ${CURVER}) =="

# ---- A1: the published happy path — resolve, digest-verify, render -----------
# `charts template` runs the SAME resolve->Pull->verifyDigest->render path an
# install does, but needs no swarm, so it guards the index/digest/tarball contract
# even on the swarm-free integration runner.
if out="$("$SWARMCLI" charts template "$RELEASE" localrepo/whoami --version "$CURVER" 2>&1)"; then
  if printf '%s\n' "$out" | grep -q 'services:'; then
    note PASS "template resolves + digest-verifies + renders whoami ${CURVER} from the repo"
  else
    note FAIL "template rendered no manifest"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
else
  note FAIL "template of whoami ${CURVER} from the repo errored"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- A2: a digest that no longer matches its asset is a hard failure ---------
# Flip the last hex digit of the served CURVER digest; the tarball is untouched,
# so download != index and #447 must refuse.
last="${CUR_DIGEST: -1}"
case "$last" in 0) rep=1;; *) rep=0;; esac
write_index "${CUR_DIGEST:0:${#CUR_DIGEST}-1}${rep}"
serve
"$SWARMCLI" charts repo update >/dev/null
if out="$("$SWARMCLI" charts template "$RELEASE" localrepo/whoami --version "$CURVER" 2>&1)"; then
  note FAIL "template accepted a tampered digest (the #447 guard is not firing)"
  printf '%s\n' "$out" | sed 's/^/    /'
else
  if printf '%s\n' "$out" | grep -qi 'digest mismatch'; then
    note PASS "template rejects a digest that does not match its asset"
  else
    note FAIL "template failed but not on a digest mismatch"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
fi
# Restore the good index for the swarm phase.
write_index "$CUR_DIGEST"
serve
"$SWARMCLI" charts repo update >/dev/null

# ---- B: swarm phase — apply --diff, install older, outdated, upgrade, idempotence
swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
if [ "$swarm_state" != "active" ] && [ "${E2E_SWARM_INIT:-}" = "1" ]; then
  echo "No active swarm; E2E_SWARM_INIT=1 -> docker swarm init"
  docker swarm init >/dev/null && swarm_state=active
fi

# Probe once, capturing output — piping `charts apply` (which exits non-zero either
# way) straight into grep would, under `set -o pipefail`, return the command's
# failure and mask grep's verdict.
apply_probe="$("$SWARMCLI" charts apply 2>&1 || true)"
if [ "$swarm_state" != "active" ]; then
  echo "-- no active swarm; skipping the deploy phase (apply/outdated/upgrade/idempotence) --"
elif printf '%s\n' "$apply_probe" | grep -q 'unknown charts command'; then
  echo "-- this swarmcli build has no 'charts apply' (needs a release from swarmcli#450); skipping the deploy phase --"
else
  # The declarative manifest a real GitOps user commits: the repo it pulls from
  # and the pinned release. version is rewritten in place between phases.
  RELFILE="$WORK/release.yaml"
  write_release() {  # write_release <version>
    cat >"$RELFILE" <<EOF
apiVersion: v1
repositories:
  - name: localrepo
    url: ${URL}
releases:
  - name: ${RELEASE}
    chart: localrepo/whoami
    version: "${1}"
EOF
  }

  # Poll the ACTUAL task state (not swarmcli --wait, which returns while tasks are
  # still Pending) until every desired-Running task reads Running, or time runs out.
  converge() {  # converge <deadline-epoch>
    local states
    while :; do
      states="$(docker stack ps "$RELEASE" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null || true)"
      if [ -n "$states" ] && ! printf '%s\n' "$states" | grep -vq '^Running'; then return 0; fi
      [ "$(date +%s)" -ge "$1" ] && return 1
      sleep 3
    done
  }

  # B1: plan-only apply asserts an install and deploys nothing.
  write_release "$CURVER"
  if out="$("$SWARMCLI" charts apply -f "$RELFILE" --diff 2>&1)"; then
    if printf '%s\n' "$out" | grep -q '1 to install' \
       && ! docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$RELEASE"; then
      note PASS "apply --diff plans an install and deploys nothing"
    else
      note FAIL "apply --diff did not plan a no-deploy install"
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
  else
    note FAIL "apply --diff errored"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  # B2: install the OLDER version, converge, then outdated must flag it.
  write_release "$OLDVER"
  if out="$("$SWARMCLI" charts apply -f "$RELFILE" 2>&1)"; then
    if converge "$(( $(date +%s) + 180 ))"; then
      note PASS "apply installs whoami ${OLDVER} from the repo and it converges"
    else
      note FAIL "whoami ${OLDVER} did not converge"
      docker stack ps "$RELEASE" --no-trunc 2>/dev/null | sed 's/^/    /' || true
    fi
  else
    note FAIL "apply of whoami ${OLDVER} was rejected"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  out="$("$SWARMCLI" charts outdated 2>&1 || true)"
  if printf '%s\n' "$out" | grep -q "$RELEASE" \
     && printf '%s\n' "$out" | grep -q "$OLDVER" \
     && printf '%s\n' "$out" | grep -q "$CURVER"; then
    note PASS "outdated reports ${RELEASE} (${OLDVER} -> ${CURVER})"
  else
    note FAIL "outdated did not report ${RELEASE} as ${OLDVER} -> ${CURVER}"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  # B3: bump to CURVER — a real upgrade (apply keys unchanged/upgrade on chart
  # version) — then re-apply the same file and assert it is a no-op.
  write_release "$CURVER"
  if out="$("$SWARMCLI" charts apply -f "$RELFILE" 2>&1)"; then
    if printf '%s\n' "$out" | grep -q '1 to upgrade'; then
      note PASS "apply upgrades ${OLDVER} -> ${CURVER}"
    else
      note FAIL "apply did not report an upgrade to ${CURVER}"
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
    converge "$(( $(date +%s) + 180 ))" || { note FAIL "whoami ${CURVER} did not converge after upgrade"; docker stack ps "$RELEASE" --no-trunc 2>/dev/null | sed 's/^/    /' || true; }
  else
    note FAIL "apply upgrade to ${CURVER} was rejected"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  if out="$("$SWARMCLI" charts apply -f "$RELFILE" 2>&1)"; then
    if printf '%s\n' "$out" | grep -q '1 unchanged' && printf '%s\n' "$out" | grep -q '0 to upgrade'; then
      note PASS "re-apply is unchanged (idempotent)"
    else
      note FAIL "re-apply was not a no-op"
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
  else
    note FAIL "re-apply errored"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi

  "$SWARMCLI" charts uninstall "$RELEASE" >/dev/null 2>&1 || docker stack rm "$RELEASE" >/dev/null 2>&1 || true
fi

if [ "$fail" -ne 0 ]; then
  echo "repo-apply integration test FAILED"
  exit 1
fi
echo "repo-apply integration test PASSED"
