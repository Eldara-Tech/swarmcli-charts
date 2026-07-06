#!/usr/bin/env bash
#
# Optional e2e smoke check for the openclaw chart. scripts/e2e-test.sh runs this after
# the release converges:
#   $1 = release name (== Docker stack name)   $2 = chart directory
# Exit 0 = healthy, non-zero = failure.
#
# It is run once per fixture, so it probes the running gateway container rather than
# assuming a particular exposure mode: it locates the task container for service
# "<release>_gateway" (a local e2e swarm is single-node) and asks node's global fetch to
# hit /healthz from inside the container — the same call the chart's healthcheck uses, so
# it needs neither curl (absent from the image) nor the operator's gateway token.
#
# PREREQUISITES (scripts/e2e-test.sh sets these up):
#   docker node update --label-add openclaw-data=true <node>
#   printf test | docker secret create openclaw_gateway_token -
set -euo pipefail

release="$1"
cid="$(docker ps -q -f "label=com.docker.swarm.service.name=${release}_gateway" | head -1)"
[ -n "$cid" ] || { echo "  ${release}_gateway container not found"; exit 1; }

docker exec "$cid" node -e \
  "fetch('http://127.0.0.1:18789/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

echo "  ${release}_gateway: /healthz OK"
