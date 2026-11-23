#!/usr/bin/env bash
#
# e2e teardown for the kafka chart. scripts/e2e-test.sh runs this AFTER it uninstalls
# the release, once per fixture:
#   $1 = release name   $2 = chart directory   $3 = fixture case name
# It removes exactly what ci/e2e-setup.sh created (the three secrets, the five peer
# node labels and, for the traefik fixture, the edge). The shared kafka-net and
# monitoring overlays are LEFT in place, like the other charts' hooks. Best-effort:
# every step tolerates already-gone resources.
set -uo pipefail

if [ "$3" = traefik ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/e2e-edge/traefik-edge.sh"
  edge_down || true
fi

# The users one-shot and the exporter hold these too; the uninstall that ran first has
# removed them, but Swarm frees a secret only once their tasks are gone.
for s in kafka_internal_password kafka_app_password kafka_exporter_password; do
  for _ in 1 2 3 4 5 6; do
    docker secret rm "$s" >/dev/null 2>&1 && break
    docker secret inspect "$s" >/dev/null 2>&1 || break
    sleep 5
  done
done

node="$(docker node ls --format '{{.ID}} {{.Self}}' 2>/dev/null | awk '$2=="true"{print $1; exit}')"
[ -n "$node" ] || node="$(docker node ls -q 2>/dev/null | sed -n 1p)"
if [ -n "$node" ]; then
  for i in 1 2 3 4 5; do
    docker node update --label-rm "kafka-$i" "$node" >/dev/null 2>&1 || true
  done
fi

exit 0
