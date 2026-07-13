#!/usr/bin/env bash
#
# requirements.yaml consistency check — mirrors swarmcli's runtime contract at
# PR time. When a chart ships a requirements.yaml it is authoritative: every
# external network/secret/config the rendered manifest references must be
# declared there. This catches author drift (an external resource added to the
# template but not declared) before publish.
#
# Usage: scripts/requirements-check.sh <rendered-stack.yaml> <chart-dir>
#   No-op ONLY when the chart has no requirements.yaml (charts may rely on the
#   manifest-driven fallback).
#
# Requires mikefarah yq v4 — scripts/test-charts.sh pre-flights it, so by the
# time this runs it is present. This script therefore never SKIPS: a missing yq
# and a broken yq expression are both hard failures.
#
# It used to downgrade both to a "note: … skipping" and exit 0, on the theory
# that a shift-left guard should not emit false failures. That was a mistake: a
# skipped check is indistinguishable from a passing one, so `make test` went
# green on machines without yq while asserting nothing at all — which is strictly
# worse than not having the check. Fail loudly instead.
set -euo pipefail

rendered="$1"
dir="$2"
rendered_req="${3:-}" # optional: requirements.yaml already rendered with the release's values
req="$dir/requirements.yaml"

[ -f "$req" ] || exit 0 # optional: fall back to manifest-driven behaviour

# Prefer the values-rendered requirements (swarmcli `charts template --requirements`)
# so a templated declaration — name: "{{ .Values.database.network }}" — is compared
# as its resolved value; fall back to the on-disk file for standalone invocations.
reqsrc="$req"
if [ -n "$rendered_req" ] && [ -f "$rendered_req" ]; then
  reqsrc="$rendered_req"
fi

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "   FAIL: mikefarah yq v4 is required by requirements-check.sh but was not found" >&2
  echo "         (scripts/test-charts.sh pre-flights this — see its message for install hints)" >&2
  exit 1
fi

# Evaluate a yq expression. An error here is a bug in THIS script's expressions,
# not a user error — surface it instead of swallowing it.
yq_eval() {
  local expr="$1" file="$2" out
  if ! out="$(yq "$expr" "$file" 2>&1)"; then
    echo "   FAIL: yq expression failed on $file: $expr" >&2
    printf '         %s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

# External resource real names in the rendered manifest, per compose semantics:
#   external: true        -> real name is the map key
#   external: { name: x } -> real name is x (falling back to the key)
manifest_external() {
  yq_eval ".${1} // {} | to_entries | .[]
    | select(.value.external == true or ((.value.external | tag) == \"!!map\"))
    | (.value.external.name // .key)" "$rendered" | sort -u
}

# Declared names in requirements.yaml (values-resolved when available).
declared() {
  yq_eval ".${1} // [] | .[].name" "$reqsrc" | sort -u
}

fail=0
for kind in networks secrets configs; do
  used="$(manifest_external "$kind")"
  declared_names="$(declared "$kind")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! grep -qxF "$name" <<<"$declared_names"; then
      echo "   FAIL: external $kind \"$name\" is used by the manifest but not declared in requirements.yaml"
      fail=1
    fi
  done <<<"$used"
done

exit "$fail"
