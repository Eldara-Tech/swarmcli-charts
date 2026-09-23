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
# the server serves the UI and what guards it: oauth2-proxy (mock), Traefik's basic auth with
# auth.mode none (noauth), or Airbyte's own login with auth.mode airbyte (login).
#
# Runs from a throwaway node:22-alpine container on the release's attachable overlay; node's
# core http has no response timeout, and the check waits on image pulls.
set -euo pipefail

release="$1"
case="${3:-}"

# login goes through the traefik edge like a browser; the others talk to the server directly.
net="${release}_airbyte"
if [ "$case" = "login" ]; then
  . "$2/../../scripts/e2e-edge/traefik-edge.sh"
  net="$EDGE_NETWORK"
fi

docker run --rm -i --network "$net" -e RELEASE="$release" -e CASE="$case" \
  -e EDGE_TARGET="${EDGE_TARGET:-}" node:22-alpine \
  node --input-type=module - <<'JS'
import http from 'node:http';

const login = process.env.CASE === 'login';
// login: every request goes through the edge with the public Host header, the UI's path.
const server = login ? `http://${process.env.EDGE_TARGET}:80` : `http://${process.env.RELEASE}_server:8001`;
const host = login ? { Host: 'airbyte.e2e.test' } : {};
const proxy = `http://${process.env.RELEASE}_oauth2-proxy:4180`;
const FAKER = 'dfd88b22-b603-4c3d-aad7-3701784586b1';        // source-faker, in Airbyte's seed registry
const DEFAULT_ORG = '00000000-0000-0000-0000-000000000000';   // the bootloader's default workspace lives here
const ADMIN_EMAIL = 'e2e@example.com';
const ADMIN_PASSWORD = 'e2e-admin-password';                 // == ci/e2e-setup.sh airbyte_admin_password

let cookie = '';  // login: the JWT cookie of the last /api/login

function request(url, body, { anonymous = false } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const headers = { ...host };
    if (data !== undefined) headers['Content-Type'] = 'application/json';
    if (cookie && !anonymous) headers.Cookie = cookie;
    const req = http.request(url, { method: data === undefined ? 'GET' : 'POST', headers }, (res) => {
      let text = '';
      res.on('data', (c) => { text += c; });
      res.on('end', () => resolve({ status: res.statusCode, text, headers: res.headers }));
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

// Airbyte's access token lives three minutes, so log in again before each authenticated step.
async function signIn() {
  if (!login) return;
  const r = await request(`${server}/api/login`, { username: ADMIN_EMAIL, password: ADMIN_PASSWORD }, { anonymous: true });
  const jwt = (r.headers['set-cookie'] || []).map((c) => c.split(';')[0]).find((c) => c.startsWith('JWT='));
  if (r.status !== 200 || !jwt) throw new Error(`login: HTTP ${r.status}, no JWT cookie ${r.text}`);
  cookie = jwt;
}

await until('server health', async () => {
  const r = await request(`${server}/api/v1/health`);
  return r.status === 200 && JSON.parse(r.text).available === true;
}, 600);
console.log('  server: healthy');

const ui = await request(`${server}/`);
if (ui.status !== 200 || !/<html/i.test(ui.text)) throw new Error(`server UI: HTTP ${ui.status}`);
console.log('  server: serves the UI');

if (process.env.CASE === 'mock') {
  const gate = await request(`${proxy}/`);
  if (gate.status !== 403 && gate.status !== 302) throw new Error(`oauth2-proxy let an anonymous request through: HTTP ${gate.status}`);
  console.log(`  oauth2-proxy: anonymous request refused (HTTP ${gate.status})`);
}

if (login) {
  const anon = await request(`${server}/api/v1/workspaces/list_by_organization_id`, { organizationId: DEFAULT_ORG });
  if (anon.status !== 401) throw new Error(`anonymous API call: HTTP ${anon.status}, expected 401`);
  console.log('  airbyte login: anonymous API call refused (HTTP 401)');

  // The first visitor's setup screen names the login email.
  const setup = await request(`${server}/api/v1/instance_configuration/setup`, {
    email: ADMIN_EMAIL, anonymousDataCollection: false, initialSetupComplete: true, displaySetupWizard: false,
  });
  if (setup.status !== 200) throw new Error(`instance setup: HTTP ${setup.status} ${setup.text}`);

  const wrong = await request(`${server}/api/login`, { username: ADMIN_EMAIL, password: 'wrong' }, { anonymous: true });
  if (wrong.status !== 401) throw new Error(`login with a wrong password: HTTP ${wrong.status}, expected 401`);
  await signIn();
  console.log('  airbyte login: wrong password refused, admin password accepted');

  // The UI calls the connector builder directly with the JWT cookie, never a bearer token.
  const resolve = `${server}/api/v1/connector_builder/manifest/resolve`;
  const builderAnon = await request(resolve, { manifest: {} }, { anonymous: true });
  if (builderAnon.status !== 401) throw new Error(`anonymous connector builder call: HTTP ${builderAnon.status}, expected 401`);
  const builder = await request(resolve, { manifest: {} });
  if (builder.status === 401 || builder.status === 403) throw new Error(`connector builder refused the login cookie: HTTP ${builder.status}`);
  console.log(`  connector builder: anonymous refused (401), login cookie accepted (HTTP ${builder.status})`);
}

await signIn();
const list = await request(`${server}/api/v1/workspaces/list_by_organization_id`, { organizationId: DEFAULT_ORG });
if (list.status !== 200) throw new Error(`workspaces: HTTP ${list.status} ${list.text}`);
const workspaceId = JSON.parse(list.text).workspaces[0].workspaceId;

// The server reports healthy once the schemas are migrated, which can be before db-migrations
// has finished seeding the connector registry.
await until('source-faker definition seeded', async () => {
  await signIn();
  return (await request(`${server}/api/v1/source_definitions/get`, { sourceDefinitionId: FAKER })).status === 200;
}, 600);

await signIn();
const check = await request(`${server}/api/v1/scheduler/sources/check_connection`, {
  workspaceId, sourceDefinitionId: FAKER, connectionConfiguration: { count: 10 },
});
if (check.status !== 200) throw new Error(`check_connection: HTTP ${check.status} ${check.text}`);
const result = JSON.parse(check.text);
if (result.status !== 'succeeded') throw new Error(`check_connection: ${result.status} ${result.message || ''}`);
console.log('  source-faker check_connection: succeeded');

// Airbyte's setup endpoint is anonymous; record whether it still accepts a new login email once
// setup is complete. Last on purpose: if it does, the admin email above no longer signs in.
if (login) {
  const again = await request(`${server}/api/v1/instance_configuration/setup`, {
    email: 'second-visitor@example.com', anonymousDataCollection: false, initialSetupComplete: true, displaySetupWizard: false,
  }, { anonymous: true });
  console.log(`  note: anonymous setup after setup -> HTTP ${again.status}`);
}
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
