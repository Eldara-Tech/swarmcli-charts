# swarmcli-charts

Community charts for [SwarmCLI](https://github.com/Eldara-Tech/swarmcli), a TUI
for Docker Swarm. Each chart renders a Docker Swarm **stack** (`docker stack`
style Compose) — not Kubernetes/Helm. SwarmCLI consumes the published charts via
its `swarmcli charts` command group.

## CLI command shape (keep docs in sync)

The user-facing command is **`swarmcli charts`** (plural), defined in the
`swarmcli` repo at `cli/charts.go`. The canonical signatures READMEs must match:

- `swarmcli charts repo add <name> <url>` / `swarmcli charts repo update`
- `swarmcli charts install <release> <repo/chart>` — **two** positional args
  required; `<repo>` is the alias from `repo add` (this repo is added as
  `swarmcli-charts`, so refs look like `swarmcli-charts/whoami`).
- `swarmcli charts search` / `list` / `status <release>` / `upgrade` /
  `uninstall` / `rollback` / `history` / `template`

Common doc mistakes: writing `chart` (singular), dropping the `<repo/chart>` arg
from `install`, or using a stale repo alias. Verify against `cli/charts.go` in
the `swarmcli` repo, not from memory.

## Repository layout

```
charts/<name>/
  Chart.yaml                 # name, version, appVersion, description (all required by CI)
  values.yaml                # default values
  values.schema.json         # optional JSON Schema — swarmcli validates values against it
  templates/stack.yaml.tmpl  # Go text/template → Swarm stack
  ci/<case>-values.yaml      # render fixtures (≥1 required; CI renders each)
  README.md
Makefile                     # make new-chart / lint / test / render / package
scripts/install-swarmcli.sh  # builds the swarmcli renderer from source
scripts/test-charts.sh       # render + compose-validate + no-value + security (== CI)
scripts/security-scan.sh     # flags risky primitives unless Chart.yaml acknowledges them
scripts/new-chart.sh         # scaffolds a passing chart skeleton
scripts/lint.sh              # chart structure + yamllint
scripts/generate-index.sh    # rebuilds the published index.yaml (release path)
.github/workflows/           # charts.yml (validate), ci.yml (machinery), release.yml
```

Templates use Go `text/template` with sprig (minus `env`/`expandenv`/
`getHostByName`) plus `toYaml`, and `.Values`, `.Chart`, `.Release` context
(e.g. `.Chart.AppVersion`, `.Release.Name`). No `.Capabilities`. swarmcli does
**not** set `missingkey=error`, so a typo renders the literal `<no value>` — the
`make test` guard greps for it.

> **External networks** a stack needs (declared in the manifest as
> `networks: <name>: { external: true }`) are auto-created by swarmcli at install
> time as `overlay --attachable` (`charts/release.go` `ensureExternalNetworks`),
> with clear remediation if a name clashes with a non-swarm network. There is no
> separate requirements file — document any human prerequisites (e.g. "Traefik
> must already run on `traefik-public`") in the chart README. External
> secrets/configs are not pre-flighted today; a missing one fails at deploy.

## Releasing

The **git tag is the source of truth** for the version. Push a tag of the form
`<chart>/v<version>` (e.g. `whoami/v0.2.0`). `release.yml` stamps that version
into `Chart.yaml` at package time, publishes a GitHub Release with the `.tgz`,
and rebuilds `index.yaml` on GitHub Pages. The `version:` in `Chart.yaml` is a
placeholder — the tag wins. Published chart version is plain SemVer; the leading
`v` belongs only to the git tag.

## CI & testing

- `charts.yml` — runs on `charts/**`/`scripts/**`/`Makefile`/`.yamllint` PRs and
  pushes to main. Builds the swarmcli renderer from source, then for every chart
  × `ci/*-values.yaml` fixture: renders (`swarmcli charts template`),
  no-`<no value>` guard, `docker compose config`, and `scripts/security-scan.sh`.
  All steps are data-only (no secrets, read-only token, render-never-deploy) so
  they are safe on fork PRs. Mirrors `make test` exactly. Uploads rendered output
  as the `rendered-stacks` artifact.
- `ci.yml` — runs on `.github/workflows/**` and `scripts/**` changes; actionlint
  + shellcheck (`--severity=error`).
- Doc-only changes outside those paths trigger no CI.

**Renderer source.** swarmcli is the renderer; its `charts` CLI is only on
swarmcli `main` today and its module path is `swarmcli` (so `go install` of the
GitHub path fails). `scripts/install-swarmcli.sh` clones+builds `main`
(`SWARMCLI_REF` overrides). Switch to release-asset download once a swarmcli
release ships the charts CLI.

**Security acknowledgments.** Risky primitives in a rendered stack (docker.sock,
host mounts, `privileged`, host network/PID, `cap_add`) fail CI unless the chart
declares `annotations: { swarmcli-charts/allow: "<keys>" }` in `Chart.yaml`. See
`charts/swarm-cronjob` (docker-socket).

**Local = CI.** `make test` runs the identical pipeline; `make new-chart NAME=x`
scaffolds a passing skeleton. GitHub action versions are SHA-pinned across all
workflows.

Actions for new contributors are gated by the "Require approval for outside
collaborators" repo setting so CI auto-runs and reports before review.

## Git / pushing (within /claude-go)

`origin` here is the sanctioned token HTTPS remote — push directly to it:
`git push -u origin <branch>`. Never direct-push to `main`; open a PR. Match
existing commit authorship (`eldara-cruncher <hello@eldara.io>`).
