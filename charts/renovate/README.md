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

## Commit identity

Renovate's default `gitAuthor` is `renovate@whitesourcesoftware.com` — on github.com that is a
real account owned by Mend, used by the hosted `forking-renovate[bot]` App. Leave it and every
commit your bot pushes is attributed to a user you do not control, with Mend's Vigilant Mode
flagging it `Unverified`. Renovate warns about this on every run.

Point it at the account whose token you gave the chart:

```yaml
extraEnv:
  RENOVATE_GIT_AUTHOR: "Renovate Bot <12345678+my-bot@users.noreply.github.com>"
```

The numeric id is `gh api users/<login> --jq .id`. The commits stay unsigned — there is no
signing key in the container — but they are attributed to an account you own, and an unsigned
commit from an account without Vigilant Mode carries no badge at all.

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
| `configVersion` | `""` | Rotation key. The chart mounts `<configName>_<configVersion>`, so new contents get a new config object |
| `configFormat` | `json` | Format of that file — `json`, `json5`, `jsonc`, `yaml`, `yml`, `js`, `cjs`, `mjs`. Renovate parses by file extension, so this must match its contents |
| `logLevel` | `info` | `trace`–`fatal` |
| `dryRun` | `""` | `extract`, `lookup` or `full` — writes nothing to your repositories |
| `extraEnv` | `{}` | Extra environment variables, injected verbatim. On GitHub, set `RENOVATE_GIT_AUTHOR` here — see [Commit identity](#commit-identity) |
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

## Changing the config: rotation

A Swarm config is **immutable**. `docker config create` is the only way to put new bytes in
front of Renovate, and redeploying changed contents under an existing name does not update
it — `docker stack deploy` calls `ConfigUpdate` and the daemon refuses with
`only updates to Labels are allowed`. New contents therefore need a **new config object**,
and `configVersion` is the seam: the chart mounts `<configName>_<configVersion>`.

Derive the version from the file's contents and rotation looks after itself. Keep
`config.js` next to your `values.yaml` in git, and after editing it run:

```bash
V=$(sha256sum config.js | cut -c1-12)
docker config inspect renovate_config_$V >/dev/null 2>&1 \
  || docker config create renovate_config_$V ./config.js
swarmcli charts upgrade renovate swarmcli-charts/renovate -f values.yaml --set configVersion=$V
```

That is the whole loop, and it is idempotent: an unchanged file hashes to the same `$V`, the
config already exists, and the upgrade changes nothing. A changed file produces a new hash, a
new config object, and a service update onto it. Any string works as a version if you would
rather track it yourself — a git SHA, a date, a counter.

On the `swarmcli charts apply` path, put `configVersion` in your release file instead of
`--set`; it is then the one line that changes per rotation, which reads far better in a diff
than renaming `configName` each time. Have your CI job run the `docker config create` step
before `apply`, exactly as above.

Superseded configs stay until you remove them. Swarm refuses to delete a config that is
still in use, so nothing can be pulled out from under a running task — `docker config ls`
shows what has accumulated, and `docker config rm` clears the old ones once the service has
moved on.

> **Why the chart cannot just read your file.** Compose can source a config from a path
> (`configs.<x>.file`), but swarmcli refuses any path outside the chart's own `files/`
> directory (`charts/files.go`). The docker CLI reads that path **client-side, as you**, and
> uploads the bytes into a config that anyone with Docker access can read — so a chart able
> to name an arbitrary path is a chart able to exfiltrate any file you can read. Creating the
> config object is deliberately yours to do; `configVersion` is what makes doing it a
> one-liner.

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
