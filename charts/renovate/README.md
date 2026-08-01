# renovate

Self-hosted [Renovate](https://docs.renovatebot.com/) on Docker Swarm. It scans the
repositories you point it at and opens pull requests bumping their dependency pins —
including the `swarmcli-release.yaml` that `swarmcli charts apply` deploys, which closes
the loop: your Swarm keeps its own chart versions up to date.

No SaaS, no CI minutes, and **no Docker socket** — the only chart in this repository with
no risky primitive to acknowledge.

## How it runs

Renovate is a **one-shot process**: it scans, opens PRs, and exits. It is not a server. So
the only real question is how it gets run again, and there are two answers.

| `schedule.mode` | Shape | Needs |
|---|---|---|
| `interval` (default) | One replica. Renovate runs, exits, and Swarm starts it again `schedule.interval` later (`restart_policy: any` + `delay`). | Nothing else. |
| `cronjob` | The service sits at **0 replicas**; the [swarm-cronjob](../swarm-cronjob) chart scales it to 1 on `schedule.cron`. Real cron expressions and `skip-running`. | The **swarm-cronjob chart must be deployed**, or nothing ever runs. |

> In `interval` mode the service reports **0/1 replicas between runs**. That is the
> container having finished its pass, not a failure — `docker service ps <release>_renovate`
> shows the completed tasks.

## Quick start

Create the token as an external Swarm secret. The chart never takes credentials through
values:

```bash
docker secret create renovate_token -    # paste a PAT, then Ctrl-D
```

Prove it works before it can write anything:

```bash
swarmcli charts install renovate swarmcli-charts/renovate \
  --set repositories[0]=my-org/my-repo \
  --set dryRun=full
```

`dryRun: full` makes Renovate do everything **except** push branches or open pull requests.
Check the logs, then re-run without it:

```bash
swarmcli charts upgrade renovate swarmcli-charts/renovate \
  --set repositories[0]=my-org/my-repo
```

## Keeping your SwarmCLI charts up to date

Point Renovate at the repository holding your release file, and extend this repo's preset:

```json
// renovate.json, in YOUR repository
{ "extends": ["github>Eldara-Tech/swarmcli-charts"] }
```

Renovate then bumps `version:` in your `swarmcli-release.yaml` whenever a chart you pin is
released. Merge the PR, and `swarmcli charts apply -f swarmcli-release.yaml` rolls it out.

## The token

Use a **PAT or a GitHub App token — not a CI job's built-in token**. On GitHub, pull
requests opened with the default `GITHUB_TOKEN` do **not** trigger `pull_request` workflows,
so Renovate's PRs would arrive with no CI having run on them.

### Non-GitHub platforms

If `platform.type` is anything but `github`, set `auth.githubComTokenSecret` too:

```bash
docker secret create github_com_token -   # a read-only, no-scope github.com token
```

Renovate fetches release notes — and any `github>`-hosted preset, including this
repository's — from github.com. Unauthenticated, those calls are rate-limited: changelogs
go missing from the PRs, and a `github>` preset can fail to resolve outright. The token
needs no permissions whatsoever; it exists purely to lift the anonymous rate limit.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `renovate/renovate` | Container image |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `schedule.mode` | `interval` | `interval` (self-contained) or `cronjob` (needs the swarm-cronjob chart) |
| `schedule.interval` | `4h` | `interval` mode: how long Swarm waits between runs |
| `schedule.cron` | `0 */4 * * *` | `cronjob` mode: 5-field cron, or `@every 4h` |
| `schedule.skipRunning` | `true` | `cronjob` mode: don't start a run while one is going |
| `platform.type` | `github` | `github`, `gitlab`, `gitea`, `bitbucket`, `azure` |
| `platform.endpoint` | `""` | API endpoint for a self-hosted platform |
| `repositories` | `[]` | Repositories to update, e.g. `[my-org/my-repo]` |
| `autodiscover` | `false` | Update every repository the token can see |
| `autodiscoverFilter` | `""` | Narrow autodiscovery, e.g. `infra/*` |
| `auth.tokenSecret` | `renovate_token` | **External** Swarm secret holding the platform token |
| `auth.githubComTokenSecret` | `""` | **External** secret with a read-only github.com token. Non-GitHub platforms only |
| `configName` | `""` | **External** Docker config holding a Renovate config file |
| `configFormat` | `json` | Format of that file — `json`, `json5`, `jsonc`, `yaml`, `yml`, `js`, `cjs`, `mjs`. Renovate parses by file extension, so this must match its contents |
| `logLevel` | `info` | `trace`–`fatal` |
| `dryRun` | `""` | `extract`, `lookup` or `full` — writes nothing to your repositories |
| `extraEnv` | `{}` | Extra environment variables, injected verbatim |
| `resources.limits.memory` | `""` | e.g. `2G`. Renovate clones repos and runs package managers |
| `resources.reservations.memory` | `""` | Scheduler hint |
| `placement.constraints` | `[]` | Extra scheduling constraints |
| `labels` | `{}` | Extra deploy labels |

You must set `repositories` **or** `autodiscover` — or supply them in the config file named
by `configName`. The chart fails to render otherwise, rather than deploying a Renovate with
nothing to do. Autodiscovery with a broadly-scoped token is how people open pull requests
across an entire org by accident, so it is off by default.

## Anything the values don't cover

Renovate's configuration surface is enormous (`packageRules`, `hostRules`, onboarding, …).
Mount its own config file as an external Docker config:

```bash
docker config create renovate_config ./config.json
swarmcli charts upgrade renovate swarmcli-charts/renovate --set configName=renovate_config
```

It lands at `/run/configs/renovate-config.<configFormat>`, with `RENOVATE_CONFIG_FILE`
pointing at it.

**`configFormat` must match the file's contents.** Renovate decides how to parse its config
purely from the *extension*, and a name it does not recognise is a startup
`FATAL: Unsupported file type` — it never looks inside the file. The default is `json`; for a
dynamic JavaScript config:

```bash
docker config create renovate_config ./config.js
swarmcli charts upgrade renovate swarmcli-charts/renovate \
  --set configName=renovate_config --set configFormat=js
```

**Values win over this file.** Renovate merges config file < environment < CLI, and the
chart renders the values above as environment: `platform.type` and `logLevel` always, and
`platform.endpoint`, `repositories`, `autodiscover`, `autodiscoverFilter` and `dryRun`
whenever they are set. Setting one of those in both places silently uses the chart value.
Leave the value empty to let the config file own that key.

## Notes

- **The token never touches the manifest.** Renovate reads `RENOVATE_TOKEN` from the
  environment and has no `*_FILE` convention, so the container reads the secret file and
  exports it before exec'ing Renovate. The value never appears in the rendered stack or in
  `docker inspect`.
- **No cache volume.** Renovate's clone cache is an optimisation, not state — it re-clones
  each run. That is fine for a handful of repositories; if you scan many, a cache volume is
  the first thing to add (note the image runs as uid `12021`, so the volume must be writable
  by it).
- **No Docker socket.** Renovate only shells out to sidecar containers for *lockfile
  artifact updates* (the deprecated `binarySource=docker`). Rewriting `version:` strings in
  a release file needs none of that.
