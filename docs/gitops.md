# GitOps with SwarmCLI charts

Renovate opens a PR when a chart you pin gets a new version. `swarmcli charts
apply` converges the swarm to whatever the file says. This guide is the joint
between them: a CI job that runs the apply after the PR merges, so the merge
*is* the deployment.

Everything here is one repository containing your `swarmcli-release.yaml`, its
values files, and a CI workflow. Nothing needs to run on the swarm itself.

## The file

```yaml
# swarmcli-release.yaml
repositories:
  - name: swarmcli-charts
    url: https://eldara-tech.github.io/swarmcli-charts
releases:
  - name: edge
    chart: swarmcli-charts/traefik
    version: "0.1.1"
    values: [./values/traefik.yaml]
  - name: hello
    chart: swarmcli-charts/whoami
    version: "0.1.8"
```

**Quote the version.** Renovate's built-in `helmfile` manager reads this file
because its key names are Helmfile's, and that schema accepts a number — so an
unquoted `1.0` is parsed as a float and written back as `"1"`, which resolves to
nothing. `"0.1.8"` is a string and stays one.

Chart versions are plain SemVer. The leading `v` belongs to the release git tag,
not to the version in this file.

## Reaching the swarm from CI

`swarmcli` deploys by running `docker --context <name> stack deploy`, so the CI
environment needs two things: the `docker` CLI on `PATH`, and a **named** Docker
context pointing at the swarm. `DOCKER_HOST` alone is not the supported path —
create a context and select it.

Selecting it means either `docker context use <name>`, or setting
`DOCKER_CONTEXT=<name>` in the environment, which takes precedence and leaves
the runner's Docker config untouched. The examples below use `context use`
because it is the more familiar of the two; in a job that does anything else
with Docker, prefer the variable.

### Over SSH (recommended)

Nothing is exposed: the daemon keeps listening only on its local socket, and the
connection is an ordinary SSH session running `docker system dial-stdio` on the
far end.

```bash
docker context create swarm --docker "host=ssh://deploy@manager.example.com"
docker context use swarm
```

Three things to get right, and each fails in a way that is not obvious:

- **The remote user must be able to talk to the daemon** — in the `docker` group,
  or whatever your host's equivalent is. `ssh deploy@manager docker version` is
  the check; if that works, so will this.
- **Pin the host key.** Write `known_hosts` from a CI secret rather than
  disabling checking. An unknown host key fails the connection closed, which is
  the behaviour you want, but it fails at the *deploy* step with a message about
  ssh rather than about your chart.
- **OpenSSH finds `~/.ssh/config` through `getpwuid()`, not `$HOME`.** If your
  job runs as a UID with no matching `/etc/passwd` entry — common in container
  executors — the config you wrote is silently ignored: no port, no identity, no
  host-key policy. Either run as a user that exists, or put the settings in the
  context URL and pass `-F` explicitly.

### Over mTLS

If you already run a CA and expose the daemon on a TCP port, that works too and
needs no SSH access to the host:

```bash
docker context create swarm \
  --docker "host=tcp://manager.example.com:2376,ca=$PWD/ca.pem,cert=$PWD/cert.pem,key=$PWD/key.pem"
docker context use swarm
```

The three PEM files come from CI secrets. This is more moving parts than the SSH
path and exposes a port that must then be firewalled; prefer SSH unless you have
the CA already.

## Getting the binary

### GitHub Actions

`ubuntu-latest` already has the `docker` CLI and an SSH client, so the only thing
to fetch is `swarmcli` itself. Download the release asset and check it — the
assets are public, so this needs no token:

```yaml
- name: Install swarmcli
  env:
    SWARMCLI_VERSION: v1.13.0
  run: |
    base="https://github.com/Eldara-Tech/swarmcli/releases/download/$SWARMCLI_VERSION"
    curl -fsSL -O "$base/swarmcli_Linux_x86_64.tar.gz"
    curl -fsSL -O "$base/checksums.txt"
    grep ' swarmcli_Linux_x86_64.tar.gz$' checksums.txt | sha256sum -c -
    tar xzf swarmcli_Linux_x86_64.tar.gz swarmcli
    sudo install swarmcli /usr/local/bin/
```

> **Not the container image, here.** `eldaratech/swarmcli` is built `FROM docker`,
> so it is Alpine-based. Alpine is not among the distributions the Actions runner
> supports ([actions/runner#801]), and JavaScript actions such as
> `actions/checkout` are not guaranteed to run inside one. Use the image in a
> `docker run`, or on a CI system that does not inject actions into the
> container — see below.

### GitLab CI, Gitea Actions, Drone

Here the image is exactly right: it carries `swarmcli`, the `docker` CLI and an
SSH client already, and nothing is injected into it.

```yaml
image:
  name: eldaratech/swarmcli:v1.13.0
  entrypoint: [""]   # the image's entrypoint is swarmcli itself
```

## The workflow

Two jobs: one that shows the operator what a PR would do, one that does it after
the merge.

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  pull_request:
    paths: ['swarmcli-release.yaml', 'values/**']
  push:
    branches: [main]
    paths: ['swarmcli-release.yaml', 'values/**']

# One convergence at a time. Two merges applying to the same swarm concurrently
# would race, and cancelling a half-finished apply is worse than queueing.
concurrency:
  group: swarm-deploy
  cancel-in-progress: false

jobs:
  apply:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Install swarmcli
        env:
          SWARMCLI_VERSION: v1.13.0
        run: |
          base="https://github.com/Eldara-Tech/swarmcli/releases/download/$SWARMCLI_VERSION"
          curl -fsSL -O "$base/swarmcli_Linux_x86_64.tar.gz"
          curl -fsSL -O "$base/checksums.txt"
          grep ' swarmcli_Linux_x86_64.tar.gz$' checksums.txt | sha256sum -c -
          tar xzf swarmcli_Linux_x86_64.tar.gz swarmcli
          sudo install swarmcli /usr/local/bin/

      - name: Point at the swarm
        env:
          SSH_KEY: ${{ secrets.SWARM_SSH_KEY }}
          KNOWN_HOSTS: ${{ secrets.SWARM_KNOWN_HOSTS }}
        run: |
          mkdir -p ~/.ssh && chmod 700 ~/.ssh
          printf '%s\n' "$SSH_KEY"     > ~/.ssh/id_ed25519
          printf '%s\n' "$KNOWN_HOSTS" > ~/.ssh/known_hosts
          chmod 600 ~/.ssh/id_ed25519
          docker context create swarm --docker "host=ssh://deploy@manager.example.com"
          docker context use swarm

      # No `charts repo add` step: apply reads the `repositories` block and adds
      # what is missing, so a fresh runner needs no prior state. It refuses to
      # silently repoint a name that is already configured at another URL.

      # On a PR: show the diff and stop. --diff implies --dry-run, so this
      # cannot deploy even by accident.
      - name: Plan
        if: github.event_name == 'pull_request'
        run: swarmcli charts apply -f swarmcli-release.yaml --diff

      # On main: converge, and wait for it rather than reporting success the
      # moment the API accepts the spec.
      - name: Apply
        if: github.event_name == 'push'
        run: swarmcli charts apply -f swarmcli-release.yaml --wait --timeout 10m
```

The GitLab equivalent runs the same two `apply` invocations; the image replaces
the install step, and `resource_group` replaces `concurrency`:

```yaml
# .gitlab-ci.yml
default:
  image:
    name: eldaratech/swarmcli:v1.13.0
    entrypoint: [""]
  before_script:
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - printf '%s\n' "$SWARM_SSH_KEY"     > ~/.ssh/id_ed25519
    - printf '%s\n' "$SWARM_KNOWN_HOSTS" > ~/.ssh/known_hosts
    - chmod 600 ~/.ssh/id_ed25519
    - docker context create swarm --docker "host=ssh://deploy@manager.example.com"
    - docker context use swarm

plan:
  rules: [{ if: $CI_PIPELINE_SOURCE == "merge_request_event" }]
  script:
    - swarmcli charts apply -f swarmcli-release.yaml --diff

apply:
  resource_group: swarm-deploy      # the concurrency gate
  rules: [{ if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH }]
  script:
    - swarmcli charts apply -f swarmcli-release.yaml --wait --timeout 10m
```

## Renovate

One line of configuration, because this repository ships the preset:

```json
{ "extends": ["github>Eldara-Tech/swarmcli-charts"] }
```

It teaches Renovate's built-in `helmfile` manager to read
`swarmcli-release.yaml`, and resolves each chart against the `repositories`
block in the file itself — so it works for any chart repository you add, not
only this one.

### Set `GITHUB_COM_TOKEN` if you self-host Renovate

Renovate fetches release notes from github.com, **and it fetches any
`github>`-hosted preset from there too — including this one**. Unauthenticated,
those calls are rate-limited by IP, which on a shared runner is exhausted
quickly. The symptoms are two, and the second is the one that wastes an
afternoon:

- changelogs stop appearing in the PRs, and
- the preset itself fails to resolve, so Renovate behaves as though it had no
  configuration at all.

A GitHub personal access token with **no scopes** — read-only public access is
all that is needed — fixes both:

```yaml
env:
  GITHUB_COM_TOKEN: ${{ secrets.RENOVATE_GITHUB_COM_TOKEN }}
```

This applies to self-hosted Renovate on GitLab, Gitea, Bitbucket, or the
[renovate chart](../charts/renovate) in this repository. The hosted GitHub App
does not need it.

## Reviewing the PR

The plan job's output is the artifact to review. `--diff` prints each changed
release's manifest diff — the actual before-and-after of what will run — and
`--dry-run` on its own prints just the plan. Both refuse to deploy.

```
$ swarmcli charts apply -f swarmcli-release.yaml --diff

RELEASE  CHART                    FROM   TO     ACTION
edge     swarmcli-charts/traefik  0.1.1  0.1.1  unchanged
hello    swarmcli-charts/whoami   0.1.7  0.1.8  upgrade

--- hello (upgrade) ---
  services:
    whoami:
-     image: traefik/whoami:v1.10.1
+     image: traefik/whoami:v1.10.2
      deploy:
        replicas: 1

0 to install, 1 to upgrade, 1 unchanged

dry-run: nothing was deployed
```

It also names anything the swarm holds that the file no longer claims — a
release this file installed and has since dropped, and any release nothing here
owns. Neither is removed; a dry-run is where you want to find out.

Paste that into the PR and the review is a code review: the chart bump is the
diff, and merging is what applies it.

To ask the same question outside a PR — "is anything I am running behind?" —
`swarmcli charts outdated` compares every deployed release against the
repository indexes.

## Pulling instead of pushing

Everything above pushes: CI holds the credential, reaches the swarm, and applies.
The other shape is a controller running *on* the swarm that watches the
repositories itself — nothing outside needs swarm access, and drift a
`docker service update` introduced behind your back is noticed rather than
waited out until the next merge. That is
[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd), and the
[swarmcli-cd chart](../charts/swarmcli-cd) deploys it.

[actions/runner#801]: https://github.com/actions/runner/issues/801
