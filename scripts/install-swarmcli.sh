#!/usr/bin/env bash
#
# Build the swarmcli binary from swarmcli's `main` — swarmcli is the chart
# *renderer*.
#
# The charts in this repo are Go text/template files turned into Docker Swarm
# stacks by swarmcli's `charts template` command, so testing a chart requires
# swarmcli itself. The PR workflows build `main` ON PURPOSE: it renders with the
# newest engine, so a change that breaks a chart shows up the moment it lands —
# before any release ships it. (The release counterpart is
# scripts/download-swarmcli.sh, which nightly.yml and floor-check.sh use to
# validate against the version users actually have.)
#
# A source build rather than `go install` — which does resolve now that swarmcli's
# module path is `github.com/Eldara-Tech/swarmcli` — because `go install ...@main`
# goes through the module proxy, which can lag a just-pushed commit by minutes. A
# shallow clone sees it immediately, and that immediacy is the whole point of this
# script. The clone also honours SWARMCLI_REPO, which `go install` has no equivalent
# for.
#
# Tracks the latest `main` by default. Override the ref (a branch or tag) with
# SWARMCLI_REF, or the repo with SWARMCLI_REPO.
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
