# Self-hosting Renovate for swarmcli-charts

This runbook stands up **self-hosted Renovate as a Docker Swarm service** and points it
at this repository, so the dependency-update rules that already live in
[`.github/renovate.json`](../.github/renovate.json) finally get *executed* by a bot you
run — no Mend SaaS, no GitHub Actions minutes.

Two pieces already exist in this repo; this runbook only connects them:

- **The rules** — [`.github/renovate.json`](../.github/renovate.json): the custom-regex
  manager that bumps each chart's `Chart.yaml:appVersion` pin, plus the `helm-values` and
  `github-actions` managers. Validated in CI, but inert until something runs Renovate.
- **The runner** — the [`renovate`](../charts/renovate) chart: packages the
  `renovate/renovate` image as a one-shot Swarm service. See its
  [README](../charts/renovate/README.md) for the full value reference.

The service supplies only **where to look** (`repositories`), **how to authenticate**
(`RENOVATE_TOKEN`), and **which platform** (`github`). The *rules* are read from this
repo's own `.github/renovate.json` at runtime — Renovate always merges a target repo's
in-repo config. So there is **nothing to duplicate** into a global config file, and
because this repo is already configured, Renovate skips onboarding and goes straight to
opening dependency PRs and creating the Dependency Dashboard issue.

## How it runs (read this first)

Renovate is a **one-shot process**: it clones the repo, opens/updates PRs, and exits. It
is not a server. The chart offers two ways to run it again — this runbook uses the default
`interval` mode, which needs nothing else deployed:

| `schedule.mode`      | Shape                                                                                  | Needs                          |
| -------------------- | -------------------------------------------------------------------------------------- | ------------------------------ |
| `interval` (default) | 1 replica; Renovate runs, exits, Swarm restarts it `schedule.interval` later (`4h`).   | Nothing.                       |
| `cronjob`            | 0 replicas; the [swarm-cronjob](../charts/swarm-cronjob) chart scales it to 1 on cron. | swarm-cronjob deployed first.  |

> In `interval` mode the service reads **0/1 replicas between runs** — that is the
> container having *finished* a pass, not a failure. `docker service ps <release>_renovate`
> shows the completed tasks.

**Interval ≠ how often PRs appear.** This repo's `.github/renovate.json` sets
`"schedule": ["before 6am on monday"]` (`Europe/Zurich`). So even though the service wakes
every 4 h, Renovate only *opens/updates PRs* during that Monday window. Off-window runs
still refresh the Dependency Dashboard; they just hold the branches.

`interval` mode needs no Docker socket and no manager node — it can be scheduled anywhere.

## Prerequisites

- A Docker Swarm you operate, and `swarmcli` **≥ 1.11.0** on the box you run these commands
  from (the renovate chart's declared `swarmcliVersion` floor).
- This chart repository added as a source:
  ```bash
  swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
  swarmcli charts repo update
  ```
- Write access to `Eldara-Tech/swarmcli-charts` for the account whose token you'll use. The
  `eldara-cruncher` bot already has it (it is the identity behind this repo's `origin`).

## Step 1 — Mint the token (eldara-cruncher, fine-grained PAT)

Signed in as **eldara-cruncher**, create a **fine-grained** PAT
(*Settings → Developer settings → Fine-grained tokens*):

- **Resource owner:** `Eldara-Tech`
- **Repository access:** *Only select repositories* → **`swarmcli-charts`** (least privilege;
  a broadly-scoped token is how people open PRs across a whole org by accident).
- **Repository permissions:**

  | Permission      | Access         | Why                                                            |
  | --------------- | -------------- | ------------------------------------------------------------- |
  | Contents        | Read and write | Push update branches.                                          |
  | Pull requests   | Read and write | Open/update the dependency PRs.                                |
  | Issues          | Read and write | Create and maintain the Dependency Dashboard issue.           |
  | Workflows       | Read and write | The `github-actions` manager edits files under `.github/workflows/`; GitHub blocks writing those without this. |
  | Commit statuses | Read and write | Read/report CI status for `internalChecksFilter` / automerge. |
  | Dependabot alerts | Read-only    | Raise security updates ahead of schedule. Omit it and every run WARNs `Cannot access vulnerability alerts`, which Renovate then reproduces as a **Repository Problems** banner at the top of the Dependency Dashboard issue. |
  | Metadata        | Read-only      | Mandatory baseline for every fine-grained PAT.                |

> A **classic** PAT works too — scopes `repo` + `workflow` — but it can't be pinned to a
> single repository, so prefer the fine-grained one above.

> **Do not use a CI job's `GITHUB_TOKEN`.** PRs opened with it don't trigger `pull_request`
> workflows, so Renovate's PRs would arrive with no CI having run.

No separate `github.com` token is needed here: the platform is GitHub, so `RENOVATE_TOKEN`
already authenticates the github.com API calls Renovate makes for changelogs and presets.
(The chart's `auth.githubComTokenSecret` is only for non-GitHub platforms.)

## Step 2 — Store the token as an external Swarm secret

The chart never takes credentials through values — only as a pre-created external secret,
read from the mounted file and exported as `RENOVATE_TOKEN` at runtime, so the plaintext
never lands in the rendered stack or `docker inspect`:

```bash
docker secret create renovate_token -    # paste the PAT, then Ctrl-D
```

(`renovate_token` is the chart's default `auth.tokenSecret` name.)

## Step 3 — Dry-run to prove token + repo before it can write anything

`dryRun: full` makes Renovate do everything **except** push branches or open PRs:

```bash
swarmcli charts install renovate swarmcli-charts/renovate \
  --set repositories[0]=Eldara-Tech/swarmcli-charts \
  --set dryRun=full \
  --set logLevel=debug
```

Then read the logs of the one-shot task:

```bash
docker service ps renovate_renovate             # find the task / node
docker service logs -f renovate_renovate
```

Confirm in the log that it: authenticated, found `Eldara-Tech/swarmcli-charts`, **read the
repo's `renovate.json`** (you'll see the extended presets and the custom manager), and
detected updates — with **no** branches pushed and **no** PRs opened (`DRY-RUN`).

## Step 4 — Go live

Put the persistent settings in a small values file rather than repeating `--set` — the
chart re-reads values on every `upgrade`, so anything you omit from a later `--set` is
dropped:

```yaml
# renovate-values.yaml
repositories:
  - Eldara-Tech/swarmcli-charts
logLevel: info
extraEnv:
  RENOVATE_GIT_AUTHOR: "Renovate Bot <262318423+eldara-cruncher@users.noreply.github.com>"
```

**`RENOVATE_GIT_AUTHOR` is not optional on github.com.** Renovate's default `gitAuthor` is
`renovate@whitesourcesoftware.com`, a real account owned by Mend and used by the hosted
`forking-renovate[bot]` App — leave it and every pin bump in this repo's history is attributed
to a user we do not control, flagged `Unverified` by Mend's Vigilant Mode, and Renovate WARNs
about it on every run. The address format is `<id>+<login>@users.noreply.github.com`; the
numeric id is `gh api users/<login> --jq .id` (`262318423` for `eldara-cruncher`). The commits
stay unsigned — there is no signing key in the container — but they belong to our own bot, and
an unsigned commit from an account without Vigilant Mode carries no badge at all.

Then drop the dry-run and go live:

```bash
swarmcli charts upgrade renovate swarmcli-charts/renovate -f renovate-values.yaml
```

Keep `renovate-values.yaml` under version control (or beside your other release files);
every later change is an edit to it followed by the same `upgrade -f`.

Because the repo is already configured, there is **no onboarding PR**. On the next run
inside the Monday-before-6am window, Renovate:

- creates the **Dependency Dashboard** issue (from `:dependencyDashboard` in the config), and
- opens dependency PRs, respecting the config's gates — `minimumReleaseAge: 5 days`,
  `prConcurrentLimit: 5`, `prHourlyLimit: 2`, the `postgres`/`mariadb` data-migration
  dashboard-approval hold, and the major-upgrade gates on keycloak/superset/traefik/redis and
  on `renovate/renovate` itself.

## Step 5 — Verify & operate

- **Is it running on schedule?** `docker service ps renovate_renovate` — expect a series of
  `Complete` tasks, one per interval. `0/1` replicas between runs is healthy.
- **Is it doing the right thing?** Watch the **Dependency Dashboard** issue and the first PRs
  in `Eldara-Tech/swarmcli-charts`. Each chart PR carries the `prBodyNote` reminding you that
  merging a pin does **not** publish the chart — release it explicitly afterwards
  (`gh workflow run release.yml -f chart=<chart> -f bump=patch`).
- **Leave the dashboard checkboxes alone.** *Create all awaiting schedule PRs*, and each
  individual *pending status checks* box, are manual overrides that bypass **every** gate at
  once: the `schedule`, the `minimumReleaseAge: 5 days` soak, and `prConcurrentLimit: 5` /
  `prHourlyLimit: 2`. Ticking them on the first dashboard opened 13 PRs in one go
  (#128–#140), each firing Charts + CI + Integration + E2E — and E2E is one job per chart, so
  the runner queue saturates and nothing reports for a long time. The limits exist to make
  updates arrive in reviewable batches; let the Monday run trickle them.
- **Don't close a PR you mean to postpone.** Closing a Renovate PR is a *never offer this
  again* signal: the update won't be recreated on the next run, it returns to the dashboard
  under the ignored list and needs re-approving by hand.
- **Logs:** `docker service logs renovate_renovate`.

### Common operations

Every change below is an edit to `renovate-values.yaml` followed by
`swarmcli charts upgrade renovate swarmcli-charts/renovate -f renovate-values.yaml`.

- **Change how often it wakes:** set `schedule.interval: 8h` (interval mode). The PR cadence
  is still governed by the in-repo `schedule`, not this value.
- **Rotate the token:** Swarm secrets are immutable *and* can't be removed while a service
  references them, so rotate by swapping to a new secret name, then deleting the old one once
  nothing uses it:
  ```bash
  docker secret create renovate_token_v2 -                 # paste the new PAT, Ctrl-D
  ```
  set `auth.tokenSecret: renovate_token_v2` in `renovate-values.yaml`, `upgrade -f`, then:
  ```bash
  docker secret rm renovate_token                          # now unreferenced
  ```
- **Bump the Renovate version:** the chart pins `renovate/renovate` via its own
  `Chart.yaml:appVersion` (maintained by Renovate itself). Take the update through a normal
  `renovate` chart release, then `swarmcli charts upgrade` to the new chart version.
  **Majors don't arrive on their own** — `renovate/renovate` sits behind
  `dependencyDashboardApproval`, so a new major waits for a click on the Dependency Dashboard.
  A Renovate major can drop config options and change defaults, and a bot that no longer
  understands `.github/renovate.json` fails *silently*: it simply stops maintaining the pins,
  with everything still green. Read the release notes, then approve it deliberately.
- **Change a mounted config file:** only relevant if you outgrow values and adopt
  `configName`. A Swarm config is **immutable**, so new bytes need a **new config object** —
  `configVersion` is the seam, and the chart mounts `<configName>_<configVersion>`. Derive it
  from the contents and rotation looks after itself:
  ```bash
  V=$(sha256sum config.json | cut -c1-12)
  docker config inspect renovate_config_$V >/dev/null 2>&1 \
    || docker config create renovate_config_$V ./config.json
  ```
  then set `configVersion: <V>` in `renovate-values.yaml` and `upgrade -f`. This setup needs
  none of it: the rules live in the repository's own `.github/renovate.json`, which Renovate
  reads on every run.
- **Give it more memory** (only if runs get OOM-killed on a large clone): set
  `resources.limits.memory: 2G`.

### Troubleshooting

- **Service sits at 0/0 and nothing ever runs** → you're in `cronjob` mode without the
  swarm-cronjob chart deployed. Either deploy [swarm-cronjob](../charts/swarm-cronjob) or use
  the default `interval` mode.
- **`secret renovate_token is empty`** → the secret was created without content; recreate it
  and paste the PAT.
- **Missing changelogs / a `github>` preset fails to resolve** → only happens on non-GitHub
  platforms; set `auth.githubComTokenSecret`. Not applicable to this setup.
- **`WARN: Cannot access vulnerability alerts`** (and the matching Repository Problems banner
  on the dashboard issue) → the PAT is missing *Dependabot alerts: Read-only*. Add it in the
  token's settings; nothing in the chart or in `.github/renovate.json` changes.
- **`WARN: Using the default gitAuthor email address … is not recommended on GitHub.com`** →
  `RENOVATE_GIT_AUTHOR` is unset; see Step 4. Commits already pushed keep the old author —
  the fix applies to new ones.

### Optional: cronjob mode instead of interval

If you want real cron expressions and `skip-running` instead of a fixed restart delay,
deploy the swarm-cronjob chart first, then add to `renovate-values.yaml`:

```yaml
schedule:
  mode: cronjob
  cron: "0 5 * * 1"        # Mon 05:00, aligned with the in-repo schedule
```

and `swarmcli charts upgrade renovate swarmcli-charts/renovate -f renovate-values.yaml`.

## Appendix — extending to the other repos (optional, not recommended yet)

The code repos (`swarmcli`, `swarmcli-be`, `swarmcli-agent`, `swarmcli-rbac-proxy`) declare
only **Go modules, GitHub Actions, and Docker** dependencies — exactly what **Dependabot**
already covers natively, with grouping and labels configured in each repo's
`.github/dependabot.yml`. Moving them to Renovate updates **nothing new**; the reasons to do
it are operational, not coverage:

- It replaces the `dependabot-tidy.yml` workflow (which exists only because Dependabot won't
  run `go mod tidy`) with Renovate's native `postUpdateOptions: ["gomodTidy"]`.
- Native automerge (no `fetch-metadata` + `gh pr merge --auto` workflow to maintain).
- One policy/dashboard/config language across the org instead of Dependabot-here /
  Renovate-there.

If you decide to onboard them later:

1. Broaden the PAT to those repos (or mint a dedicated one), and in `renovate-values.yaml`
   either list them under `repositories:` or switch to
   `autodiscover: true` + `autodiscoverFilter: "Eldara-Tech/*"`.
2. Add a `renovate.json` to each repo (port the ecosystems + labels from its
   `dependabot.yml`, add `"postUpdateOptions": ["gomodTidy"]`).
3. **Delete each repo's `.github/dependabot.yml`** in the same change — running both bots
   produces duplicate PRs.

Do this only when the `go mod tidy` bolt-on or the two-tool split actually costs you
something; until then, Dependabot on the code repos is the lower-maintenance choice.
