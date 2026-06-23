#!/usr/bin/env bash
#
# Scan a rendered Swarm stack for dangerous primitives. A risky pattern FAILS
# unless the chart explicitly acknowledges it in Chart.yaml:
#
#   annotations:
#     swarmcli-charts/allow: "docker-socket,host-mount"
#
# The point is to make danger explicit and reviewable — a contributed chart
# cannot silently ship a docker.sock mount or a privileged container.
#
# Risk keys: docker-socket, host-mount, privileged, host-network, host-pid, cap-add
#
# Usage: scripts/security-scan.sh <rendered.yaml> <chart-dir>
set -euo pipefail

RENDERED="${1:?usage: security-scan.sh <rendered.yaml> <chart-dir>}"
CHARTDIR="${2:?usage: security-scan.sh <rendered.yaml> <chart-dir>}"

# Acknowledged risk keys from the Chart.yaml annotation (comma-separated list).
allow="$(sed -n 's#.*swarmcli-charts/allow:[[:space:]]*##p' "$CHARTDIR/Chart.yaml" 2>/dev/null \
  | tr -d '"'\'' ' | head -1)"
is_allowed() { case ",${allow}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

risks=()
grep -q '/var/run/docker\.sock' "$RENDERED" && risks+=("docker-socket")
grep -Eq '^[[:space:]]*privileged:[[:space:]]*true' "$RENDERED" && risks+=("privileged")
grep -Eq '^[[:space:]]*network_mode:[[:space:]]*"?'\''?host' "$RENDERED" && risks+=("host-network")
grep -Eq '^[[:space:]]*pid:[[:space:]]*"?'\''?host' "$RENDERED" && risks+=("host-pid")
grep -Eq '^[[:space:]]*cap_add:' "$RENDERED" && risks+=("cap-add")
# Absolute-path bind mounts other than the docker socket (host filesystem access).
if grep -E '^[[:space:]]*-[[:space:]]*/[^:]+:' "$RENDERED" | grep -vq '/var/run/docker\.sock'; then
  risks+=("host-mount")
fi

status=0
if [ "${#risks[@]}" -gt 0 ]; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if is_allowed "$r"; then
      echo "    note: risk '$r' present and acknowledged via swarmcli-charts/allow"
    else
      echo "    SECURITY: '$r' present in rendered stack but NOT acknowledged."
      echo "              add it to charts/$(basename "$CHARTDIR")/Chart.yaml:"
      echo "                annotations:"
      echo "                  swarmcli-charts/allow: \"$r\""
      status=1
    fi
  done < <(printf '%s\n' "${risks[@]}" | sort -u)
fi

exit "$status"
