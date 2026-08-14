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
- **mikefarah `yq` v4** — required by `make test`, which *refuses to run without
  it*: the `requirements.yaml` consistency check and the charts' `ci/render-check.sh`
  assertions are written in it. Install with `go install github.com/mikefarah/yq/v4@latest`,
  `snap install yq`, `brew install yq`, or a [release binary](https://github.com/mikefarah/yq/releases).
  Beware: the `yq` in Debian/Ubuntu apt is a **different tool** (a Python `jq`
  wrapper) — `yq --version` must say `mikefarah`.
- **`jq`** and **`gh`** — only needed to run `scripts/generate-index.sh` (the release
  path); it exits with an error without them.
- Optional: `yamllint` (`pip install yamllint`) for `make lint`.

`make install-tools` builds the renderer and tells you what else is missing.

## Anatomy of a chart

```
charts/<name>/
  Chart.yaml                 # name, version, appVersion, description (all required)
                             #   + `# renovate: image=<repo>` directly above appVersion
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

## Chart conventions

The existing charts share deliberate patterns — new charts must follow them.
The full normative list lives in [CLAUDE.md](CLAUDE.md#chart-design-conventions);
in short:

- **Image pins.** `Chart.yaml:appVersion` is the image pin (every chart ships
  `image.tag: ""` and the template falls back to `.Chart.AppVersion`). Renovate
  maintains it, so every `Chart.yaml` needs a `# renovate: image=<repo>` comment
  directly above `appVersion`, naming the same image as `values.yaml`
  `image.repository`. No `:latest`, and never repeat the version in a comment or in
  the README values table — Renovate edits `Chart.yaml` and touches neither, so it
  drifts. `make new-chart` gets all of this right; `make test` enforces it. The bot doing
  the maintaining is our own, run from the [`renovate`](charts/renovate) chart — see
  [docs/renovate-self-hosting.md](docs/renovate-self-hosting.md) for how it is configured
  and which updates it holds back.
- **Traefik-routed** services carry `traefik.enable=true`,
  `traefik.constraint-label` and `traefik.swarm.network` deploy labels (the
  swarm provider discovers nothing without the constraint label), and default
  their `traefik.*` values to the in-repo traefik chart — entrypoints
  `http`/`https`, cert resolver `le`, redirect middleware `https-redirect`. See
  "Routing a service" in [charts/traefik/README.md](charts/traefik/README.md).
- **Stateful** services run a single replica pinned via `persistence.nodeLabel`,
  rendered only while `persistence.enabled` (never a hardcoded entry in
  `placement.constraints`, which is for extra constraints); they offer host-path
  persistence via `persistence.volumePath` with the `host-mount` acknowledgment,
  and ship `ephemeral` + `bind-mount` CI fixtures. See charts/mariadb.
- **Secrets** are external and operator-created; charts read them from the
  mounted `/run/secrets/...` files (never take secret values via values.yaml).

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

### It is a template, not static YAML

swarmcli renders `requirements.yaml` as a Go template with the **release's**
values, so a declaration tracks whatever the operator overrode:

```yaml
  - name: "{{ .Values.exposure.network }}"   # quote every substitution
```

Quote substitutions so the file still parses as YAML *unrendered* — that is what
lets `yamllint` (via `scripts/lint.sh`) check it, and it keeps the declaration
readable on disk. **Prefer plain YAML with substitution only**: it covers almost
every chart, because an entry a given configuration never references is simply
inert (swarmcli's pre-flight is manifest-driven), so you rarely need an `if`.

If you genuinely need control flow — the honest case is a **user-supplied list**,
which substitution cannot express — use it, and add `# yamllint disable-file` as
the first line:

```yaml
# yamllint disable-file
networks:
{{- range .Values.extraNetworks }}
  - name: "{{ . }}"
    autoCreate: false
{{- end }}
```

A template action on its own line is not parseable YAML, and yamllint cannot lint
a template with control flow — the directive is the opt-out, and it is
load-bearing, not cruft. Nothing important is lost: swarmcli renders this file per
release and `scripts/requirements-check.sh` parses the **rendered** result for
every `ci/*-values.yaml` fixture, which is the form that actually matters. See
`charts/zammad` for a worked example.

> Control flow here was impossible until swarmcli's chart loader stopped
> hard-parsing the raw bytes as YAML (Eldara-Tech/swarmcli#457). If you find an
> older comment claiming `range` "would break yamllint", it is stale — that
> reasoning once cost a chart a user-facing feature.

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

## Testing end-to-end (real deploy)

`make test` proves a chart *renders*; `make e2e` proves it *runs*. Against a
local single-node swarm (`docker swarm init`), `make e2e` deploys each chart ×
fixture **straight from your working tree** — so you can test a chart *before*
you commit, open a PR, or publish anything — waits for the services to converge,
runs an optional per-chart smoke check, and tears the release down:

```bash
make e2e                 # all charts
make e2e CHART=mychart   # just yours
```

It needs a live Swarm and pulls real images. The `e2e.yml` workflow runs this
**in CI** on a throwaway single-node swarm for charts that ship CI-provisionable
setup hooks (`ci/e2e-setup.sh` / `ci/e2e-teardown.sh`) — fork-safe, using only
public images and dummy on-runner secrets; the full local `make e2e` across every
chart stays your loop until each chart gains those hooks. See
[docs/e2e-testing.md](docs/e2e-testing.md) for prerequisites, the setup/teardown
hooks, a manual lifecycle walkthrough, writing a `ci/e2e-check.sh` smoke check,
and troubleshooting.

To exercise the consumer flow (`repo add` → `search` → `install repo/chart`)
against your unpublished chart, `make local-repo` serves the working tree as a
local HTTP repo — see [docs/e2e-testing.md](docs/e2e-testing.md#trying-a-chart-through-the-repo-flow-local-repo).

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

The **git tag is the source of truth** for the version. The easiest way to cut one
is the workflow dispatch, which derives the next version from the newest existing
tag and creates the tag for you:

```bash
gh workflow run release.yml -f chart=whoami -f bump=patch   # or minor / major
```

**Use it, not a hand-pushed tag, when releasing several charts at once**: GitHub
silently drops tag-push events beyond 3 tags per `git push`, so some charts would
end up tagged but never published. One dispatch is always exactly one release.

Pushing a tag by hand still works:

```bash
git tag whoami/v0.2.0
git push origin whoami/v0.2.0
```

`release.yml` stamps the SemVer into `Chart.yaml`, packages the `.tgz` and
publishes a GitHub Release; `pages-index.yml` then rebuilds `index.yaml` on
GitHub Pages. The `version:` in
`Chart.yaml` is only a placeholder — the tag wins. Published versions are plain
SemVer (`0.2.0`); the leading `v` belongs to the git tag.

## How the renderer is obtained

swarmcli *is* the renderer, so CI and `make test` need it. There are two ways to
get one, and the repo uses both on purpose:

- `scripts/install-swarmcli.sh` clones and builds swarmcli's **`main`**. This is
  what the PR workflows use: `main` renders with the newest engine, so a change
  that breaks a chart shows up the moment it lands, before any release ships it.
- `scripts/download-swarmcli.sh` downloads a **released** binary and verifies its
  checksum. `nightly.yml` uses it to run the suite against the latest release, and
  `floor-check.sh` uses it to render each chart with the exact release its
  `Chart.yaml` declares as its floor.

A source build rather than `go install` — which does resolve, since swarmcli's
module path is `github.com/Eldara-Tech/swarmcli` — because `go install ...@main`
goes through the module proxy, which can lag a just-pushed commit; a shallow clone
sees it immediately.

- Override the ref with `SWARMCLI_REF=<branch-or-tag>` if needed, or the repo with
  `SWARMCLI_REPO=<url>` to build a fork.
- If an upstream swarmcli change on `main` reds CI for reasons unrelated to your
  chart, set `SWARMCLI_REF` to a known-good commit and open a tracking issue.

## Repo setup note (maintainers)

To make fork PRs auto-tested before review, enable **Settings → Actions →
General → Fork pull request workflows → Require approval for all outside
collaborators' first workflow run**. One click per new contributor, then CI runs
and reports automatically.
