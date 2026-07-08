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
3. **installs** — `swarmcli charts install <release> ./charts/<chart> -f <fixture>`,
   straight from your local working-tree directory (no packaging or publishing). A
   non-zero exit (rejected manifest, failed pre-flight) fails the case. swarmcli
   auto-creates any external attachable overlay the chart declares in
   `requirements.yaml` (e.g. `traefik-public`).
4. **waits for convergence** — polls `docker stack ps` until every task whose
   desired state is `running` actually reads `Running`, up to `$E2E_TIMEOUT`
   (default `3m`; raise it for slow image pulls). It deliberately does **not** use
   swarmcli's `--wait`, which reports a service converged as soon as its tasks are
   *scheduled* (desired-state Running) — not when they are actually running — so on
   a cold image pull `--wait` returns while tasks are still `Pending`.
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

> **On `--wait`.** `swarmcli charts install/upgrade` accept `--wait`, but it
> reports convergence as soon as the tasks are *scheduled* (their desired state is
> Running), which on a cold image pull happens while they are still `Pending`. To
> confirm a release is really up, watch `docker stack ps <release>` until every
> task reads `Running` — which is what `make e2e` does for you.

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

Charts shipping these hooks today: **openclaw** (the reference above); **redis** and
**mariadb** (dummy auth secret(s) + the persistence node-label pin + the bind-mount host
dir); **traefik** (the `traefik-certs` node-label pin + the certs-bind-mount host dir);
and **keycloak** (the two operator secrets + the DB/ingress overlays + a throwaway
co-located MariaDB backend on `keycloak-db-net`, because Keycloak attaches its DB overlay
unconditionally and `/health/ready` only passes once it has connected and migrated — so
every keycloak fixture needs a reachable database). `whoami` and `swarm-cronjob` converge
solo and ship no hooks.

Some fixtures are deliberately **excluded from the curated CI subset** (they still run in a
full local `make e2e`): `traefik`'s `loki-logging` needs the `loki:latest` Docker
log-driver plugin, which stock runners lack (`docker plugin install
grafana/loki-docker-driver:latest --alias loki:latest --grant-all-permissions` to run it
locally); `mariadb`'s `bind-mount`, because MariaDB's healthcheck cannot authenticate on a
host bind-mounted datadir in the Swarm CI environment (it works on a named volume, so the
other mariadb fixtures pass, and the host-path render is covered by `charts.yml`); and
`keycloak`'s `postgres` / `jdbc-url` (need PostgreSQL) and `published-tls` (needs real PEM
cert material) fall outside the MariaDB-backed CI subset.

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

> **Regression-tested in CI.** The `Integration` workflow runs
> `scripts/local-repo-test.sh`, which stands this server up and asserts
> `repo add` → `update` → `search` lists every chart — so the packaging + index +
> serving path stays green on every PR (no swarm needed). You can run it locally
> too: `SWARMCLI=.swarmcli-bin/swarmcli scripts/local-repo-test.sh`. A Linux runner
> can't reproduce Docker-Desktop/WSL2 serving quirks, so still smoke `make
> local-repo` by hand once on macOS/Windows when you touch the serving path.

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
