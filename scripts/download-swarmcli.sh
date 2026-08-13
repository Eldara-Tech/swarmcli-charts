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
# It downloads the **oss** artefact, deliberately. A swarmcli release now
# carries two builds under one tag: `swarmcli_*`, which is the Business Edition
# build with the licensed code compiled in and inert, and `swarmcli_*_oss`,
# which is the wholly Apache-2.0 one. Rendering a chart needs nothing licensed,
# and this repository is Apache-2.0 — so it takes the artefact it can verify is
# the same. See Eldara-Tech/swarmcli docs/editions.md.
#
# The executable *inside* both archives is `swarmcli`, which is why the tar
# extraction below and floor-check.sh's invocation are unchanged.
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

# GoReleaser asset naming: swarmcli_<OS>_<ARCH>_oss.tar.gz, with a universal
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
# Newest spelling first; each entry is `<asset>:<checksum manifest>`. Only an
# HTTP error moves on to the next one, and the last entry is the LICENSED build
# — see the fetch loop below for why that ordering has to be defended rather
# than merely written down.
#
#   swarmcli_<OS>_<ARCH>_oss.tar.gz   the Apache-2.0 build (Eldara-Tech/swarmcli#569
#                                     moved the qualifier to the end so that the
#                                     Business Edition archives sort first on the
#                                     release page)
#   swarmcli-oss_<OS>_<ARCH>.tar.gz   the same build, as v1.14.0-rc1 and rc2 named it
#   swarmcli_<OS>_<ARCH>.tar.gz       pre-editions, when the plain name WAS this build
candidates="swarmcli_${os}_${arch}_oss.tar.gz:checksums-oss.txt
swarmcli-oss_${os}_${arch}.tar.gz:checksums-oss.txt
swarmcli_${os}_${arch}.tar.gz:checksums.txt"
asset="swarmcli_${os}_${arch}_oss.tar.gz"
checksums="checksums-oss.txt"

# curl, with the transport failures retried. A runner that loses a TLS handshake
# for one second must not redden a whole nightly (#104: `curl: (60) SSL
# certificate problem: self-signed certificate`, one job out of eighteen, the
# other seventeen fetching the same asset fine). curl's own --retry covers only
# HTTP 5xx/429 and timeouts, and --retry-all-errors would also retry the 404 the
# -oss probe below EXPECTS on a pre-editions tag — hence the loop.
#
# Passes curl's exit status back: 22 is an HTTP error under -f (the asset is not
# in this release), any other non-zero means we never got there to find out.
fetch() {
  local rc try
  for try in 1 2 3; do
    [ "$try" -eq 1 ] || sleep 2
    rc=0
    curl -fsSL "$@" || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 22 ]; then break; fi
  done
  return "$rc"
}

# Resolve the tag. /releases/latest redirects to /releases/tag/<tag>; reading
# the redirect target needs no API token and skips prereleases.
REF="${SWARMCLI_REF:-}"
if [ -z "$REF" ]; then
  REF="$(fetch -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" | sed -E 's#.*/tag/##')"
  [ -n "$REF" ] || { echo "download-swarmcli: could not resolve latest release" >&2; exit 1; }
fi

base="https://github.com/$REPO/releases/download/$REF"
work="$DEST/dl"
rm -rf "$work"; mkdir -p "$work"

echo "Downloading swarmcli $REF ($asset) ..." >&2
found=
while IFS=: read -r a c; do
  [ -n "$a" ] || continue
  rc=0
  fetch -o "$work/$a" "$base/$a" || rc=$?
  if [ "$rc" -eq 0 ]; then
    asset="$a"; checksums="$c"; found=1
    break
  fi
  # Only an HTTP error (22) means the asset is not in this release. Every other
  # code is a transport failure that outlived the retries, and it must NOT fall
  # through: the last name in the list is the LICENSED build, so swapping it in
  # because a handshake flaked is exactly the silent substitution this script
  # exists to prevent — and it would pass green.
  if [ "$rc" -ne 22 ]; then
    echo "download-swarmcli: fetching $a from $REF failed (curl exit $rc)" >&2
    exit "$rc"
  fi
  # Releases before the editions split published this build under the plain
  # name, with a `checksums.txt` covering it. floor-check.sh asks for whatever
  # tag a chart's Chart.yaml declares, so those tags stay reachable for as long
  # as a chart declares one.
  echo "download-swarmcli: no $a in $REF; trying the next asset name" >&2
done <<EOF
$candidates
EOF
if [ -z "$found" ]; then
  echo "download-swarmcli: $REF publishes none of the asset names this script knows" >&2
  exit 1
fi
echo "download-swarmcli: using $asset ($checksums)" >&2
fetch -o "$work/$checksums" "$base/$checksums"

echo "Verifying checksum ..." >&2
( cd "$work" && grep " $asset\$" "$checksums" | sha256sum -c - >&2 )

tar xzf "$work/$asset" -C "$DEST" swarmcli
rm -rf "$work"

echo "$DEST/swarmcli"
