# Testing charts end-to-end locally

This repo has **two** test loops. Most of the time you only need the first; reach
for the second when you want to prove a chart actually *runs*, not just that it
renders.

| Loop | Command | Needs a Swarm? | What it proves | Runs in CI? |
|------|---------|----------------|----------------|-------------|
| **Data-only** (`== CI`) | `make test` | no | the template renders to a valid stack | yes |
| **End-to-end** | `make e2e` | **yes** | the stack deploys, converges, and serves | partly — see below |

`make test` is covered in [CONTRIBUTING.md](../CONTRIBUTING.md#testing-locally--ci):
it renders each chart against its `ci/*-values.yaml` fixtures, runs the
`<no value>` guard, `docker compose config`, the security scan, and the
requirements check. It never deploys anything, so it is fast and fork-safe — and
it is exactly what the `charts.yml` workflow runs.

`make e2e` goes the rest of the way: it **deploys each fixture to a real Docker
Swarm**, waits for the services to converge, optionally smoke-tests them, and
tears the release back down. It needs a running Swarm and pulls real images.

Both loops render with **one** swarmcli — whatever `install-swarmcli.sh` built,
which is `main`. Neither proves a chart runs on the *released* swarmcli a user
actually has. That third, orthogonal question has its own check — see
[Verifying the swarmcli floor](#verifying-the-swarmcli-floor).

The `e2e.yml` workflow runs this loop **in CI** on a throwaway single-node swarm
(`E2E_SWARM_INIT=1`), as **one job per chart** (a `strategy.matrix`, so charts run in
parallel and in isolation). Each job runs a **curated fixture subset** (via `E2E_CASES`,
below) — the cheap "does it deploy and come up" smoke — while the **full** local
`make e2e` still runs *every* fixture. It stays fork-safe because it uses only public
images and dummy on-runner secrets, never a repo secret. **Add a chart to CI** with one
`matrix.include` line `{chart, cases, timeout}`, plus `ci/e2e-setup.sh` /
`ci/e2e-teardown.sh` (see [Setup / teardown hooks](#setup--teardown-hooks-cie2e-setupsh))
only if the chart needs external resources — charts that converge solo (whoami,
swarm-cronjob) need no hooks.

> **It tests your working tree, not a published chart.** `make e2e` installs the
> chart straight from its local directory (`./charts/<name>`), so you can validate
> a chart you are *still editing* — **before you commit, open a PR, or release
> anything**. Nothing has to be packaged, tagged, or pushed first. (Mechanically,
> swarmcli resolves any chart reference that exists as a local path directly; only
> a `repo/chart` reference falls back to a published `index.yaml`. See
> [Manual lifecycle walkthrough](#manual-lifecycle-walkthrough).)

## Prerequisites

- Everything `make test` needs (`make install-tools` builds the swarmcli
  renderer and reports any missing helpers).
- **A Docker Swarm.** A single node is enough:

  ```bash
  docker swarm init                 # make this host a one-node manager
  docker info --format '{{.Swarm.LocalNodeState}}'   # -> active
  ```

  > To undo it later: `docker swarm leave --force`.

That is all — no registry and no multi-node cluster. Charts pull images from
their public registries (ghcr.io, docker.io) directly.

## Quick start

```bash
make e2e                 # deploy + verify every chart × fixture, then tear down
make e2e CHART=whoami    # just one chart
```

A run looks like:

```
── whoami [default]  (release: e2e-whoami-default)
   smoke: ci/e2e-check.sh
   OK
...
All charts deployed, converged, and tore down cleanly.
```

Tunables (env vars):

- `E2E_TIMEOUT` — convergence wait per release (default `3m`). Raise it on a slow
  link where image pulls dominate: `E2E_TIMEOUT=10m make e2e`.
- `E2E_SWARM_INIT=1` — let the harness run `docker swarm init` for you when no
  swarm is active (handy for throwaway VMs/CI runners; off by default because it
  mutates global Docker state).
- `E2E_CASES` — space/comma-separated fixture **case** names to run (the `<case>` in
  `ci/<case>-values.yaml`); unset ⇒ every fixture (the `make e2e` default). CI sets a
  curated subset per chart; run one case locally with e.g.
  `E2E_CASES=default make e2e CHART=redis`. A set `E2E_CASES` that matches no fixture for
  a chart fails loudly (guards against a typo silently passing green).

## What `make e2e` does

For every chart × `ci/*-values.yaml` fixture, `scripts/e2e-test.sh`:

1. **pre-cleans** — uninstalls any leftover `e2e-<chart>-<case>` release (and runs
   the teardown hook) from a prior crashed run.
2. **sets up (optional)** — if `charts/<chart>/ci/e2e-setup.sh` is executable, runs
   it *before* install to provision external prerequisites swarmcli validates but
   never creates (external secrets, node labels, a co-located backend). See
   [Setup / teardown hooks](#setup--teardown-hooks-cie2e-setupsh).
3. **installs and converges** — `swarmcli charts install <release> ./charts/<chart> -f <fixture> --wait`,
   straight from your local working-tree directory (no packaging or publishing). A
   non-zero exit (rejected manifest, failed pre-flight) fails the case. swarmcli
   auto-creates any external attachable overlay the chart declares in
   `requirements.yaml` (e.g. `traefik-public`).
4. **waits for convergence** — the same step: `--wait --timeout $E2E_TIMEOUT`
   (default `3m`; raise it for slow image pulls). swarmcli holds until every task
   is actually `Running` on an active node and has survived swarm's own monitor
   window, and it treats a completed one-shot service as converged rather than
   waiting for a task that will never come back.
5. **smoke-tests (optional)** — if `charts/<chart>/ci/e2e-check.sh` is
   executable, runs it (with the case name as `$3`); a non-zero exit fails the case.
6. **tears down** — `swarmcli charts uninstall <release> --purge-volumes` plus the
   optional `ci/e2e-teardown.sh`, always, even when a step above failed.

The run exits non-zero if any case failed. Because every release is torn down,
repeated runs are idempotent and leave no stacks behind.

## Manual lifecycle walkthrough

When something fails and you want to poke at a live release, drive the same
commands the harness wraps (using the built renderer at `.swarmcli-bin/swarmcli`,
or `swarmcli` if it is on your `PATH`):

```bash
BIN=.swarmcli-bin/swarmcli

# Deploy from the local chart directory.
$BIN charts install demo ./charts/whoami \
  -f charts/whoami/ci/default-values.yaml

# Watch the tasks actually come up (Pending -> Preparing -> Running).
docker stack ps demo               # task-level state (start here when stuck)

# Inspect it.
$BIN charts status demo            # release + services overview
$BIN charts list                   # all releases
docker service logs demo_whoami    # service logs (note the <release>_<service> name)

# Change values and preview / apply an upgrade.
$BIN charts diff upgrade demo ./charts/whoami --set replicas=3
$BIN charts upgrade   demo ./charts/whoami --set replicas=3

# Roll back to a previous revision, then remove it.
$BIN charts history  demo
$BIN charts rollback demo 1
$BIN charts uninstall demo --purge-volumes
```

> **On `--wait`.** `swarmcli charts install/upgrade` accept `--wait`, which is
> what `make e2e` uses to decide a release is up. It needs **swarmcli >=
> v1.13.0-rc4**: earlier builds counted tasks by *desired* state, so it returned
> while they were still `Pending` (Eldara-Tech/swarmcli#473), and a one-shot
> service hung it until the timeout (#443). Against an older binary, watch
> `docker stack ps <release>` by hand instead.

> Installing from a published repo instead of a local path uses a
> `<repo>/<chart>` reference, e.g.
> `swarmcli charts install demo swarmcli-charts/whoami` (see the
> [README](../README.md#usage)). For chart development you install the **local
> directory** (`./charts/<name>`) so your edits are picked up without packaging.

## Writing a smoke check (`ci/e2e-check.sh`)

A smoke check is an **optional**, executable `charts/<name>/ci/e2e-check.sh`. The
harness runs it after the release converges and treats a non-zero exit as a
failure. Contract:

- `$1` — the release name, which is also the Docker **stack** name. Stack deploy
  prefixes service names, so a service `web` is reachable as `<release>_web`.
- `$2` — the chart directory.
- `$3` — the fixture case name (the `<case>` in `ci/<case>-values.yaml`), so one
  check can assert fixture-specific behaviour.
- Exit `0` for healthy, non-zero to fail the case.

Keep it self-contained and side-effect-free (use `--rm` throwaway containers).
The `whoami` chart ships a real example — `charts/whoami/ci/e2e-check.sh` — that
curls the service directly over its overlay (Traefik is not running in a bare
local swarm, so it tests the service, not ingress):

```bash
docker run --rm --network traefik-public curlimages/curl:latest \
  -fsS --max-time 10 "http://${release}_whoami:80" >/dev/null
```

Charts without a hook (e.g. `swarm-cronjob`) are verified by convergence alone.

## Setup / teardown hooks (`ci/e2e-setup.sh`)

Some charts need external resources swarmcli **validates but never creates** — an
operator-supplied secret, a node label a placement pin requires, a co-located
backend service — so the install pre-flight fails without them. Provide them with
two **optional**, executable per-chart hooks the harness runs around each fixture:

- `charts/<name>/ci/e2e-setup.sh <release> <chart-dir> <case>` — runs **before**
  install. A non-zero exit fails the case (and teardown still runs). Make it
  **idempotent** (every create tolerates "already exists"): the harness also runs
  it after pre-clean, and a crashed run may leave resources behind.
- `charts/<name>/ci/e2e-teardown.sh <release> <chart-dir> <case>` — runs **after**
  the release is uninstalled. Best-effort (tolerate already-gone resources); remove
  exactly what setup created, but **leave shared overlays** like `traefik-public`
  (other releases use them).

The `openclaw` chart is the reference: its setup creates the dummy gateway-token
secret and the persistence node label for every fixture, and — for the `backend`
fixture — stands up a mock Ollama backend (`ci/mock-ollama.js` shipped as a swarm
config) on an `ai-internal` overlay, which `ci/e2e-check.sh` then proves the
gateway reaches once OpenClaw is pointed at it via config.

These hooks are what let the `e2e.yml` workflow run a chart's e2e in CI without
any repo secrets: everything the fixture needs is public images plus these
on-runner, dummy-valued resources.

Charts shipping these hooks today: **openclaw** (the reference above); **redis**, **mariadb**
and **postgres** (dummy auth secret(s) + the persistence node-label pin + the bind-mount host
dir); **traefik** (the `traefik-certs` node-label pin + the certs-bind-mount host dir);
and **keycloak** (the two operator secrets + the DB/ingress overlays + a throwaway
co-located backend on `keycloak-db-net` — MariaDB, or PostgreSQL for the `postgres` fixture —
because Keycloak attaches its DB overlay unconditionally and `/health/ready` only passes once
it has connected and migrated, so every keycloak fixture needs a reachable database); and
**vaultwarden** (the four dummy secrets + the data node label for every fixture, plus a
throwaway PostgreSQL/MariaDB named `vw-postgres`/`vw-mariadb` for the `postgres`/`mysql`
fixtures — deliberately *not* the plain `postgres`/`mariadb` names the keycloak and superset
hooks use, so the two never collide).
`whoami` and `swarm-cronjob` converge solo and ship no hooks.

> **Asserting what the secret wrapper actually produced.** Several charts export a
> credential from an `sh -c` wrapper that reads `/run/secrets/…` with a compose-escaped
> `$$(cat …)`. If that escape is ever eaten, the shell expands `$$` to its own pid and the
> app runs holding the literal `1(cat /run/secrets/…)` — and still converges, because the
> value only fails later, inside the application. `docker exec` shows the image + service
> environment, **not** the wrapper's exports, so the only place the real value is visible is
> PID 1's environment. `charts/vaultwarden/ci/e2e-check.sh` reads
> `/proc/1/environ` and asserts the exact expected `DATABASE_URL` / `ADMIN_TOKEN` /
> `SMTP_PASSWORD`, which is what turns "it came up" into "it came up on the configured
> backend". Do the same in a new chart's check rather than trusting convergence alone.

### Proving Traefik actually routes (the shared edge helper)

The data-only render proves a routed chart *emits* the right `traefik.*` deploy labels, but
not that Traefik **discovers and routes to** it — the "renders fine, silently 404s/502s at
the edge" footgun in [CLAUDE.md](../CLAUDE.md) (wrong/absent constraint-label ⇒ never
discovered). `scripts/e2e-edge/traefik-edge.sh` is a **sourced** helper (not executed —
hooks `. ` it) that stands up the in-repo **traefik** chart as a real edge and asserts an
HTTP request routes *through* it, so the label/discovery contract is exercised at runtime.
Two fixtures consume it:

- **openclaw** and **keycloak** ship an `edge` fixture. Their `ci/e2e-setup.sh` calls
  `edge_up` (installs traefik on `traefik-public` with the dashboard off and a dummy ACME
  email, keeping the default `:80/:443` host ports), and `ci/e2e-check.sh` calls
  `edge_assert_routed <host> <path>` — a curl through the edge with a matching `Host:`
  header must return 200 from the app (`/healthz` for openclaw, `/realms/master` for
  keycloak) — plus `edge_assert_unrouted` for an unknown host (404). The fixture sets
  `ingress.tls: false` so the `http`-entrypoint router forwards straight to the app (no
  HTTPS/ACME router exists in CI). `ci/e2e-teardown.sh` calls `edge_down`.
- **traefik** ships a `routing` fixture where traefik itself is the chart under test: its
  `ci/e2e-setup.sh` uses `edge_whoami_up` to stand up two `whoami` backends — one correctly
  labelled, one **missing only the constraint label** — and `ci/e2e-check.sh` asserts the
  first routes (200) while the second is never discovered (404), reproducing the footgun
  for real.

All curls run from a throwaway `--rm` container on `traefik-public` and hit the traefik
service VIP with an explicit `Host:` header (a bare swarm has no DNS; the header is what
drives Traefik's router rules). Real ACME/TLS is out of reach in CI (no public DNS or cert
issuance), so this verifies **HTTP routing and label discovery**, not certificate
resolution — plain HTTP only.

Some fixtures are deliberately **excluded from the curated CI subset** (they still run in a
full local `make e2e`): `traefik`'s `loki-logging` needs the `loki:latest` Docker
log-driver plugin, which stock runners lack (`docker plugin install
grafana/loki-docker-driver:latest --alias loki:latest --grant-all-permissions` to run it
locally); and `mariadb`'s `bind-mount`, because MariaDB's healthcheck cannot authenticate on a
host bind-mounted datadir in the Swarm CI environment (it works on a named volume, so the
other mariadb fixtures pass, and the host-path render is covered by `charts.yml`). The
`postgres` chart's own `bind-mount` fixture *does* run in CI: its `PGDATA` sits one level below
the mount (`/var/lib/postgresql/<major>/docker`), so initdb never has to chown or empty the
bind-mounted mountpoint itself.

A fixture that can converge **nowhere** — not in CI and not locally — belongs in
`charts/<name>/ci/e2e-render-only` instead (one case name per line): the default sweep skips
it, `scripts/test-charts.sh` still renders it, and naming it explicitly in `E2E_CASES` still
forces it. `keycloak` lists `jdbc-url` (its JDBC URL demands `ssl=require`, and the stock
postgres image ships `ssl=off`; it also carries a `node.labels.keycloak == true` constraint no
e2e node has) and `published-tls` (needs real PEM material). Keycloak's `postgres` fixture, by
contrast, now runs in CI — `ci/e2e-setup.sh` stands up a throwaway PostgreSQL backend for it
(issue #69).

## Trying a chart through the repo flow (local repo)

`make e2e` and `install ./charts/<name>` both load a chart from its **local
directory**. They do not exercise the path a real user takes — `repo add` →
`search` → `install <repo>/<chart>` — which also depends on the chart **packaging
and its index entry** resolving correctly. To dogfood that consumer flow against a
chart you have **not published yet**, stand up a throwaway local repo:

```bash
make local-repo                 # all charts
make local-repo CHART=whoami    # just one
```

That packages the working-tree chart(s), writes an `index.yaml` with relative
tarball URLs, and serves `./.localrepo/` over HTTP (a throwaway `nginx` container)
on `http://localhost:8879`. It **blocks** — leave it running and, in another
terminal:

```bash
# swarmcli refuses plaintext repositories by default; this one is a throwaway
# container on loopback. Export it — the scheme is re-checked on every fetch, so
# opting in on `repo add` alone would only move the refusal to `install`.
export SWARMCLI_CHARTS_ALLOW_PLAINTEXT=1
swarmcli charts repo add localrepo http://localhost:8879
swarmcli charts repo update
swarmcli charts search                                   # lists localrepo/<chart>
swarmcli charts install demo localrepo/whoami --wait
docker stack ps demo                                     # confirm it is Running

# cleanup
swarmcli charts uninstall demo --purge-volumes
swarmcli charts repo remove localrepo
# then Ctrl-C the `make local-repo` terminal (the container is auto-removed)
```

> **Why HTTP and not a path?** swarmcli requires repository URLs to be **http(s)**
> — `file://` and bare filesystem paths are rejected by design — so the charts are
> served over `http://localhost`. Override the port with `LOCALREPO_PORT`. This is
> only for trying the repo UX locally; real distribution goes through a tagged
> release (see the [README](../README.md#releasing-a-new-chart-version)).

> **Why the opt-in?** A repository serves the tarball that *becomes* the deployed
> workload, and the index digest that would attest it travels the same connection —
> so swarmcli refuses plain `http://` unless `SWARMCLI_CHARTS_ALLOW_PLAINTEXT=1`
> (Eldara-Tech/swarmcli#531). A throwaway container on loopback is exactly the
> "internal registry on a network you already trust" the escape hatch names. Never
> set it for a repository reached over a real network.

> **Regression-tested in CI.** The `Integration` workflow runs
> `scripts/local-repo-test.sh`, which stands this server up and asserts
> `repo add` → `update` → `search` lists every chart — so the packaging + index +
> serving path stays green on every PR (no swarm needed). You can run it locally
> too: `SWARMCLI=.swarmcli-bin/swarmcli scripts/local-repo-test.sh`. A Linux runner
> can't reproduce Docker-Desktop/WSL2 serving quirks, so still smoke `make
> local-repo` by hand once on macOS/Windows when you touch the serving path.

## Verifying the swarmcli floor

Every `Chart.yaml` declares `swarmcliVersion` — the oldest swarmcli whose chart
engine renders that chart:

```yaml
# Chart.yaml
swarmcliVersion: ">= 1.11.0"
```

This matters because `make test` and CI render with swarmcli **`main`**, which is
newer than anything a user has installed. A chart can quietly depend on
behaviour that only exists on `main` and still pass every render check — and then
fail on the released swarmcli a user actually runs. That is not hypothetical:
`charts/zammad` uses template control flow in `requirements.yaml` (a feature on
`main`, in no release yet), so it renders in CI and fails on *every* release with
an opaque `parse requirements.yaml: could not find expected ':'`.

**`scripts/floor-check.sh` proves a floor** by building a *real* binary of the
declared version and rendering the chart with it — the only thing that settles
whether the chart runs there. It runs in the `Charts` workflow, and locally:

```bash
scripts/floor-check.sh          # render every chart with a real binary of its floor
```

Expect one `rendering with real swarmcli vX.Y.Z → OK` block per chart, then a
summary. It **fails** (exit 1) if a chart does not run on the version it declares.

- **Raise a floor only to a *released* version.** floor-check builds that version
  to test it, so a floor naming an unreleased tag cannot be proven: it is
  reported as `NOT verified` (with a `::warning::`) and skipped — visible in the
  log, never silently passed. `zammad` is in that state today (`>= 1.13.0`, which
  documents *why* it cannot publish yet) and will verify automatically once that
  release ships.
- **Find a floor by measuring, not guessing.** Render the chart against
  successively older releases (`SWARMCLI_REF=vX.Y.Z scripts/install-swarmcli.sh
  ./bin` then `make test`); the oldest that still renders is the floor.
- **`swarmcli charts lint --for-version X`** is the quick check — but know its
  limit: it tests whether the chart's declared floor *admits* X, i.e. the claim's
  shape, not whether the chart *runs* on X. A swarmcli carries one engine's
  behaviour and cannot emulate another's; only floor-check (a real binary)
  proves runs-on.
- **The floor protects users going forward, not retroactively.** A swarmcli older
  than the check itself parses `Chart.yaml` leniently and ignores `swarmcliVersion`
  entirely; only swarmcli new enough to carry the check enforces it. See the
  `swarmcli floor` note in [CLAUDE.md](../CLAUDE.md).

## Troubleshooting

- **`not a Docker Swarm manager` / exit 2** — run `docker swarm init` (or
  `E2E_SWARM_INIT=1 make e2e`).
- **Install times out / never converges** — read `docker service logs
  <release>_<service>` and `docker stack ps <release> --no-trunc` (the `Error`
  column explains rejected tasks). Common causes: image pull failures/typos, or a
  placement constraint no node satisfies. Raise `E2E_TIMEOUT` if it is just a slow
  pull.
- **`requirements.yaml` pre-flight fails** — a network marked `autoCreate: false`
  must be created by hand first
  (`docker network create --driver overlay --attachable <name>`); secrets/configs
  are never auto-created (`docker secret create …` / `docker config create …`).
  See [CONTRIBUTING.md](../CONTRIBUTING.md#external-resources-requirementsyaml).
- **A release is stuck after a crash** — `swarmcli charts uninstall <release>
  --purge-volumes`, or drop to Docker: `docker stack rm <release>`.

## Cleanup

The harness removes every release it creates. To tidy up after manual sessions:

```bash
swarmcli charts uninstall <release> --purge-volumes   # release + its volumes
docker network rm traefik-public                       # auto-created shared overlay (if unused)
docker swarm leave --force                              # only if you initialised a throwaway swarm
```
