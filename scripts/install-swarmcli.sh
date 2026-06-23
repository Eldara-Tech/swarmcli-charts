#!/usr/bin/env bash
#
# Build the swarmcli binary from source — swarmcli is the chart *renderer*.
#
# The charts in this repo are Go text/template files turned into Docker Swarm
# stacks by swarmcli's `charts template` command, so testing a chart requires
# swarmcli itself. Two constraints force a source build rather than `go install`
# or a release download:
#   1. The `charts` CLI is currently only on swarmcli's `main` branch — no
#      published release renders these charts yet.
#   2. swarmcli's module path is `swarmcli` (not its GitHub path), so
#      `go install github.com/Eldara-Tech/swarmcli@...` does not resolve.
#
# Tracks the latest `main` by default. Override the ref (a branch or tag) with
# SWARMCLI_REF, or the repo with SWARMCLI_REPO. Once a swarmcli release ships
# the charts CLI, this can be swapped for downloading the release asset
# (swarmcli_<OS>_<ARCH>.tar.gz) + verifying it against checksums.txt.
#
# Usage: scripts/install-swarmcli.sh [dest-dir]
#   Builds <dest-dir>/swarmcli and prints its absolute path on stdout.
set -euo pipefail

REPO_URL="${SWARMCLI_REPO:-https://github.com/Eldara-Tech/swarmcli}"
REF="${SWARMCLI_REF:-main}"
DEST="${1:-.swarmcli-bin}"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
SRC="$DEST/src"

# Re-clone fresh each time so we always build the requested ref (cheap, shallow).
rm -rf "$SRC"
echo "Cloning swarmcli ($REF) ..." >&2
git clone --depth 1 --branch "$REF" "$REPO_URL" "$SRC" >&2

echo "Building swarmcli ..." >&2
( cd "$SRC" && go build -o "$DEST/swarmcli" . )

echo "$DEST/swarmcli"
