#!/usr/bin/env bash
#
# Serve the working-tree charts as a LOCAL chart repository so a contributor can
# exercise the real consumer flow against charts they have NOT published:
#
#   swarmcli charts repo add localrepo http://localhost:8879
#   swarmcli charts repo update
#   swarmcli charts search
#   swarmcli charts install demo localrepo/<chart>
#
# It packages each chart into .localrepo/<chart>-v<version>.tgz, generates an
# index.yaml with relative tarball URLs + sha256 digests, and serves the result
# over HTTP with a throwaway nginx container.
#
# swarmcli requires repo URLs to be http(s) — file:// and bare paths are rejected
# by design — which is why this serves over localhost rather than a path.
#
# Usage: scripts/local-repo.sh [chart ...]   (defaults to all charts under charts/*)
#   Env: LOCALREPO_PORT   host port to serve on (default 8879)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${LOCALREPO_PORT:-8879}"
DIR="$ROOT/.localrepo"

command -v docker >/dev/null 2>&1 \
  || { echo "ERROR: docker is required to serve the local repo"; exit 2; }

# First value of a top-level Chart.yaml scalar key, surrounding quotes stripped.
field() {
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 | sed 's/^"//; s/"$//'
}

charts=("$@")
if [ "${#charts[@]}" -eq 0 ]; then
  for d in charts/*/; do charts+=("$(basename "$d")"); done
fi

rm -rf "$DIR"
mkdir -p "$DIR"

index="$DIR/index.yaml"
{
  echo "apiVersion: v1"
  echo "entries:"
} >"$index"

for chart in "${charts[@]}"; do
  cy="charts/$chart/Chart.yaml"
  if [ ! -f "$cy" ]; then
    echo "ERROR: $cy not found"
    exit 1
  fi
  name="$(field name "$cy")";       name="${name:-$chart}"
  version="$(field version "$cy")"; version="${version:-0.0.0}"
  appVersion="$(field appVersion "$cy")"
  description="$(field description "$cy")"
  tgz="${chart}-v${version}.tgz"

  tar -czf "$DIR/$tgz" -C charts "$chart"
  digest="$(sha256sum "$DIR/$tgz" | awk '{print $1}')"

  {
    echo "  ${name}:"
    echo "    - name: ${name}"
    echo "      version: \"${version}\""
    echo "      appVersion: \"${appVersion}\""
    echo "      description: \"${description}\""
    echo "      urls:"
    echo "        - ${tgz}"
    echo "      digest: sha256:${digest}"
  } >>"$index"
  echo "packaged $chart -> $tgz"
done

# Clean any leftover server from a previous run.
docker rm -f swarmcli-localrepo >/dev/null 2>&1 || true

cat <<EOF

Local chart repo ready at http://localhost:${PORT}
Run these in another terminal:

  swarmcli charts repo add localrepo http://localhost:${PORT}
  swarmcli charts repo update
  swarmcli charts search
  swarmcli charts install demo localrepo/<chart> --wait   # then: docker stack ps demo

Cleanup when done:

  swarmcli charts uninstall demo --purge-volumes
  swarmcli charts repo remove localrepo
  # Ctrl-C here to stop the server (the container is removed automatically)

EOF

exec docker run --rm --name swarmcli-localrepo -p "${PORT}:80" \
  -v "$DIR:/usr/share/nginx/html:ro" nginx:alpine
