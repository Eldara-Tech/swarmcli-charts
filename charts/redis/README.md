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
(skip step 2). For an ephemeral cache, set `persistence.enabled: false` and
`placement.constraints: []` (skip step 1).

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
| `persistence.enabled` | `true` | Mount a named volume at `/data` |
| `persistence.volumeName` | `redis-data` | Named volume |
| `persistence.appendonly` | `true` | Enable AOF |
| `placement.constraints` | `["node.labels.redis-data == true"]` | Node pin |
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

## Security note

The official Redis image has no `REDIS_PASSWORD` env and no requirepass-from-file
directive, so the password is read from the mounted secret at container start and
passed to `redis-server`. The resolved value appears only in the in-container
process args — never in the compose file or `docker inspect` (which show the
unresolved `$(cat /run/secrets/redis_password)` literal). The healthcheck reads the
same secret via `REDISCLI_AUTH`, so the password never appears on a `redis-cli`
command line either.
