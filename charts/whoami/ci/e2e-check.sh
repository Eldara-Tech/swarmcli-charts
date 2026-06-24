#!/usr/bin/env bash
#
# Optional e2e smoke check for the whoami chart. scripts/e2e-test.sh runs this
# after the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# whoami attaches to the external `traefik-public` overlay. Traefik itself is
# not running in a bare local swarm, so we skip ingress and curl the service
# directly over the overlay from a throwaway, auto-removed container. Docker
# stack deploy names the service "<release>_whoami".
set -euo pipefail

release="$1"

docker run --rm --network traefik-public curlimages/curl:latest \
  -fsS --max-time 10 "http://${release}_whoami:80" >/dev/null
