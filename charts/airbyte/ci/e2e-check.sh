#!/usr/bin/env bash
#
# e2e smoke check for the airbyte chart, run by scripts/e2e-test.sh after the release
# converges:   $1 = release name   $2 = chart directory   $3 = fixture case name
#
# Convergence proves little here: every Airbyte service reports Running long before it
# serves, and the workload launcher is Running while it still waits for the dataplane
# credentials. So this drives the one path that crosses every part of the chart — a
# connection check for source-faker. The server hands it to a worker through Temporal, the
# launcher claims it with the credentials FakeK8s stored in Postgres, and FakeK8s turns the
# pod into Docker containers whose output lands in MinIO. On the way it also asserts that
# the server serves the UI and that oauth2-proxy stands in front of it (mock), or, with
# auth.mode none (noauth), that Traefik's basic auth stands in front of the server and the
# connector builder.
#
# Runs from a throwaway node:22-alpine container on the release's attachable overlay; node's
# core http has no response timeout, and the check waits on image pulls.
set -euo pipefail

release="$1"
case="${3:-}"

docker run --rm -i --network "${release}_airbyte" -e RELEASE="$release" -e CASE="$case" node:22-alpine \
  node --input-type=module - <<'JS'
import http from 'node:http';

const server = `http://${process.env.RELEASE}_server:8001`;
const proxy = `http://${process.env.RELEASE}_oauth2-proxy:4180`;
const FAKER = 'dfd88b22-b603-4c3d-aad7-3701784586b1';        // source-faker, in Airbyte's seed registry
const DEFAULT_ORG = '00000000-0000-0000-0000-000000000000';   // the bootloader's default workspace lives here

function request(url, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const req = http.request(url, {
      method: data === undefined ? 'GET' : 'POST',
      headers: data === undefined ? {} : { 'Content-Type': 'application/json' },
    }, (res) => {
      let text = '';
      res.on('data', (c) => { text += c; });
      res.on('end', () => resolve({ status: res.statusCode, text }));
    });
    req.on('error', reject);
    req.end(data);
  });
}

async function until(what, probe, seconds) {
  const deadline = Date.now() + seconds * 1000;
  let last = '';
  while (Date.now() < deadline) {
    try { if (await probe()) return; } catch (e) { last = e.message; }
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error(`${what}: not within ${seconds}s ${last}`);
}

await until('server health', async () => {
  const r = await request(`${server}/api/v1/health`);
  return r.status === 200 && JSON.parse(r.text).available === true;
}, 600);
console.log('  server: healthy');

const ui = await request(`${server}/`);
if (ui.status !== 200 || !/<html/i.test(ui.text)) throw new Error(`server UI: HTTP ${ui.status}`);
console.log('  server: serves the UI');

if (process.env.CASE !== 'noauth') {
  const gate = await request(`${proxy}/`);
  if (gate.status !== 403 && gate.status !== 302) throw new Error(`oauth2-proxy let an anonymous request through: HTTP ${gate.status}`);
  console.log(`  oauth2-proxy: anonymous request refused (HTTP ${gate.status})`);
}

const list = await request(`${server}/api/v1/workspaces/list_by_organization_id`, { organizationId: DEFAULT_ORG });
if (list.status !== 200) throw new Error(`workspaces: HTTP ${list.status} ${list.text}`);
const workspaceId = JSON.parse(list.text).workspaces[0].workspaceId;

const check = await request(`${server}/api/v1/scheduler/sources/check_connection`, {
  workspaceId, sourceDefinitionId: FAKER, connectionConfiguration: { count: 10 },
});
if (check.status !== 200) throw new Error(`check_connection: HTTP ${check.status} ${check.text}`);
const result = JSON.parse(check.text);
if (result.status !== 'succeeded') throw new Error(`check_connection: ${result.status} ${result.message || ''}`);
console.log('  source-faker check_connection: succeeded');
JS

# auth.mode none: through the traefik edge, basic auth refuses an anonymous request, and an
# authenticated one reaches the server's API and UI and the connector builder's own router.
if [ "$case" = "noauth" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  edge_assert_routed airbyte.e2e.test /api/v1/health 401 || exit 1
  for path in /api/v1/health / /api/v1/connector_builder/health; do
    code=""
    for _ in $(seq 1 30); do
      code="$(docker run --rm --network "$EDGE_NETWORK" "$EDGE_CURL_IMAGE" -s -o /dev/null \
        -w '%{http_code}' --max-time 15 -u e2e:e2e-secret -H 'Host: airbyte.e2e.test' \
        "http://${EDGE_TARGET}:80$path" 2>/dev/null || true)"
      [ "$code" = 200 ] && break
      sleep 3
    done
    [ "$code" = 200 ] || { echo "  FAIL: authenticated $path through the edge returned ${code:-<none>}, not 200"; exit 1; }
    echo "  edge: authenticated $path -> HTTP 200"
  done
fi

# The check can only succeed through FakeK8s; show it from the launcher's own log as well.
# Captured to a file and matched with -F rather than piped: `docker service logs` can lag the
# process, so retry for a while.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
for _ in $(seq 1 12); do
  docker service logs --raw "${release}_workload-launcher" >"$log" 2>&1 || true
  if grep -F 'DONE  phase=Succeeded' "$log" >/dev/null; then
    echo "  workload-launcher: $(grep -F 'DONE  phase=Succeeded' "$log" | sed -n 1p | sed 's/^.*POD /FakeK8s ran pod /')"
    # Fabric8 cancelling a pod watch must not trip okio's timeout check (see FakeK8s sendWatch).
    if grep -F 'Unbalanced enter/exit' "$log" >/dev/null; then
      echo "  FAIL: the launcher log shows $(grep -cF 'Unbalanced enter/exit' "$log") 'Unbalanced enter/exit' trace(s) from a cancelled watch"
      exit 1
    fi
    exit 0
  fi
  sleep 5
done
echo "  FAIL: the launcher log shows no pod FakeK8s ran to success"
exit 1
