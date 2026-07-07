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

## Connecting

Attach an app service to the `redis-net` overlay and dial `redis:6379`,
authenticating with the `redis_password` secret. To reach Redis from outside the
overlay, set `exposure.enabled: true` (publishes a port; choose `mode: ingress` for
the cluster-wide routing mesh or `mode: host` for the pinned node only).

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `redis` | Image repository |
| `image.tag` | `""` | Tag — defaults to appVersion (`8.2.7`) |
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
| `extraConfig` | `[]` | Extra `redis-server` flags appended verbatim |
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
