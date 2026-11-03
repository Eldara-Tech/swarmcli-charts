#!/usr/bin/env bash
#
# Functional test for scripts/generate-history.sh — the script that renders the
# published version-history page (index.html) from index.yaml (#177).
#
# The generator reads an index and, for each entry, `git show <tag>:...` for its
# Chart.yaml and values.yaml. This test makes that hermetic: a throwaway git repo
# supplies the tags and a hand-written index supplies the entries. It then checks
# the rows a reader relies on: newest version first, an empty image tag falling
# back to appVersion, optional pins listed with their values key, number-like
# scalars kept as written, and every value HTML-escaped.
#
# Requires: jq, yq (mikefarah v4), git — the same tools generate-history.sh needs.
#
# Usage: scripts/generate-history-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/scripts/generate-history.sh"
REPO="Eldara-Tech/swarmcli-charts"
TAGS="https://github.com/${REPO}/releases/tag"

for tool in jq yq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

fail=0
note() { echo "  $1: $2"; if [ "$1" = FAIL ]; then fail=1; fi; }
# has <label> <needle> <haystack>
has() { if printf '%s' "$3" | grep -qF -- "$2"; then note PASS "$1"; else note FAIL "$1 (no [$2])"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then note FAIL "$1 (found [$2])"; else note PASS "$1"; fi; }

# ---- Fixture: demo at two tags, other at one -----------------------------------
REPO_DIR="$WORK/repo"
mkdir -p "$REPO_DIR/charts/demo" "$REPO_DIR/charts/other"
cat >"$REPO_DIR/charts/demo/Chart.yaml" <<'EOF'
name: demo
version: 0.1.0
appVersion: "1.0"
EOF
cat >"$REPO_DIR/charts/demo/values.yaml" <<'EOF'
image:
  repository: demo/app
  tag: ""
EOF
cat >"$REPO_DIR/charts/other/Chart.yaml" <<'EOF'
name: other
version: 1.20
appVersion: 2.0
swarmcliVersion: ">= 1.13.0"
EOF
cat >"$REPO_DIR/charts/other/values.yaml" <<'EOF'
image:
  repository: other/app
  tag: "2.0"
EOF
(
  cd "$REPO_DIR"
  git init -q
  git config user.email t@t && git config user.name t
  git add -A && git commit -qm v1
  git tag demo/v0.1.0 && git tag other/v1.20
)
# demo 0.2.0: a floor, an unquoted float tag on an optional pin, and a scalar image key.
cat >"$REPO_DIR/charts/demo/Chart.yaml" <<'EOF'
name: demo
version: 0.2.0
appVersion: "1.10"
swarmcliVersion: ">= 2.0.0"
EOF
cat >"$REPO_DIR/charts/demo/values.yaml" <<'EOF'
image:
  repository: demo/app
  tag: ""
metrics:
  enabled: false
  image:
    repository: prom/exporter
    tag: 3.10
modelInitImage: curlimages/curl:8.0
imagePullPolicy: IfNotPresent
EOF
(cd "$REPO_DIR" && git commit -qam v2 && git tag demo/v0.2.0)

# The index generate-index.sh would publish: charts in name order, newest first.
cat >"$WORK/index.yaml" <<'EOF'
apiVersion: v1
generated: "2026-07-03T00:00:00Z"
entries:
  demo:
    - name: demo
      version: "0.2.0"
      appVersion: "1.10"
      description: 'Demo <script>alert("x")</script> & co'
      created: "2026-07-02T10:00:00Z"
    - name: demo
      version: "0.1.0"
      appVersion: "1.0"
      description: old demo
      created: "2026-07-01T10:00:00Z"
  other:
    - name: other
      version: 1.20
      appVersion: 2.0
      description: other chart
      created: "2026-06-30T10:00:00Z"
EOF

echo "== generate-history.sh =="
OUT="$(cd "$REPO_DIR" && "$GEN" "$REPO" "$WORK/index.yaml" 2>"$WORK/err")" \
  || { echo "  FAIL: generate-history.sh exited non-zero"; sed 's/^/    /' "$WORK/err"; exit 1; }

# row <tag>: the page's one-line table row for that release.
row() { printf '%s\n' "$OUT" | grep -F "href=\"${TAGS}/$1\"" || true; }
line() { printf '%s\n' "$OUT" | grep -nF -- "$1" | head -1 | cut -d: -f1; }

has   "page is an HTML document"          '<!DOCTYPE html>'                                 "$OUT"
has   "page is closed"                    '</html>'                                         "$OUT"
has   "footer names the index generation" '(2026-07-03T00:00:00Z)'                          "$OUT"

# Grouping and order: demo before other, and demo's newest version first.
[ "$(line 'id="demo"')" -lt "$(line 'id="other"')" ] && note PASS "charts in index order" || note FAIL "charts in index order"
[ "$(line "${TAGS}/demo/v0.2.0")" -lt "$(line "${TAGS}/demo/v0.1.0")" ] \
  && note PASS "newest version first" || note FAIL "newest version first"

R2="$(row demo/v0.2.0)"
has   "0.2.0: release date"               '<td>2026-07-02</td>'                             "$R2"
has   "0.2.0: appVersion 1.10 as written" '<td>1.10</td>'                                   "$R2"
has   "0.2.0: escaped swarmcli floor"     '<td>&gt;= 2.0.0</td>'                            "$R2"
has   "0.2.0: empty tag -> appVersion"    '<code>demo/app:1.10</code> <span class="key">image</span>' "$R2"
has   "0.2.0: optional pin, float kept"   '<code>prom/exporter:3.10</code> <span class="key">metrics.image</span>' "$R2"
has   "0.2.0: scalar image key"           '<code>curlimages/curl:8.0</code> <span class="key">modelInitImage</span>' "$R2"
lacks "0.2.0: imagePullPolicy is no image" 'IfNotPresent'                                   "$R2"

R1="$(row demo/v0.1.0)"
has   "0.1.0: its own appVersion"         '<code>demo/app:1.0</code>'                       "$R1"
has   "0.1.0: no floor shown as a dash"   '<td>—</td>'                                      "$R1"
lacks "0.1.0: no pin from a later tag"    'prom/exporter'                                   "$R1"

has   "other: number-like version kept"   "${TAGS}/other/v1.20\">1.20</a>"                  "$OUT"
has   "other: pinned tag wins"            '<code>other/app:2.0</code>'                      "$(row other/v1.20)"

# The newest description heads the chart, escaped; nothing in it reaches the page raw.
has   "description is escaped"            'Demo &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; co' "$OUT"
lacks "no raw markup from the index"      '<script>'                                        "$OUT"
lacks "older description not the heading" 'old demo'                                        "$OUT"

if [ "$fail" -ne 0 ]; then
  echo "generate-history test FAILED"
  exit 1
fi
echo "generate-history test PASSED"
