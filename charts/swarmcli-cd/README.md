# swarmcli-cd

[SwarmCLI CD](https://github.com/Eldara-Tech/swarmcli-cd) on Docker Swarm: the GitOps
controller that converges this swarm to the desired state declared in a git repository,
and serves the API `swarmcli-cd status`, `app list` and any UI read it through.

It is the other half of the loop this repository's charts sit in. Where
[`swarmcli charts apply`](../../docs/gitops.md) pushes from CI after a merge, this pulls:
the controller runs *on* the swarm, watches the repositories itself, and reconciles what
it finds — including drift a `docker service update` introduced behind your back.

> **This container is root-equivalent on your swarm.** It applies manifests through the
> mounted Docker socket, from a manager node. Whoever can commit to the repositories it
> tracks can run anything on this cluster. The defaults below are cautious for that
> reason: the API is published nowhere, prune is off, and every credential is an external
> Swarm secret you create.

## Quick start

The controller refuses to start without an admin token, and refuses to start on an empty
application set — so there are exactly two things to create first:

```bash
printf '%s' "$(openssl rand -hex 32)" | docker secret create swarmcli-cd-token -
docker config create swarmcli-cd-applications ./applications.yaml
```

Start `applications.yaml` from
[the upstream example](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/examples/applications.yaml);
the field reference is
[configuration.md](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/configuration.md).
Then label the node that will hold the controller's data, and install:

```bash
docker node update --label-add swarmcli-cd-data=true <manager-node>
swarmcli charts install cd swarmcli-charts/swarmcli-cd
```

`docker service logs cd_controller` is the whole of it — the reconcile events, the
applier's per-resource lines and the seam report at startup alike.

## Where the application set lives

The set is the list of applications to reconcile. Four shapes, chosen by `appset.mode`:

| `appset.mode` | The set changes when | Needs |
|---|---|---|
| `static` (default) | you create a new Docker config and redeploy | nothing |
| `git` | you commit to the tracked branch | an **HTTPS** repository URL |
| `git-sync` | you commit to the tracked branch | an **SSH** URL, a deploy key and pinned host keys |
| `dir` | something you deploy writes the file | an external volume and your own writer |

`static` is immutable by construction: a Docker config cannot change under the process, so
nothing moves without a redeploy. That is the right answer for an air-gapped or
tightly-controlled deployment, and the wrong one if adding an application should be a
commit — which is what the other three are for.

### `git` — the controller polls the repository

```yaml
appset:
  mode: git
  path: gitops/swarmcli-cd/applications.yaml
  repo:
    url: https://github.com/your-org/apps.git
    revision: main
git:
  username: x-access-token
  tokenSecret: swarmcli-cd-git-token   # private repositories only
```

No sidecar, no shared volume. **HTTPS only** — swarmcli-cd's git client refuses `ssh://`
and `git@host:` remotes, so the chart refuses them here too rather than letting the
controller crash-loop on it.

### `git-sync` — the same, over SSH

The mode this chart exists for if your forge is only reachable over SSH: a self-hosted
GitLab, a non-standard port, a deploy key. A sidecar in the same stack clones the
repository and publishes the file onto a shared volume, and the controller reads that
directory (`--appset-dir`).

```bash
docker secret create swarmcli-cd-appset-ssh-key ./id_ed25519
ssh-keyscan -p 10022 gitlab.example.com > known_hosts
docker secret create swarmcli-cd-appset-known-hosts ./known_hosts
```

```yaml
appset:
  mode: git-sync
  path: gitops/swarmcli-cd/applications.yaml
  repo:
    url: ssh://git@gitlab.example.com:10022/infra/apps.git
    revision: main
  sync:
    intervalSeconds: 120
```

Three things about it are deliberate:

- **`knownHostsSecret` is required, and there is no `ssh-keyscan` at startup.** Scanning
  the host at boot trusts whatever answers on that port, which is the thing
  `StrictHostKeyChecking` exists to refuse. Take the keys once, from a host you trust, and
  hand them over as a secret. For a non-standard port the entry's host field must be
  `[host]:port` — which is exactly what `ssh-keyscan -p` writes, so take it with the
  command above rather than by hand.
- **The publish is a rename**, not a rewrite. A file rewritten in place can be read
  half-written; that read fails to parse, which is safe, but a truncation that is still
  valid YAML cannot be told from a set you meant to shrink.
- **`path` is still the path in the repository.** The sidecar always publishes it as
  `applications.yaml` in the shared directory, so this value means one thing in both git
  modes.

The end-to-end lag is `sync.intervalSeconds` plus `appset.interval`: one is how often the
repository is fetched, the other how often the controller re-reads the published file.

### `dir` — bring your own writer

```yaml
appset:
  mode: dir
  dirVolumeName: gitops-appset   # EXTERNAL: your writer lives in another stack
```

For the Flux source-controller pattern, or a git-sync of your own. **That writer must
publish atomically** (write a temporary file, `rename` it over the target), and it must run
on the same node as the controller — a Swarm volume is node-local, which is what
`persistence.nodeLabel` pins.

A set that has not arrived yet is not fatal in any of the three non-static modes: the
controller starts with no applications, says so on `status` and in the log, and retries.

## Reaching the API

`exposure.mode: none` is the default and means what it says. The API holds
root-equivalent access to the swarm behind a **single shared bearer token over plaintext
HTTP**, so it is not published for you.

| `exposure.mode` | |
|---|---|
| `none` (default) | nothing published. Reach it over an SSH tunnel to the node — `ssh -L 8080:127.0.0.1:8080 manager` — or from inside the swarm |
| `traefik` | Traefik deploy labels on `exposure.network`. TLS terminated at the edge, which makes this the only mode that does not put the token on the wire in clear |
| `published` | publish the port on the swarm. No TLS and no second factor: on a node with a public address, this puts your swarm on the internet |

Put a middleware in front of it if you route it:

```yaml
exposure:
  mode: traefik
ingress:
  host: cd.example.com
  tls: true
traefik:
  middlewares: [cd-auth@file]
```

The Traefik defaults match [the traefik chart](../traefik) in this repository —
entrypoints `http`/`https`, cert resolver `le`, constraint label `traefik-public`. Adjust
them if you run your own; the full label contract is in
[charts/traefik/README.md](../traefik/README.md#routing-a-service).

Nothing is exposed by the container port either way: the controller always listens on
8080 inside the container, and `publish.port` is only the outside of that mapping.

## Prune, and two controllers on one swarm

By default an application that leaves the set stops being reconciled and **its stack is
left running**, reported as orphaned. `prune.enabled` deletes it instead — so with prune
on, removing an entry to park something is an outage rather than a pause. `prune.volumes`
extends that to named volumes, the one part nothing can restore.

**If more than one swarmcli-cd runs against this swarm, give each its own
`controllerId`.** Every release carries the stamp `cd/<controllerId>/<application>` and the
prune sweep only considers releases stamped for itself; two controllers sharing an id each
see the other's applications as departed, and with prune on they delete each other's
deployments. The controller cannot detect this from the inside.

## Private registries

Image-pull credentials are per application, not per controller: an application's
`registryAuth:` in the set names a Docker secret, and it can use only the one it names.
Create each, then list them so the chart mounts them:

```bash
docker --config /tmp/rc login ghcr.io -u <user> -p <pat>
docker secret create swarmcli-cd-regauth-edge /tmp/rc/config.json
```

```yaml
registryAuthSecrets: [swarmcli-cd-regauth-edge]
```

Static credentials only — the image ships no credential helpers, so a `config.json` using
`credsStore`/`credHelpers` is refused at startup, and short-lived ECR/GCR tokens have to be
refreshed out of band.

## Rotating the applications config

A Swarm config is immutable: redeploying changed contents under an existing name is
refused by the daemon. `appset.configVersion` is the seam — the chart mounts
`<configName>_<configVersion>`, so a new version is a new object:

```bash
V=$(sha256sum applications.yaml | cut -c1-12)
docker config inspect swarmcli-cd-applications_$V >/dev/null 2>&1 \
  || docker config create swarmcli-cd-applications_$V ./applications.yaml
swarmcli charts upgrade cd swarmcli-charts/swarmcli-cd --set appset.configVersion=$V
```

Derived from the file's contents, an unchanged file resolves to the same name and deploys
nothing.

## Prerequisites

- A **manager node** — `node.role == manager` is rendered unconditionally. The controller
  talks to the swarm's own API, which only a manager serves; on a worker every apply fails.
- The **data node label**, unless `persistence.nodeLabel` is empty:
  `docker node update --label-add swarmcli-cd-data=true <node>`.
- `traefik-public` (or whatever `exposure.network` names) must already exist in `traefik`
  mode — it is declared `autoCreate: false`, because a controller that created it would
  create one the edge proxy is not on, and the route would 404 rather than fail loudly.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `eldaratech/swarmcli-cd` | Container image |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `appset.mode` | `static` | `static`, `git`, `git-sync` or `dir` |
| `appset.path` | `""` | The set's path — within the repository (`git`, `git-sync`) or within the mounted directory (`dir`, default `applications.yaml`) |
| `appset.interval` | `3m` | How often the set is re-read. Ignored by `static` |
| `appset.configName` | `swarmcli-cd-applications` | `static`: **external** Docker config holding the applications file |
| `appset.configVersion` | `""` | `static`: rotation key. The chart mounts `<configName>_<configVersion>` |
| `appset.repo.url` | `""` | `git` (HTTPS) / `git-sync` (SSH) repository URL |
| `appset.repo.revision` | `main` | Branch, tag or SHA to track — pin it |
| `appset.sync.image.repository` | `alpine/git` | `git-sync`: the sidecar image |
| `appset.sync.image.tag` | `2.47.2` | `git-sync`: sidecar image tag |
| `appset.sync.intervalSeconds` | `120` | `git-sync`: seconds between fetches |
| `appset.sync.sshKeySecret` | `swarmcli-cd-appset-ssh-key` | `git-sync`: **external** secret with the deploy key |
| `appset.sync.knownHostsSecret` | `swarmcli-cd-appset-known-hosts` | `git-sync`: **external** secret with the accepted host keys. Required |
| `appset.sync.volumeName` | `swarmcli-cd-appset` | `git-sync`: stack-scoped volume the sidecar publishes onto |
| `appset.dirVolumeName` | `swarmcli-cd-appset` | `dir`: **external** volume your own writer publishes onto |
| `exposure.mode` | `none` | `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | `traefik`: the **external** overlay the edge proxy runs on |
| `ingress.host` | `swarmcli-cd.example.com` | `traefik`: the router's `Host()` rule |
| `ingress.tls` | `true` | `traefik`: whether the public endpoint is HTTPS |
| `traefik.certResolver` | `le` | ACME resolver name on your Traefik |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Entrypoint names on your Traefik |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider constraint label — without it the service is never discovered |
| `traefik.redirectMiddleware` | `https-redirect` | Applied to the HTTP router when `ingress.tls` |
| `traefik.middlewares` | `[]` | Extra middlewares on the public router, e.g. `[cd-auth@file]` |
| `publish.port` | `8080` | `published`: the published port |
| `publish.mode` | `ingress` | `published`: `ingress` (routing mesh) or `host` |
| `auth.adminTokenSecret` | `swarmcli-cd-token` | **External** secret holding the API admin token. The controller refuses to start without one |
| `git.username` | `""` | Git username — GitHub wants `x-access-token` |
| `git.tokenSecret` | `""` | **External** secret with the git password/token. Private repositories only |
| `registryAuthSecrets` | `[]` | **External** secrets holding `docker config.json`s, one per application that pulls from a private registry |
| `prune.enabled` | `false` | Delete an application's resources when it leaves the set |
| `prune.volumes` | `false` | Extend prune to named volumes. Requires `prune.enabled` |
| `controllerId` | `default` | This controller's identity. Two controllers on one swarm must differ |
| `log.level` | `info` | `debug`, `info`, `warn` or `error` |
| `log.format` | `text` | `text` (logfmt) or `json` |
| `persistence.enabled` | `true` | Volume for the repository clones and chart cache |
| `persistence.volumeName` | `swarmcli-cd-data` | Stack-scoped named volume |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount instead; takes precedence |
| `persistence.nodeLabel` | `swarmcli-cd-data` | Node the volumes live on, as `node.labels.<label> == true`. Empty skips the pin |
| `healthcheck.enabled` | `true` | Run `/swarmcli-cd healthcheck` against the unauthenticated `/healthz` |
| `healthcheck.interval` / `.timeout` / `.retries` / `.startPeriod` | `10s` / `5s` / `3` / `15s` | Probe timings |
| `healthcheck.monitor` | `60s` | `update_config.monitor` — must cover the probe's worst case |
| `placement.constraints` | `[]` | **Extra** constraints; the manager and data pins are rendered for you |
| `resources.limits.memory` | `""` | e.g. `1G` |
| `resources.reservations.memory` | `""` | Scheduler hint |
| `labels` | `{}` | Extra deploy labels |
| `extraHosts` | `[]` | Extra `/etc/hosts` entries as `"hostname:ip"`, for a forge the swarm's DNS cannot resolve. Rendered onto the controller **and** the git-sync sidecar |

## What the data directory is, and is not

`/var/lib/swarmcli-cd` holds repository clones and the chart cache. It is a **cache** —
release history lives in the swarm, not here — so losing it costs a re-clone rather than
state, and `persistence.enabled: false` is a supported way to run. It is still worth a
volume: without one, every restart re-clones every application.

## Security

- `docker-socket` and `host-mount` are acknowledged in `Chart.yaml`. The socket is the
  workload; the host mount is only `persistence.volumePath`, and the default named-volume
  render mounts no host path.
- Every credential is an **external** Swarm secret, passed to the controller as a file
  path. A secret is encrypted at rest in the raft log, delivered in memory, and never
  appears in `docker service inspect` — a token in the environment would.
- The controller refuses to mount any of its own secrets into a stack it reconciles, so a
  chart declaring `swarmcli-cd-token` as an external secret cannot read it.
- The chart never creates a secret and never takes a secret value through `values.yaml`.

## Upstream documentation

- [Getting started](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/getting-started.md)
- [Configuration](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/configuration.md) — the applications file, field by field
- [Concepts](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/concepts.md) — sync vs health, drift, ownership
- [HTTP API](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/api.md)
