# redis

Single-instance Redis 8.2 for Docker Swarm: persistent (AOF on a node-local named
volume), password-authenticated via an external Swarm secret, pinned to one node,
and reachable by other stacks over a shared overlay. Not Traefik-routed (Redis is
TCP); publishes no port by default.

## Prerequisites

1. Label the node that will hold the data volume (Swarm volumes are node-local, so
   the service is pinned to exactly one node):

   ```bash
   docker node update --label-add redis-data=true <node>
   ```

2. Pre-create the password secret. The chart **validates** this secret but never
   creates it (its content is operator-supplied):

   ```bash
   printf 'S3cr3t' | docker secret create redis_password -
   ```

3. (Optional) the `redis-net` overlay — swarmcli auto-creates it if missing.

For an unauthenticated cache on a trusted internal overlay, set `auth.enabled: false`
(skip step 2). For an ephemeral cache, set `persistence.enabled: false` (skip
step 1 — the node pin is dropped together with the volume).

## Installing

```bash
swarmcli charts install redis swarmcli-charts/redis
```

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret, config, volume and network the release
references, whatever its name. A default install needs:

```yaml
- name: redis             # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    secrets:  [redis_password]
    networks: [redis-net]
```

Each entry is the name itself, so an override in values needs the same change here. See
[`allow`](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/configuration.md#allow-optional) in the swarmcli-cd docs.

## Connecting

Attach an app service to the `redis-net` overlay and dial `redis:6379`,
authenticating with the `redis_password` secret. To reach Redis from outside the
overlay, set `exposure.enabled: true` (publishes a port; choose `mode: ingress` for
the cluster-wide routing mesh or `mode: host` for the pinned node only).

## Metrics

Redis serves no Prometheus metrics of its own, so `metrics.enabled` adds a
[redis_exporter](https://github.com/oliver006/redis_exporter) service,
`<release>_redis-exporter`. It carries the deploy labels `prometheus.io/scrape=true`
and `prometheus.io/port=9121` and joins the `monitoring` overlay, which is where the
[prometheus-stack](../prometheus-stack) chart scrapes by default, so Prometheus finds
it by itself with no scrape config. Any Prometheus using Docker Swarm service
discovery on those labels works the same way. Redis itself never joins `monitoring`.

```bash
openssl rand -base64 32 | docker secret create redis_exporter_password -
swarmcli charts upgrade redis swarmcli-charts/redis -f redis-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`.
That flag merges over the previous release's stored values *instead of* this chart
version's defaults, so every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

With `auth.enabled` (the default), the exporter logs in as an ACL user of its own,
`exporter`, defined on the `redis-server` command line from the SHA-256 of that
secret. Its grant reads server state and the slow log, and nothing else: `INFO`,
`LATENCY LATEST` and `HISTOGRAM`, `SLOWLOG LEN` and `GET`, `COMMAND INFO` and
`CLIENT SETNAME`. It cannot read a key or run `CONFIG` (`CONFIG GET requirepass`
returns the admin password in plain text), and a secret that is empty or only
whitespace stops Redis from starting rather than become an empty password. Without
auth there is nothing to restrict, and no secret is needed.

- **Turning metrics on restarts Redis once**, because the ACL user is part of its
  command line. With persistence on, the AOF carries the data across; an ephemeral
  instance (`persistence.enabled: false`) starts empty. Turning metrics off restarts
  it again.
- You get `redis_up`, everything `INFO ALL` reports (memory, clients, keyspace sizes,
  `redis_commands_total`, replication, persistence), per-command latency percentiles
  and the slow log's length and last entry. The exporter skips only the `CONFIG GET`
  metrics (`redis_config_*`; the ones that matter, such as `maxmemory`, are in `INFO`
  too), so no scrape is ever denied a command: `ACL LOG`,
  `redis_acl_access_denied_cmd_total` and `redis_errors_total` stay clean for real
  denials.
- **What `SLOWLOG GET` exposes.** The exporter reads the newest slow-log entry for its
  id and duration. That entry also carries the slow command's arguments (up to 32,
  each cut to 128 bytes) and the client's address and name, so a key or value in a
  slow command is readable with the exporter's credential. The exporter exports
  neither, and the credential stays in its secret: `/scrape` is disabled (below).
  Denying it instead would make every scrape count against the denial and error
  counters above, for ever.
- **`/scrape` is disabled.** redis_exporter's multi-target endpoint
  (`/scrape?target=…`) dials whatever address a caller names and authenticates with
  the exporter's own user and password (`exporter/http.go` at v1.93.0 copies the
  configured options into each target's connection), so anything on `monitoring`
  could collect them with a fake Redis. The chart passes `--disable-scrape-endpoint`.
- **Rotating the password**: create a secret under a new name and point
  `metrics.secretName` at it. Both services change, so Redis restarts, and an
  ephemeral instance (`persistence.enabled: false`) starts empty.
- **Requirements**: Redis 7.0 or later with auth on (the grant names
  `latency|histogram`, and redis-server refuses to start on an unknown command), and
  no ACL file: redis-server refuses command-line users beside one. The render refuses
  `--aclfile` anywhere in an `extraConfig` entry; an `aclfile` set inside a file
  passed with `--include` is not visible to it, and Redis then fails to start with
  "Configuring Redis with users defined in redis.conf and at the same setting an ACL
  file path is invalid".
- `metrics.network` names a different overlay. It must differ from `network.name`,
  and the render fails if it does not.
- **Turning it off** leaves the exporter running, because swarmcli deploys without
  `--prune`. Remove it yourself: `docker service rm <release>_redis-exporter`.
- With swarmcli-cd, add `redis_exporter_password` to `allow.secrets` and
  `monitoring` to `allow.networks`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `redis` | Image repository |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `1` | Replica count (must stay 1 — node-local volume) |
| `auth.enabled` | `true` | Require a password |
| `auth.secretName` | `redis_password` | External Swarm secret holding the password |
| `persistence.enabled` | `true` | Mount a volume at `/data` (also controls the node pin) |
| `persistence.volumeName` | `redis-data` | Named volume (used when `volumePath` is empty) |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount instead; when set it wins over `volumeName` (see Operating notes) |
| `persistence.nodeLabel` | `redis-data` | Node label the data pin renders from (`node.labels.<nodeLabel> == true`); dropped when persistence is off, `""` skips the pin |
| `persistence.appendonly` | `true` | Enable AOF |
| `placement.constraints` | `[]` | Extra scheduling constraints (the data pin comes from `persistence.nodeLabel`) |
| `network.name` | `redis-net` | Overlay network |
| `network.external` | `true` | Use a pre-existing/shared overlay vs chart-managed |
| `exposure.enabled` | `false` | Publish a port |
| `exposure.port` / `.protocol` / `.mode` | `6379` / `tcp` / `ingress` | Port binding |
| `maxmemory` | `""` | redis-server `--maxmemory` (e.g. `256mb`) |
| `maxmemoryPolicy` | `noeviction` | Eviction policy (applied when `maxmemory` set) |
| `resources.limits.memory` | `""` | Swarm deploy memory limit |
| `healthcheck.*` | see `values.yaml` | redis-cli PING healthcheck |
| `healthcheck.monitor` | `90s` | Rollout watch window. Must cover `startPeriod + interval x retries` (80s) — see below |
| `extraConfig` | `[]` | Extra `redis-server` flags appended verbatim |
| `metrics.enabled` | `false` | A redis_exporter labelled for Prometheus service discovery. See *Metrics*. |
| `metrics.image.repository` | `oliver006/redis_exporter` | Exporter image |
| `metrics.image.tag` | pinned in `values.yaml` | Exporter image tag (a concrete `-alpine` pin; Renovate maintains it) |
| `metrics.username` | `exporter` | ACL user the exporter logs in as (auth on); the chart defines it |
| `metrics.secretName` | `redis_exporter_password` | External secret holding that user's password (auth on) |
| `metrics.network` | `monitoring` | External overlay the exporter shares with Prometheus (auto-created) |
| `labels` | `{}` | Extra deploy labels |

## Operating notes

- **The node pin travels with persistence.** The
  `node.labels.redis-data == true` constraint is rendered from
  `persistence.nodeLabel` while `persistence.enabled` is on and dropped with it,
  so an ephemeral cache never sits `Pending` on a missing node label.
  `placement.constraints` holds *extra* constraints and is applied in all modes.
  (Before this coupling the pin lived in `placement.constraints` — a values file
  that still lists it there just applies it twice, which is harmless; to move the
  pin to a different label, set `persistence.nodeLabel` instead.)
- **Host-path persistence.** By default data lives on the node-local named volume
  `redis-data` (durable across restarts/redeploys, under Docker's own volume
  storage). To store it under a directory you choose instead, set
  `persistence.volumePath` to an absolute path — it takes precedence over
  `volumeName` and `/data` is **bind-mounted** from that path on the pinned node.
  The directory must already exist on that node and be writable by the
  container's `redis` uid (`999`); the entrypoint chowns it at start, but
  pre-creating it with the right owner (`install -d -o 999 -g 999 <path>`) is
  safest. A bind mount is direct host-filesystem access, acknowledged by this
  chart's `swarmcli-charts/allow: "host-mount"` annotation. (A host path in
  `volumeName` is rejected at render time — that field is a Docker named-volume
  name and cannot contain `/`.)

## Security note

The official Redis image has no `REDIS_PASSWORD` env and no requirepass-from-file
directive, so the password is read from the mounted secret at container start and
passed to `redis-server`. The resolved value appears only in the in-container
process args — never in the compose file or `docker inspect` (which show the
unresolved `$(cat /run/secrets/redis_password)` literal). The healthcheck reads the
same secret via `REDISCLI_AUTH`, so the password never appears on a `redis-cli`
command line either.

### Why `healthcheck.monitor` exists

Swarm watches a task for `update_config.monitor` **after creating it**, and only a
failure inside that window counts against the rollout. Leave it unset and swarm
applies a 5s default — so a container that takes longer than that to be declared
unhealthy never fails the deploy: the rollout is reported complete and the task
quietly restart-loops. `swarmcli charts lint` warns when `monitor` is shorter
than `start_period + interval x retries`.

**Raise it if you raise the healthcheck values above**, or the lint will tell you.
