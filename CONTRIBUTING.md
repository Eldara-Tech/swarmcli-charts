# Contributing to swarmcli-charts

Thanks for contributing! This repo holds community charts for
[SwarmCLI](https://github.com/Eldara-Tech/swarmcli). Each chart is a Go
`text/template` that **swarmcli renders into a Docker Swarm stack** — these are
*not* Helm charts, so Helm tooling does not apply.

## TL;DR

```bash
make new-chart NAME=mychart   # scaffold a passing skeleton
# edit charts/mychart/{Chart.yaml,values.yaml,templates/stack.yaml.tmpl,README.md}
make test CHART=mychart       # render + validate (exactly what CI runs)
make test                     # validate everything before opening a PR
```

Open a PR. CI runs the same `make test` automatically — including on PRs from
forks, before a maintainer reviews — so a chart that does not render never gets
that far.

## Prerequisites

- **Go** (to build the swarmcli renderer from source — see below) and **Docker
  Compose v2** (`docker compose`, used to validate rendered stacks).
- Optional: `yamllint` (`pip install yamllint`) for `make lint`.

`make install-tools` builds the renderer and tells you what else is missing.

## Anatomy of a chart

```
charts/<name>/
  Chart.yaml                 # name, version, appVersion, description (all required)
  values.yaml                # default values
  values.schema.json         # optional JSON Schema — swarmcli validates values against it
  templates/stack.yaml.tmpl  # Go text/template → Docker Swarm stack
  requirements.yaml          # optional — external networks/secrets/configs (see below)
  README.md                  # what it deploys + a values table
  ci/<case>-values.yaml      # render fixtures (at least ci/default-values.yaml)
```

Templates use Go `text/template` with [sprig](https://masterminds.github.io/sprig/)
functions (minus `env`/`expandenv`/`getHostByName`) plus `toYaml`. The available
context is:

- `.Values` — merged values (defaults ← `-f` files ← `--set`)
- `.Release.Name` / `.Release.Namespace` / `.Release.Revision`
- `.Chart.Name` / `.Chart.Version` / `.Chart.AppVersion`

There is **no** `.Capabilities` or other Helm context.

> swarmcli does **not** render in strict mode, so a typo like
> `{{ .Values.replcas }}` silently becomes the literal `<no value>` instead of
> erroring. `make test` greps for `<no value>` and fails — fix the reference.

## External resources (`requirements.yaml`)

If a stack attaches to an external network or mounts an external secret/config
(anything marked `external: true` in the rendered stack), declare it in an
optional `requirements.yaml`. swarmcli reads this file as a **pre-flight** before
it deploys:

```yaml
networks:
  - name: traefik-public   # the external network's real name (required)
    driver: overlay        # optional, default "overlay"
    attachable: true       # optional, default true
    autoCreate: true       # optional, default true:
                           #   true  => swarmcli creates it if missing
                           #   false => validate-only; a missing one is a hard
                           #            error and is never auto-created
    description: "Shared ingress overlay"   # optional; shown when validation fails
secrets:                   # entries: { name, description } — validated, never
  - name: db-password      #   auto-created (their content is not chart-supplied)
    description: "Postgres password"
configs: []                # entries: { name, description }
```

The file is **optional but authoritative when present**: every external resource
the rendered stack references must be declared, or install (and `make test`)
fails. Without it, swarmcli falls back to auto-creating external networks as
attachable overlays. Use `autoCreate: false` for a network the operator
pre-provisions (e.g. a shared ingress) — and document such prerequisites in the
chart `README.md` too.

## Testing locally (== CI)

`make test` does, per chart × per `ci/*-values.yaml` fixture:

1. **render** — `swarmcli charts template` must succeed and emit a valid stack
2. **no-value guard** — fails on any `<no value>` (missing-key typo)
3. **compose-validate** — `docker compose config` must accept the output
4. **security scan** — flags risky primitives unless acknowledged (see below)
5. **requirements check** — every external resource the rendered stack uses must
   be declared in `requirements.yaml` (skipped if the chart has none)

Rendered output lands in `.rendered/` for inspection; CI uploads it as an
artifact named `rendered-stacks` so reviewers can read the produced stack.

## Security acknowledgments

Charts that need a dangerous primitive (Docker socket, host bind-mount,
`privileged`, host network/PID, `cap_add`) must **acknowledge** it in
`Chart.yaml`, or `make test` fails:

```yaml
annotations:
  swarmcli-charts/allow: "docker-socket,host-mount"
```

This keeps danger explicit and reviewable. See `charts/swarm-cronjob` for a real
example (it mounts the Docker socket by design). Risk keys: `docker-socket`,
`host-mount`, `privileged`, `host-network`, `host-pid`, `cap-add`.

## Pull requests

- Keep one chart (or one logical change) per PR.
- Run `make test` and keep the chart's README values table in sync with
  `values.yaml`.
- The PR template has the checklist.

## Releasing (maintainers)

The **git tag is the source of truth** for the version. Push a tag of the form
`<chart>/v<version>`:

```bash
git tag whoami/v0.2.0
git push origin whoami/v0.2.0
```

`release.yml` stamps the SemVer into `Chart.yaml`, packages the `.tgz`, publishes
a GitHub Release, and rebuilds `index.yaml` on GitHub Pages. The `version:` in
`Chart.yaml` is only a placeholder — the tag wins. Published versions are plain
SemVer (`0.2.0`); the leading `v` belongs to the git tag.

## How the renderer is obtained

swarmcli *is* the renderer, so CI and `make test` need it. The `charts` CLI
currently lives only on swarmcli's `main` branch (no release ships it yet), and
swarmcli's Go module path is `swarmcli` (not its GitHub path), so `go install`
does not work. `scripts/install-swarmcli.sh` therefore clones and builds swarmcli
from `main`.

- Override the ref with `SWARMCLI_REF=<branch-or-tag>` if needed.
- If an upstream swarmcli change on `main` reds CI for reasons unrelated to your
  chart, set `SWARMCLI_REF` to a known-good commit and open a tracking issue.
- Once a swarmcli release ships the charts CLI, this will switch to downloading
  the release binary (`swarmcli_<OS>_<ARCH>.tar.gz`) + checksum verification.

## Repo setup note (maintainers)

To make fork PRs auto-tested before review, enable **Settings → Actions →
General → Fork pull request workflows → Require approval for all outside
collaborators' first workflow run**. One click per new contributor, then CI runs
and reports automatically.
