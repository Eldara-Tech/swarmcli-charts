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
  templates/stack.yaml.tmpl  # Go text/template → Swarm stack
  requirements.yaml          # swarmcli-specific: networks/secrets/configs (NOT Helm deps)
  README.md
scripts/generate-index.sh    # rebuilds the published index.yaml
.github/workflows/           # release.yml, ci.yml, lint.yml
```

Templates use Go `text/template` with `.Values`, `.Chart`, and `.Release`
context (e.g. `.Chart.AppVersion`, `.Release.Name`). `requirements.yaml`
declares overlay networks / secrets / configs the stack expects — it is
SwarmCLI's own format, unrelated to Helm chart dependencies.

## Releasing

The **git tag is the source of truth** for the version. Push a tag of the form
`<chart>/v<version>` (e.g. `whoami/v0.2.0`). `release.yml` stamps that version
into `Chart.yaml` at package time, publishes a GitHub Release with the `.tgz`,
and rebuilds `index.yaml` on GitHub Pages. The `version:` in `Chart.yaml` is a
placeholder — the tag wins. Published chart version is plain SemVer; the leading
`v` belongs only to the git tag.

## CI

- `lint.yml` — runs on `charts/**` PRs; checks changed charts have the required
  `Chart.yaml` fields, `values.yaml`, and `templates/stack.yaml.tmpl`.
- `ci.yml` — runs on `.github/workflows/**` and `scripts/**` changes; actionlint
  + shellcheck (`--severity=error`).
- Doc-only changes outside those paths trigger no CI.

## Git / pushing (within /claude-go)

`origin` here is the sanctioned token HTTPS remote — push directly to it:
`git push -u origin <branch>`. Never direct-push to `main`; open a PR. Match
existing commit authorship (`eldara-cruncher <hello@eldara.io>`).
