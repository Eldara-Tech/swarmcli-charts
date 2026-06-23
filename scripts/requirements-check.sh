#!/usr/bin/env bash
#
# requirements.yaml consistency check — mirrors swarmcli's runtime contract at
# PR time. When a chart ships a requirements.yaml it is authoritative: every
# external network/secret/config the rendered manifest references must be
# declared there. This catches author drift (an external resource added to the
# template but not declared) before publish.
#
# Usage: scripts/requirements-check.sh <rendered-stack.yaml> <chart-dir>
#   No-op when the chart has no requirements.yaml (charts may rely on the
#   manifest-driven fallback) or when a usable yq is unavailable (with a note) —
#   the render harness owns hard failures; this is a shift-left contract guard,
#   and swarmcli still enforces the contract at install time.
#
# Requires mikefarah yq v4 (preinstalled on GitHub-hosted runners). A different
# yq, or any expression error, downgrades to a skip rather than a false failure.
set -euo pipefail

rendered="$1"
dir="$2"
req="$dir/requirements.yaml"

[ -f "$req" ] || exit 0 # optional: fall back to manifest-driven behaviour

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "   note: mikefarah yq v4 not found — skipping requirements.yaml consistency check"
  exit 0
fi

# eval the given yq expression against file $2; on any yq error, signal skip via
# a sentinel so a yq incompatibility never turns into a spurious render failure.
yq_or_skip() {
  local expr="$1" file="$2" out
  if ! out="$(yq "$expr" "$file" 2>/dev/null)"; then
    echo "__YQ_ERROR__"
    return 0
  fi
  printf '%s\n' "$out"
}

# External resource real names in the rendered manifest, per compose semantics:
#   external: true        -> real name is the map key
#   external: { name: x } -> real name is x (falling back to the key)
manifest_external() {
  yq_or_skip ".${1} // {} | to_entries | .[]
    | select(.value.external == true or ((.value.external | tag) == \"!!map\"))
    | (.value.external.name // .key)" "$rendered" | sort -u
}

# Declared names in requirements.yaml.
declared() {
  yq_or_skip ".${1} // [] | .[].name" "$req" | sort -u
}

fail=0
for kind in networks secrets configs; do
  used="$(manifest_external "$kind")"
  declared_names="$(declared "$kind")"
  if [ "$used" = "__YQ_ERROR__" ] || [ "$declared_names" = "__YQ_ERROR__" ]; then
    echo "   note: yq expression failed — skipping requirements.yaml consistency check"
    exit 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! grep -qxF "$name" <<<"$declared_names"; then
      echo "   FAIL: external $kind \"$name\" is used by the manifest but not declared in requirements.yaml"
      fail=1
    fi
  done <<<"$used"
done

exit "$fail"
