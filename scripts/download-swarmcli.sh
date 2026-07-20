#!/usr/bin/env bash
#
# Download a RELEASED swarmcli binary and verify it against checksums.txt —
# swarmcli is the chart *renderer* (see scripts/install-swarmcli.sh for why a
# chart needs it).
#
# This is the release counterpart to install-swarmcli.sh's source build. The
# per-PR workflows build `main` on purpose (they catch a renderer breakage the
# moment it lands, before any release ships it). This script fetches a published
# release instead — the version users actually have — and is used by:
#   * .github/workflows/nightly.yml — validates the whole repo against the
#     latest release on a schedule.
#   * scripts/floor-check.sh — renders each chart with the exact release its
#     Chart.yaml declares. Downloading beats building: no Go toolchain, no
#     compile, and floor-check only ever wants versions that are already tagged.
#
# No Go, no `gh`, no auth: the assets are public, so plain curl + sha256sum do.
#
# Tracks the latest NON-PRERELEASE by default (GitHub's /releases/latest already
# excludes prereleases and drafts). Override the tag with SWARMCLI_REF (e.g.
# v1.12.0), or the repo with SWARMCLI_REPO (owner/repo).
#
# Usage: scripts/download-swarmcli.sh [dest-dir]
#   Downloads <dest-dir>/swarmcli and prints its absolute path on stdout.
set -euo pipefail

# Accept a bare owner/repo or a full git/HTTPS URL (floor-check passes the
# latter via SWARMCLI_REPO); normalise to owner/repo.
REPO="${SWARMCLI_REPO:-Eldara-Tech/swarmcli}"
REPO="${REPO#https://github.com/}"
REPO="${REPO%.git}"
DEST="${1:-.swarmcli-bin}"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# GoReleaser asset naming: swarmcli_<OS>_<ARCH>.tar.gz, with a universal
# ("all") macOS build.
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)   os="Linux"   ;;
  Darwin)  os="Darwin"; arch="all" ;;
  *) echo "download-swarmcli: unsupported OS '$os'" >&2; exit 2 ;;
esac
if [ "$os" != "Darwin" ]; then
  case "$arch" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="arm64"  ;;
    *) echo "download-swarmcli: unsupported arch '$arch'" >&2; exit 2 ;;
  esac
fi
asset="swarmcli_${os}_${arch}.tar.gz"

# Resolve the tag. /releases/latest redirects to /releases/tag/<tag>; reading
# the redirect target needs no API token and skips prereleases.
REF="${SWARMCLI_REF:-}"
if [ -z "$REF" ]; then
  REF="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" | sed -E 's#.*/tag/##')"
  [ -n "$REF" ] || { echo "download-swarmcli: could not resolve latest release" >&2; exit 1; }
fi

base="https://github.com/$REPO/releases/download/$REF"
work="$DEST/dl"
rm -rf "$work"; mkdir -p "$work"

echo "Downloading swarmcli $REF ($asset) ..." >&2
curl -fsSL -o "$work/$asset"        "$base/$asset"
curl -fsSL -o "$work/checksums.txt" "$base/checksums.txt"

echo "Verifying checksum ..." >&2
( cd "$work" && grep " $asset\$" checksums.txt | sha256sum -c - >&2 )

tar xzf "$work/$asset" -C "$DEST" swarmcli
rm -rf "$work"

echo "$DEST/swarmcli"
