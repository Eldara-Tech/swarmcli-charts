# gitlab-runner

[GitLab Runner](https://docs.gitlab.com/runner/) on Docker Swarm: one long-lived runner
manager that polls your GitLab for jobs and runs each one in a container on its node's own
Docker engine.

The runner's authentication token stays in an external Swarm secret and never reaches the
manifest — the chart writes a `config.toml` that references it, and the runner resolves the
reference itself when it loads the file.

**There is no Swarm executor**, and this is the thing to understand before deploying it.
The runner is *deployed* as a Swarm service, but the job containers it creates are plain
containers on one node's engine: siblings of the runner, invisible to Swarm. Swarm does not
schedule them, does not count them against this service's `resources`, and will not clean
them up. Size the node for `concurrent` jobs — not for the runner's own few tens of
megabytes.

## Prerequisites

**Create the runner in GitLab first.** Go to *Settings > CI/CD > Runners > New project
runner* (or the group/instance equivalent) and copy the authentication token it gives you —
a string starting with `glrt-`. This chart runs no `gitlab-runner register` step, because a
token in `config.toml` is all `gitlab-runner run` needs.

```bash
# The token, as an external Swarm secret (never a chart value):
docker secret create gitlab-runner-token -     # paste the glrt-… token, then Ctrl-D

# The node the runner runs on. Its job containers, image cache and job volumes all live
# there, so the chart pins it by label. Skip this only on a single-node swarm, where you
# instead set persistence.nodeLabel="".
docker node update --label-add gitlab-runner-data=true <node>
```

Registration tokens (the old flow) are not supported: GitLab deprecated them in 15.6 and
the runner's own configuration takes the authentication token in the same `token` field.

## Installing

```bash
swarmcli charts install runner swarmcli-charts/gitlab-runner \
  --set gitlab.url=https://gitlab.example.com/
```

Then check GitLab's runner page: the runner goes online within one `checkInterval`. If it
does not, read the service log — the runner says exactly what it thinks of your token.

## How the token gets in

Worth spelling out, because it is the part that would otherwise look like a missing feature:

1. The operator creates a Swarm secret holding the `glrt-…` token. Swarm mounts it at
   `/run/secrets/<name>`, readable only inside the container.
2. The container's start-up command reads that file and exports it as `RUNNER_TOKEN`.
3. The generated `config.toml` carries the literal `token = "${RUNNER_TOKEN}"`. GitLab
   Runner
   [expands environment variables in `url` and `token`](https://docs.gitlab.com/runner/configuration/advanced-configuration/#use-environment-variables-in-the-configtoml)
   when it loads the file.

So the token appears in no manifest, no `docker inspect` output and no release record — only
the reference does. The same applies to the cache credentials, which the container appends
to the end of `config.toml` at start.

One consequence: **`config.toml` is regenerated on every container start.** Editing it
inside a running container works until the next restart, and then your edit is gone. Put
changes in chart values, or in `config.extraGlobalToml` / `config.extraDockerToml`.

## Security: what the socket grants

The runner mounts the node's `/var/run/docker.sock` because that is how it creates job
containers. Three separate grants follow from that, and they are worth deciding
deliberately:

- **The runner's own socket access.** Root-equivalent on that node. Unavoidable for the
  docker executor.
- **`docker.mountSocketInJobs`** (default off) puts the same socket inside *every job
  container*, which is how a job runs `docker build`. It hands every pipeline that can run
  on this runner root on that node. GitLab's own docs describe socket binding as
  "effectively disabl[ing] the container's security mechanisms".
- **`docker.privileged`** (default off) runs job containers privileged, which is what a
  `docker:dind` service needs. It disables those containers' isolation. Swarm cannot run
  the *runner* privileged — the daemon drops the flag on a service — but the runner creates
  job containers through the engine API directly, so this setting does take effect.

**Manager or worker?** The chart renders no `node.role` constraint, because a single-node
swarm has only a manager and a `node.role == worker` default would never schedule there. On
a multi-node swarm, decide explicitly:

```yaml
placement:
  constraints:
    - node.role == worker      # jobs cannot touch the Swarm API — the safe default
    # - node.role == manager   # jobs CAN run `docker stack deploy`, i.e. own the cluster
```

Pointing a runner at a manager's socket is how you let CI deploy to the swarm, and also how
a compromised pipeline takes over every node. There is no middle setting.

## Distributed cache

Without a cache configured, a job's cache is a local Docker volume on whichever node ran it,
so a second runner node — or a rescheduled runner — is a guaranteed cache miss. Point it at
S3-compatible storage instead:

```bash
docker secret create gitlab-runner-cache-access-key -
docker secret create gitlab-runner-cache-secret-key -
```

```yaml
cache:
  enabled: true
  s3:
    server: minio:9000
    bucket: runner-cache
    insecure: true      # in-swarm MinIO over plain HTTP
    pathStyle: true     # MinIO and most S3 clones need this; AWS S3 does not
```

With `authenticationType: iam` the two secrets are neither needed nor mounted. A credential
containing a single quote is refused at start-up, because it cannot be written into the TOML
string.

Note for anyone changing the cache values: **the runner silently ignores `config.toml` keys
it does not recognise.** A mis-cased `accesskey` produces a perfectly healthy runner with a
cache that does nothing. `ci/render-check.sh` asserts the exact capitalisation for that
reason.

## Metrics

`metrics.enabled` makes the runner serve Prometheus metrics on the task's own address. The
chart deliberately offers no way to publish that port: the endpoint — and `/debug/pprof`
beside it — carries no authentication at all. Scrape it from a Prometheus inside the swarm,
or look at it by hand:

```bash
docker exec "$(docker ps -q -f label=com.docker.swarm.service.name=runner_gitlab-runner)" \
  curl -s http://127.0.0.1:9252/metrics
```

`healthcheck.enabled` probes that same endpoint, and so requires `metrics.enabled` — asking
for one without the other fails the render rather than deploying a probe that can never
pass. The probe deliberately does **not** ask GitLab whether the token is valid: a GitLab
outage would then mark every runner unhealthy and Swarm would restart them, aborting running
jobs.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `gitlab/gitlab-runner` | Runner image. |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml. Set `alpine-v<version>` for the smaller Alpine variant. |
| `replicas` | `1` | Runner managers. Each polls independently and runs up to `concurrent` jobs, so this multiplies load. Needs `persistence.enabled: false`. |
| `gitlab.url` | `https://gitlab.com/` | Your GitLab instance. Required. |
| `gitlab.name` | `""` | Runner description in the GitLab UI. Empty uses the release name. |
| `auth.tokenSecret` | `gitlab-runner-token` | External Swarm secret holding the `glrt-…` authentication token. |
| `concurrent` | `4` | Jobs this runner process runs at a time. |
| `checkInterval` | `3` | Seconds between job polls. |
| `logLevel` | `info` | `panic`, `fatal`, `error`, `warning`, `info` or `debug`. |
| `logFormat` | `text` | `runner`, `text` or `json`. |
| `shutdownTimeout` | `1800` | Seconds the runner keeps draining jobs after being asked to stop. |
| `runner.requestConcurrency` | `4` | Simultaneous job requests to GitLab. 1 bottlenecks long polling. |
| `runner.limit` | `0` | Cap on jobs for this runner entry. 0 = no cap beyond `concurrent`. |
| `runner.outputLimit` | `0` | Job log cap in kilobytes. 0 keeps the runner's own default. |
| `runner.environment` | `[]` | `"KEY=value"` strings injected into every job. |
| `docker.image` | `alpine:3.24` | Image a job gets when its `.gitlab-ci.yml` names none. |
| `docker.pullPolicy` | `if-not-present` | `always`, `if-not-present` or `never`. |
| `docker.mountSocketInJobs` | `false` | Mount the engine socket inside every job container. Root on the node — see Security. |
| `docker.privileged` | `false` | Run job containers privileged, for `docker:dind`. See Security. |
| `docker.volumes` | `[]` | Extra job volumes, e.g. `"/cache"`. |
| `docker.allowedImages` | `[]` | Image allowlist for jobs, e.g. `["alpine:*"]`. Empty allows any. |
| `docker.networkMode` | `""` | Docker network mode for job containers. |
| `docker.memory` | `""` | Per-job memory limit, e.g. `2g`. |
| `docker.cpus` | `""` | Per-job CPU limit, e.g. `"1.5"`. |
| `cache.enabled` | `false` | Store job caches in S3-compatible object storage. |
| `cache.shared` | `true` | Share cached archives between runners. |
| `cache.path` | `""` | Prefix inside the bucket. |
| `cache.s3.server` | `""` | `host:port` of the endpoint. Required when the cache is on. |
| `cache.s3.bucket` | `gitlab-runner-cache` | Bucket name. |
| `cache.s3.location` | `""` | S3 region. AWS needs it; MinIO ignores it. |
| `cache.s3.insecure` | `false` | Plain HTTP instead of HTTPS. |
| `cache.s3.pathStyle` | `false` | Path-style addressing, which MinIO needs. |
| `cache.s3.authenticationType` | `access-key` | `access-key` (the two secrets below) or `iam` (no secrets). |
| `cache.s3.accessKeySecret` | `gitlab-runner-cache-access-key` | External Swarm secret with the S3 access key. |
| `cache.s3.secretKeySecret` | `gitlab-runner-cache-secret-key` | External Swarm secret with the S3 secret key. |
| `metrics.enabled` | `false` | Serve Prometheus metrics. Never published by this chart. |
| `metrics.port` | `9252` | Port the runner listens on for metrics. |
| `healthcheck.enabled` | `false` | Probe the metrics endpoint. Requires `metrics.enabled`. |
| `healthcheck.interval` | `30s` | Probe interval. |
| `healthcheck.timeout` | `5s` | Probe timeout. |
| `healthcheck.retries` | `3` | Failures before the container is unhealthy. |
| `healthcheck.startPeriod` | `20s` | Grace period before failures count. |
| `healthcheck.monitor` | `120s` | How long Swarm counts a task failure against a rollout. |
| `stopGracePeriod` | `31m` | Time Swarm allows for draining before SIGKILL. Keep above `shutdownTimeout`. |
| `persistence.enabled` | `true` | Keep `/etc/gitlab-runner` on a volume, so `.runner_system_id` survives restarts. |
| `persistence.volumeName` | `gitlab-runner-config` | Stack-scoped named volume. No slashes. |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount instead. Takes precedence. |
| `persistence.nodeLabel` | `gitlab-runner-data` | Node label the runner is pinned to. Empty skips the pin. |
| `placement.constraints` | `[]` | Extra scheduling constraints, e.g. `node.role == worker`. |
| `resources.limits.memory` | `""` | Memory limit for the runner process only. |
| `resources.reservations.memory` | `""` | Memory reservation for the runner process only. |
| `config.extraGlobalToml` | `""` | Verbatim TOML after the global keys, before `[[runners]]`. |
| `config.extraDockerToml` | `""` | Verbatim TOML inside `[runners.docker]`. |
| `labels` | `{}` | Extra deploy labels. |
| `extraEnv` | `{}` | Extra environment for the runner process. |

Values that end up inside `config.toml` (`runner.environment`, `docker.volumes`,
`config.extra*Toml`) travel through the compose manifest, which Docker interpolates before
deploying: write a literal `$` as `$$`.

## Operating notes

**Updates drain, they do not kill — if you let them.** The image's stop signal is `SIGQUIT`,
which tells the runner to finish its running jobs and then exit. Swarm's default grace
period is 10 seconds, which would kill a build mid-flight on every update, so the chart sets
`stopGracePeriod` well above the runner's own `shutdownTimeout`. Lower them together, never
separately.

**Scaling out.** `concurrent` is per runner process, so the first lever is `concurrent`, not
`replicas`. If you do want several managers off one token, set `persistence.enabled: false`
first: each process needs its own `.runner_system_id`, and that file lives beside
`config.toml`, so replicas sharing one volume would share one identity and GitLab would see
a single runner manager. The chart refuses that combination at render time.

**Stale runner managers in the GitLab UI** are the other side of the same file: with
persistence off, every task restart mints a new `system_id` and GitLab lists each one. That
is cosmetic, and the reason `persistence.enabled` defaults to on.

**Job containers and disk.** Caches and images accumulate on the runner's node, outside
Swarm's view. The image ships `clear-docker-cache` for exactly this:

```bash
docker exec "$(docker ps -q -f label=com.docker.swarm.service.name=runner_gitlab-runner)" \
  clear-docker-cache
```

**A self-hosted GitLab on the same swarm** is reached by its routable URL, like any other
client — this chart joins no other overlay. If your GitLab uses a private CA, the image
reads one from `/etc/gitlab-runner/certs/ca.crt`; with `persistence.enabled` you can place
it on the volume.

## What this chart does not do

- **No `shell` executor**, `docker-autoscaler` or `instance` executor. `docker+machine` is
  deprecated upstream (removal in 20.0) and the autoscaling executors need cloud instance
  groups, neither of which a Swarm chart can provide.
- **No session server** (the interactive web terminal). It needs a per-task routable
  `advertise_address`, which a Swarm VIP cannot give it for more than one replica.
- **No GCS or Azure cache backends.** `config.extraDockerToml` cannot reach them either;
  they would be a chart change.
