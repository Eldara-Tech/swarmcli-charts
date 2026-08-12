# SwarmCLI Charts

[![Charts](https://github.com/Eldara-Tech/swarmcli-charts/actions/workflows/charts.yml/badge.svg)](https://github.com/Eldara-Tech/swarmcli-charts/actions/workflows/charts.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Community charts for [SwarmCLI](https://github.com/Eldara-Tech/swarmcli) — a k9s-inspired TUI for Docker Swarm.

## Available Charts

| Chart | Version | App Version | Description |
|-------|---------|-------------|-------------|
| [whoami](charts/whoami) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.whoami%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.whoami%5B0%5D.appVersion&label=&color=informational) | HTTP echo service for testing |
| [swarm-cronjob](charts/swarm-cronjob) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.swarm-cronjob%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.swarm-cronjob%5B0%5D.appVersion&label=&color=informational) | Label-driven cron job scheduler for Docker Swarm |
| [traefik](charts/traefik) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.traefik%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.traefik%5B0%5D.appVersion&label=&color=informational) | Reverse proxy / ingress with Let's Encrypt TLS for Docker Swarm |
| [redis](charts/redis) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.redis%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.redis%5B0%5D.appVersion&label=&color=informational) | Redis in-memory data store for Docker Swarm — persistent, secret-authenticated, single-node pinned |
| [mariadb](charts/mariadb) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.mariadb%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.mariadb%5B0%5D.appVersion&label=&color=informational) | MariaDB relational database for Docker Swarm — persistent, secret-authenticated, single-node pinned |
| [postgres](charts/postgres) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.postgres%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.postgres%5B0%5D.appVersion&label=&color=informational) | PostgreSQL relational database for Docker Swarm — persistent, secret-authenticated, single-node pinned |
| [keycloak](charts/keycloak) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.keycloak%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.keycloak%5B0%5D.appVersion&label=&color=informational) | Keycloak identity & access management for Docker Swarm — DB-agnostic, secret-authenticated, Traefik-routed |
| [openclaw](charts/openclaw) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.openclaw%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.openclaw%5B0%5D.appVersion&label=&color=informational) | OpenClaw self-hosted personal AI assistant gateway for Docker Swarm — stateful, secret-authenticated, Traefik-routed |
| [superset](charts/superset) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.superset%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.superset%5B0%5D.appVersion&label=&color=informational) | Apache Superset BI & visualization platform for Docker Swarm — external metadata DB + Redis, Celery workers, Traefik-routed |
| [ollama](charts/ollama) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.ollama%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.ollama%5B0%5D.appVersion&label=&color=informational) | Ollama self-hosted LLM server for Docker Swarm — offline models, stateful, single-node pinned, optional GPU |
| [renovate](charts/renovate) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.renovate%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.renovate%5B0%5D.appVersion&label=&color=informational) | Self-hosted Renovate — opens dependency-update PRs, including for your swarmcli-release.yaml |
| [zammad](charts/zammad) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.zammad%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.zammad%5B0%5D.appVersion&label=&color=informational) | Zammad helpdesk / ticketing for Docker Swarm — external or embedded PostgreSQL & Redis, embedded Elasticsearch, Traefik-routed via its own nginx |
| [swarmcli-cd](charts/swarmcli-cd) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.swarmcli-cd%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.swarmcli-cd%5B0%5D.appVersion&label=&color=informational) | SwarmCLI CD — GitOps continuous delivery for Docker Swarm, pulling from git instead of pushing from CI |
| [vaultwarden](charts/vaultwarden) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.vaultwarden%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.vaultwarden%5B0%5D.appVersion&label=&color=informational) | Vaultwarden password manager for Docker Swarm — SQLite by default or external PostgreSQL/MySQL, stateful, Traefik-routed |
| [gitlab](charts/gitlab) | [![Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.gitlab%5B0%5D.version&label=&color=blue)](https://github.com/Eldara-Tech/swarmcli-charts/releases) | ![App Version](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Feldara-tech.github.io%2Fswarmcli-charts%2Findex.yaml&query=%24.entries.gitlab%5B0%5D.appVersion&label=&color=informational) | GitLab CE — self-hosted Git hosting and CI/CD for Docker Swarm — omnibus all-in-one image, stateful, single-node pinned, Traefik-routed with git-over-SSH on a TCP entrypoint |


> The Version/App Version badges read the live published
> [`index.yaml`](https://eldara-tech.github.io/swarmcli-charts/index.yaml), so they
> track the latest release automatically — there is no number to bump by hand.

## Adding the Repository

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts repo update
```

You can add multiple repos and reference charts by repo prefix. `install` takes a
release name and a `<repo>/<chart>` reference:

```bash
swarmcli charts install whoami swarmcli-charts/whoami
```

## Usage

```bash
# Install a chart
swarmcli charts install whoami swarmcli-charts/whoami --set ingress.host=whoami.yourdomain.com

# Install with custom values
swarmcli charts install whoami swarmcli-charts/whoami -f my-values.yaml

# List available charts
swarmcli charts search
```

## Keeping Charts Up to Date

Pin your releases in a file and let [Renovate](https://docs.renovatebot.com/) bump
them:

```yaml
# swarmcli-release.yaml
repositories:
  - name: swarmcli-charts
    url: https://eldara-tech.github.io/swarmcli-charts
releases:
  - name: edge
    chart: swarmcli-charts/traefik
    version: "0.1.1"
    values: [./traefik.yaml]
  - name: hello
    chart: swarmcli-charts/whoami
    version: "0.1.8"
```

```bash
swarmcli charts apply -f swarmcli-release.yaml --dry-run   # plan
swarmcli charts apply -f swarmcli-release.yaml             # converge
swarmcli charts outdated                                   # what has a newer chart?
```

Then extend this repository's Renovate preset — that is the whole configuration:

```json
{ "extends": ["github>Eldara-Tech/swarmcli-charts"] }
```

Renovate opens a PR whenever a chart you pin gets a new version, with the chart's
release notes attached. Merge it, and `swarmcli charts apply` in CI rolls it out.

**[docs/gitops.md](docs/gitops.md) is that CI job, worked end to end**: reaching
the swarm over an `ssh://` context, installing the binary, a plan-on-PR /
apply-on-merge workflow for GitHub Actions and GitLab CI, and the Renovate
settings that are easy to get wrong.

The file's key names match Helmfile's on purpose, so Renovate's **built-in**
`helmfile` manager reads it — there is no custom regex to maintain, and the chart
registry is resolved from the `repositories` block, so the preset works for any
chart repository you add, not just this one.

> **Running the bot yourself?** To self-host Renovate on your own Swarm with the
> [`renovate`](charts/renovate) chart — including pointing it at this repository — see
> [docs/renovate-self-hosting.md](docs/renovate-self-hosting.md).

## Releasing a New Chart Version

The **git tag is the source of truth** for the version. The easiest way to cut one
is the workflow dispatch, which derives the next version from the newest existing
tag and creates the tag itself:

```bash
gh workflow run release.yml -f chart=whoami -f bump=patch   # or minor / major
```

Prefer it over a hand-pushed tag when releasing **several** charts at once: GitHub
silently drops tag-push events beyond 3 tags per `git push`, so some charts would be
tagged and never published.

Pushing a tag by hand also works:

```bash
git tag whoami/v0.2.0
git push origin whoami/v0.2.0
```

`release.yml` stamps that version into the chart's `Chart.yaml` at package time
and publishes a GitHub Release with the `.tgz`; `pages-index.yml` then rebuilds
the `index.yaml` on GitHub Pages. The `version:` field committed in `Chart.yaml` is
only a placeholder — the tag wins.

The published chart version is plain SemVer (`0.2.0`); install it with
`--version 0.2.0` (the leading `v` belongs to the git tag, not the chart version).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide. In short:

```bash
make new-chart NAME=mychart   # scaffold a passing skeleton
make test CHART=mychart       # render + validate (exactly what CI runs)
make e2e  CHART=mychart       # deploy to a local swarm + verify (see docs/e2e-testing.md)
```

- Each chart lives under `charts/<name>/`
- Required files: `Chart.yaml`, `values.yaml`, `templates/stack.yaml.tmpl`, `README.md`, and a `ci/*-values.yaml` fixture
- Templates use Go `text/template` syntax with `.Values`, `.Chart`, and `.Release` context
- CI renders every chart against its fixtures and validates the output — see CONTRIBUTING.md

## One-Time Repo Setup (for maintainers)

The release workflow publishes `index.yaml` to GitHub Pages, so Pages needs to be enabled once:

1. Repo **Settings → Pages → Source** → set to **"GitHub Actions"** — the release workflow publishes the generated index via `actions/upload-pages-artifact` + `actions/deploy-pages`

That's it — `contents: write` is scoped only to the job that creates the GitHub Release (required by `softprops/action-gh-release`), and the index-publishing job only needs `pages: write` + `id-token: write`, which are job-level permissions the workflow requests itself and don't depend on the repo/org-wide "Workflow permissions" toggle. If that toggle is greyed out or locked by an org policy, this setup still works.

After the first successful release, the index will be live at:
   ```
   https://<org>.github.io/swarmcli-charts/index.yaml
   ```

### How the index is built

`scripts/generate-index.sh` rebuilds `index.yaml` from scratch on every chart release:
- Lists all GitHub Releases tagged `<chart>/v<version>`
- Reads each chart's `Chart.yaml` as it existed at that tag (via `git show <tag>:path`) for metadata
- Downloads each release's `.sha256` file to embed the digest
- Outputs a Helm-style `index.yaml` with download URLs pointing at the release assets

The generated `index.yaml` is published straight to GitHub Pages (not committed back to `main`), so no repo-write permission is needed beyond what release creation already requires.

Run it locally to debug:
```bash
gh auth login
./scripts/generate-index.sh eldara-tech/swarmcli-charts > index.yaml
```
