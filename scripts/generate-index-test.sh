#!/usr/bin/env bash
#
# Functional test for scripts/generate-index.sh — the script that assembles the
# PUBLISHED index.yaml from GitHub Releases. ci.yml shellchecks it but never ran
# it, so a change to the jq/yq assembly could ship a subtly wrong index (a version
# that stops being a string, an appVersion silently reparsed as a float, a
# description that breaks the document, a URL that no longer resolves) and only
# break downstream — exactly the class of failure swarmcli now rejects at install
# time (it verifies the chart digest against this index, Eldara-Tech/swarmcli#447).
#
# generate-index.sh reaches the network through two seams — `gh release list` and
# `gh release download` — and reads each chart's Chart.yaml with `git show
# <tag>:...`. This test makes it hermetic: a throwaway git repo supplies the tags
# and Chart.yaml, and a mock `gh` on PATH supplies the release list and the
# `.sha256` assets. No network, no auth, no real releases. It then parses the
# generated index with yq and asserts the structure and — the point of the jq/yq
# rewrite — that number-like scalars stay strings and a tricky description is
# escaped rather than corrupting the document.
#
# Requires: jq, yq (mikefarah v4), git — the same tools generate-index.sh needs,
# minus the mocked gh.
#
# Usage: scripts/generate-index-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/scripts/generate-index.sh"
REPO="Eldara-Tech/swarmcli-charts"          # only used for BASE_URL + (mocked) gh --repo
BASE="https://github.com/${REPO}/releases/download"

for tool in jq yq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# A mock `gh` shared by both cases; RELEASES_TSV / a per-asset sha file drive it so
# the same binary serves the populated and the empty case.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# gh release list --repo R --limit N --json ... -q ... -> the TSV in $GH_RELEASES
# gh release download TAG --repo R --pattern ASSET.sha256 --output -   -> $GH_SHADIR/ASSET.sha256
set -euo pipefail
if [ "${1:-}" = release ] && [ "${2:-}" = list ]; then
  printf '%b' "${GH_RELEASES:-}"
  exit 0
fi
if [ "${1:-}" = release ] && [ "${2:-}" = download ]; then
  prev=""; pat=""
  for a in "$@"; do [ "$prev" = --pattern ] && pat="$a"; prev="$a"; done
  f="${GH_SHADIR:-/nonexistent}/${pat}"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  exit 1   # no checksum asset -> generate-index.sh leaves the digest empty
fi
echo "mock gh: unhandled: $*" >&2
exit 1
MOCK
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

fail=0
note() { echo "  $1: $2"; if [ "$1" = FAIL ]; then fail=1; fi; }
# eq <label> <expected> <actual>
eq() { if [ "$2" = "$3" ]; then note PASS "$1"; else note FAIL "$1 (want [$2], got [$3])"; fi; }

# ---- Case 1: two charts with number-like versions and a tricky description ----
REPO_DIR="$WORK/repo"
mkdir -p "$REPO_DIR/charts/foo" "$REPO_DIR/charts/bar"
cat >"$REPO_DIR/charts/foo/Chart.yaml" <<'EOF'
name: foo
version: 0.1.0
appVersion: "1.10"
description: 'Echo with a "quote", a colon: value, and a #hash'
home: https://example.com/foo
EOF
cat >"$REPO_DIR/charts/bar/Chart.yaml" <<'EOF'
name: bar
version: 1.20
appVersion: 2.0
description: plain bar
EOF
(
  cd "$REPO_DIR"
  git init -q
  git config user.email t@t && git config user.name t
  git add -A && git commit -qm init
  git tag foo/v0.1.0 && git tag bar/v1.20
)

# The checksum assets the mock gh serves (bar deliberately has NONE -> no digest).
mkdir -p "$WORK/sha"
echo "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888  foo-v0.1.0.tgz" \
  >"$WORK/sha/foo-v0.1.0.tgz.sha256"

echo "== generate-index.sh: populated repo =="
OUT="$(cd "$REPO_DIR" && GH_RELEASES='foo/v0.1.0\t2026-07-01T00:00:00Z\nbar/v1.20\t2026-07-02T00:00:00Z\n' \
  GH_SHADIR="$WORK/sha" "$GEN" "$REPO" 2>"$WORK/err")" \
  || { echo "  FAIL: generate-index.sh exited non-zero"; sed 's/^/    /' "$WORK/err"; exit 1; }

y() { printf '%s' "$OUT" | yq "$1"; }

# Valid YAML at all (yq would error otherwise) + the envelope.
printf '%s' "$OUT" | yq '.' >/dev/null 2>&1 && note PASS "output is valid YAML" || note FAIL "output is not valid YAML"
eq "apiVersion is v1"                 "v1"                                  "$(y '.apiVersion')"

# Number-like scalars MUST stay strings — the corruption the jq/yq rewrite prevents.
eq "foo.version is the string 0.1.0"  "0.1.0"  "$(y '.entries.foo[0].version')"
eq "foo.version tagged !!str"         "!!str"  "$(y '.entries.foo[0].version | tag')"
eq "bar.version 1.20 not float 1.2"   "1.20"   "$(y '.entries.bar[0].version')"
eq "bar.version tagged !!str"         "!!str"  "$(y '.entries.bar[0].version | tag')"
eq "foo.appVersion 1.10 not float 1.1" "1.10"  "$(y '.entries.foo[0].appVersion')"
eq "foo.appVersion tagged !!str"      "!!str"  "$(y '.entries.foo[0].appVersion | tag')"

# A description with quotes/colon/hash round-trips instead of breaking the doc.
eq "foo.description round-trips"      'Echo with a "quote", a colon: value, and a #hash' \
                                      "$(y '.entries.foo[0].description')"

# URL, digest, created, home, sources.
eq "foo.url resolves to the asset"    "${BASE}/foo/v0.1.0/foo-v0.1.0.tgz"   "$(y '.entries.foo[0].urls[0]')"
eq "foo.digest is sha256-prefixed"    "sha256:aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888" \
                                      "$(y '.entries.foo[0].digest')"
eq "foo.created from publishedAt"     "2026-07-01T00:00:00Z"                "$(y '.entries.foo[0].created')"
eq "foo.sources is this repo"         "https://github.com/${REPO}"          "$(y '.entries.foo[0].sources[0]')"
eq "foo.home carried through"         "https://example.com/foo"             "$(y '.entries.foo[0].home')"
# An absent optional key is omitted, not emitted empty (bar has no home; no digest asset).
eq "bar.home omitted when unset"      "null"                                "$(y '.entries.bar[0].home')"
eq "bar.digest omitted when no asset" "null"                                "$(y '.entries.bar[0].digest')"

# ---- Case 2: no releases -> the valid empty-index form ------------------------
echo "== generate-index.sh: no releases =="
EMPTY="$(cd "$REPO_DIR" && GH_RELEASES='' GH_SHADIR="$WORK/sha" "$GEN" "$REPO" 2>/dev/null)" \
  || { echo "  FAIL: generate-index.sh exited non-zero on empty"; exit 1; }
printf '%s' "$EMPTY" | yq '.' >/dev/null 2>&1 && note PASS "empty output is valid YAML" || note FAIL "empty output is not valid YAML"
eq "empty: apiVersion is v1"          "v1"        "$(printf '%s' "$EMPTY" | yq '.apiVersion')"
eq "empty: entries is an empty map"   "0"         "$(printf '%s' "$EMPTY" | yq '.entries | length')"

if [ "$fail" -ne 0 ]; then
  echo "generate-index test FAILED"
  exit 1
fi
echo "generate-index test PASSED"
