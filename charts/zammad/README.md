# zammad

[Zammad](https://zammad.org/) helpdesk / ticketing on Docker Swarm. One Zammad image runs five
roles and the chart wires up its backing services:

| Service | Role |
|---------|------|
| `init` | one-shot: create/migrate/seed the database, configure Elasticsearch, build the index, then exit |
| `railsserver` | the web application (Puma) |
| `websocket` | the websocket server |
| `scheduler` | background jobs (always a single replica) |
| `nginx` | the HTTP front door — serves assets and proxies to `railsserver` + `websocket` |
| `memcached` | in-stack action cache (ephemeral) |
| `elasticsearch` | full-text search — **embedded** by default (external or disabled) |
| `postgres` | **external** by default (or embedded) — Zammad's system of record |
| `redis` | **external** by default (or embedded) — websocket sessions + job queue |
| `backup` | optional scheduled dump of the database + storage (off by default) |

Swarm has no `depends_on`, but the Zammad image self-coordinates: every non-init role blocks on
the image's own `check_zammad_ready` until migrations+seeds have landed, so there is nothing to
order by hand.

Zammad is **stateful**: uploaded attachments live on a node-local volume at `/opt/zammad/storage`
shared by every app role, so the app tier is pinned to one node (see [Storage](#storage-and-scaling)).

## Prerequisites

1. **Label the data node** (Swarm volumes are node-local, so the storage-bound services are pinned
   to one node):

   ```bash
   docker node update --label-add zammad-data=true <node>
   ```

   Skip this on a single-node swarm and set `persistence.nodeLabel=""`.

2. **Pre-create the Swarm secrets.** The chart validates them but never creates them (their content
   is operator-supplied):

   ```bash
   printf 'S3cr3t' | docker secret create zammad_db_password -
   printf 'S3cr3t' | docker secret create zammad_redis_password -     # if redis.auth.enabled (default)
   ```

3. **For the default (external) PostgreSQL + Redis**, run those charts and their overlays first —
   e.g. the [postgres](../postgres) and [redis](../redis) charts in this repo:

   ```bash
   swarmcli charts install postgres swarmcli-charts/postgres \
     --set auth.username=zammad --set auth.database=zammad_production --set auth.secretName=zammad_db_password
   swarmcli charts install redis    swarmcli-charts/redis \
     --set auth.secretName=zammad_redis_password
   ```

   Then point Zammad at them (their services are `<release>_postgres:5432` / `<release>_redis:6379`).
   The `traefik-public`, `postgres-net` and `redis-net` overlays are declared `autoCreate:false` —
   provision them with those charts, or pre-create them.

To skip the external database/Redis entirely (single-node evaluation), use `database.mode=embedded`
and `redis.mode=embedded` — the chart then runs both itself and nothing external is needed.

## Installing

Default — external PostgreSQL + Redis, embedded Elasticsearch, Traefik at the edge:

```bash
swarmcli charts install zammad swarmcli-charts/zammad \
  --set ingress.host=support.example.com \
  --set database.host=postgres_postgres \
  --set redis.host=redis_redis
```

One-command evaluation — everything in-stack, published directly on port 8080:

```bash
swarmcli charts install zammad swarmcli-charts/zammad \
  --set database.mode=embedded --set redis.mode=embedded \
  --set exposure.mode=published --set ingress.host=support.example.com
```

## Exposure

`exposure.mode` controls how the `nginx` front door is reached:

- **`traefik`** (default) — Traefik deploy labels on `exposure.network`. TLS terminates at the edge;
  nginx serves plain HTTP on the backend and Zammad advertises the forwarded scheme so its links are
  `https://`. Defaults match the [traefik](../traefik) chart (entrypoints `http`/`https`, cert
  resolver `le`, constraint label `traefik-public`, redirect middleware `https-redirect`); override
  the `traefik.*` values if you run your own Traefik.
- **`published`** — publish nginx's port on the swarm directly (no proxy, no TLS). Behind your own
  load balancer or for a private swarm.
- **`none`** — no published port and no Traefik labels; nginx sits on `exposure.network` so your own
  reverse proxy (joined to that overlay) can reach it.

`ingress.host` is the public address users type — it drives Zammad's absolute links and, in traefik
mode, the `Host()` router rule. `ingress.tls` selects whether the public endpoint is HTTPS.

## Elasticsearch

`elasticsearch.mode`:

- **`embedded`** (default) — a single-node Elasticsearch this chart runs and persists (its own
  volume + the data pin). `discovery.type=single-node` skips the bootstrap checks, so it starts
  without a host `vm.max_map_count` sysctl or added capabilities. For a real workload set
  `vm.max_map_count=262144` on the data node anyway (`sysctl -w vm.max_map_count=262144`) and size
  `elasticsearch.javaOpts` / `elasticsearchResources` to the corpus.
- **`external`** — point `elasticsearch.host`/`schema`/`port` at an existing cluster on
  `elasticsearch.network`; set `elasticsearch.auth.*` (and the `zammad_elasticsearch_password`
  secret) if it requires credentials.
- **`disabled`** — Zammad runs with **database-based search** (no full-text on article bodies). The
  lightest deployment; upstream-supported for small teams.

## Backing services (external vs embedded)

`database.mode` and `redis.mode` are each `external` (default) or `embedded`:

- **external** — the production path. Run the PostgreSQL/Redis on their own overlays and point the
  connection values at them; the data survives a redeploy of this stack and one backing service can
  serve several.
- **embedded** — the chart runs the service inside this stack, for single-node evaluation. Embedded
  **PostgreSQL is persistent** (its own volume + the data pin — it is Zammad's system of record);
  embedded **Redis is ephemeral** (no volume — a restart drops queued jobs and websocket sessions,
  which Zammad tolerates). Passwords come from the same external secrets either way.

Memcached is always in-stack (a small ephemeral cache); set `memcache.servers` to an existing
`host:11211` to use an external one instead (it must be reachable on an overlay the app roles already
attach to).

> **Redis password must be URL-safe.** Zammad's standalone Redis client reads only `REDIS_URL`
> (the separate `REDIS_PASSWORD` is sentinel-only), so the chart embeds the password into the URL
> as `redis://:<password>@host:port`. Use a password without URL-reserved characters (`@ : / # ?`)
> — e.g. `openssl rand -hex 24`. Set `redis.auth.enabled=false` for an unauthenticated Redis on a
> private overlay (the zero-secret path, natural with `redis.mode=embedded`).

## Storage and scaling

The app roles share a node-local named volume for `/opt/zammad/storage`, so by default the whole app
tier is pinned to one `persistence.nodeLabel` node and `railsserver` stays a single replica. Options
for going wider:

- **Host path** — set `persistence.storagePath` (and `database.embedded.volumePath` /
  `elasticsearch.persistence.volumePath` / `backup.volumePath`) to bind-mount an absolute host
  directory instead of a managed named volume.
- **Multiple app replicas on the pinned node** — `replicas.railsserver` / `replicas.websocket` may be
  raised; on the pinned node they share the same volume.
- **True multi-node** — move attachments off the shared filesystem so the app tier can schedule
  anywhere: either Zammad's **database storage provider** (Settings → System → Storage, then the app
  roles need no shared volume — set `persistence.enabled=false`), or an **external shared volume
  driver** (NFS/CIFS) for `/opt/zammad/storage`. Both are operator choices outside this chart.
- **Ephemeral** — `persistence.enabled=false` drops all volumes and the node pin (attachments/DB/index
  are lost on reschedule): evaluation only.

## Tuning

Zammad exposes many `ZAMMAD_*` knobs (scheduler worker counts, Puma concurrency, HTTP timeouts,
GraphQL introspection). Set them through `extraEnv`, which is injected verbatim into every role:

```yaml
extraEnv:
  ZAMMAD_WEB_CONCURRENCY: "3"
  ZAMMAD_PROCESS_DELAYED_JOBS_WORKERS: "4"
```

## Rotating a secret

The DB/Redis passwords are read from the mounted secret at container start, so rotating one is:
update the secret's value at the source (and in PostgreSQL/Redis), then redeploy the release so the
tasks re-read `/run/secrets/*`. Swarm secrets are immutable, so "update the secret" means create a
new secret and point the relevant `*SecretName` value at it.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `ghcr.io/zammad/zammad` | Zammad image |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `ingress.host` | `zammad.example.com` | Public address (ZAMMAD_FQDN + traefik Host rule) |
| `ingress.tls` | `true` | Public endpoint is HTTPS (selects the forwarded scheme) |
| `exposure.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `exposure.network` | `traefik-public` | Shared ingress overlay (traefik & none modes) |
| `traefik.*` | see `values.yaml` | Cert resolver / entrypoints / constraint label / redirect middleware |
| `publish.port` / `.mode` | `8080` / `ingress` | Host port + publish mode (published exposure) |
| `service.nginxPort` / `.railsPort` / `.websocketPort` | `8080` / `3000` / `6042` | Container ports |
| `nginx.clientMaxBodySize` | `50M` | Largest attachment upload nginx accepts |
| `nginx.serverName` | `_` | nginx `server_name` (catch-all is right behind Traefik) |
| `trustedProxies` | `0.0.0.0/0` | `RAILS_TRUSTED_PROXIES` — peers trusted for X-Forwarded-* |
| `replicas.railsserver` / `.websocket` | `1` / `1` | App-role replicas (scale on the pinned node) |
| `internalNetwork` | `zammad-internal` | Chart-managed overlay for in-stack traffic |
| `persistence.enabled` | `true` | Storage volumes + node pin (false ⇒ ephemeral) |
| `persistence.nodeLabel` | `zammad-data` | Data-pin node label (`""` skips the pin) |
| `persistence.storageVolumeName` / `.storagePath` | `zammad-storage` / `""` | Attachment volume (host path via `storagePath`) |
| `placement.constraints` | `[]` | Extra scheduling constraints (the data pin travels with persistence) |
| `database.mode` | `external` | `external` \| `embedded` |
| `database.host` / `.port` / `.name` / `.username` | `postgres_postgres` / `5432` / `zammad_production` / `zammad` | Connection (host ignored when embedded) |
| `database.passwordSecretName` | `zammad_db_password` | External secret for the DB password |
| `database.options` / `.createDb` | `?pool=50` / `true` | Connection options / let init create the DB |
| `database.network` | `postgres-net` | External overlay (external mode) |
| `database.embedded.*` | see `values.yaml` | Image + volume for the embedded (persistent) PostgreSQL |
| `redis.mode` | `external` | `external` \| `embedded` (embedded is ephemeral) |
| `redis.host` / `.port` | `redis_redis` / `6379` | Connection (host ignored when embedded) |
| `redis.auth.enabled` / `.secretName` | `true` / `zammad_redis_password` | Redis auth |
| `redis.network` | `redis-net` | External overlay (external mode) |
| `memcache.servers` / `.memoryMB` | `""` / `256` | External memcached, or the embedded one's size |
| `elasticsearch.mode` | `embedded` | `embedded` \| `external` \| `disabled` |
| `elasticsearch.schema` / `.host` / `.port` | `http` / `""` / `9200` | Connection (external mode) |
| `elasticsearch.namespace` / `.reindex` | `zammad` / `true` | Index prefix / build the index on first boot |
| `elasticsearch.auth.*` | disabled | External-cluster credentials + secret |
| `elasticsearch.javaOpts` | `-Xms1g -Xmx1g` | Embedded node heap |
| `elasticsearch.network` | `elasticsearch-net` | External overlay (external mode) |
| `elasticsearch.persistence.*` | see `values.yaml` | Embedded index volume (host path option) |
| `backup.enabled` | `false` | Render the scheduled backup service |
| `backup.time` / `.holdDays` / `.onStart` / `.tz` | `03:00` / `10` / `true` / `Europe/Berlin` | Backup schedule/retention |
| `backup.volumeName` / `.volumePath` | `zammad-backup` / `""` | Backup target volume (host path option) |
| `extraEnv` | `{}` | Extra env injected into every Zammad role |
| `resources.*` / `elasticsearchResources.*` | `""` | Per-service memory limits/reservations |
| `healthcheck.*` | see `values.yaml` | Container healthchecks (generous `startPeriod` for first boot) |
