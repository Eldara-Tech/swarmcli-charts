# postgres

Single-instance PostgreSQL 18 for Docker Swarm: persistent (data on a node-local named
volume), authenticated via an external Swarm secret, pinned to one node, and reachable by
other stacks over a shared overlay. Not Traefik-routed (PostgreSQL is TCP); publishes no
port by default.

## Prerequisites

1. Label the node that will hold the data volume (Swarm volumes are node-local, so the
   service is pinned to exactly one node):

   ```bash
   docker node update --label-add postgres-data=true <node>
   ```

2. Pre-create the password secret. The chart **validates** this secret but never creates it
   (its content is operator-supplied):

   ```bash
   printf 'S3cr3t' | docker secret create postgres_password -
   ```

3. (Optional) the `postgres-net` overlay — swarmcli auto-creates it if missing.

For an ephemeral database, set `persistence.enabled: false` (skip step 1 — the node pin is
dropped together with the volume).

## Installing

```bash
swarmcli charts install postgres swarmcli-charts/postgres
```

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret, config, volume and network the release
references, whatever its name. A default install needs:

```yaml
- name: postgres          # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    secrets:  [postgres_password]
    networks: [postgres-net]
```

Each entry is the name itself, so an override in values needs the same change here. See
[`allow`](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/configuration.md#allow-optional) in the swarmcli-cd docs.

## Connecting

Attach an app service to the `postgres-net` overlay and dial **`<release>_postgres:5432`** —
for the install above, `postgres_postgres:5432`. (The unqualified service name `postgres` is
also registered as a network alias, but it is ambiguous the moment two releases of this chart
share the overlay, so prefer the stack-qualified name.) Authenticate as `auth.username` against
database `auth.database` with the `postgres_password` secret.

With the [keycloak chart](../keycloak):

```bash
swarmcli charts install keycloak swarmcli-charts/keycloak \
  --set database.vendor=postgres \
  --set database.host=postgres_postgres \
  --set database.port=5432 \
  --set database.network=postgres-net
```

To reach PostgreSQL from outside the overlay, set `exposure.enabled: true`. The container
always listens on 5432 and `exposure.port` is the port published on the **host**, so a taken
5432 can be republished (`exposure.port: 15432`). `mode: ingress` binds that port on **every**
Swarm node, so prefer `mode: host` (the pinned node only) and firewall it to trusted sources —
or keep exposure disabled and stay on the overlay.

## Metrics

PostgreSQL serves no Prometheus metrics of its own, so `metrics.enabled` adds a
[postgres_exporter](https://github.com/prometheus-community/postgres_exporter) beside it. The
exporter carries the deploy labels `prometheus.io/scrape=true` and `prometheus.io/port=9187` and
joins the `monitoring` overlay, which is where the prometheus-stack chart scrapes by default — so
Prometheus finds it by itself, with no scrape config. Any Prometheus using Docker Swarm service
discovery on those labels works the same way.

```bash
openssl rand -base64 32 | docker secret create postgres_exporter_password -
swarmcli charts upgrade postgres swarmcli-charts/postgres -f postgres-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`. That flag
merges over the previous release's stored values *instead of* this chart version's defaults, so
every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

Turning it on adds two services and changes nothing about `postgres` itself, so the database
does not restart. The exporter logs in as a role of its own, `exporter`, which a one-shot service
(`postgres-exporter-user`) creates — or whose password it resets — as `auth.username` over the
overlay, and then exits. The role can log in, holds at most 3 connections, and is a member of
PostgreSQL's built-in `pg_monitor` role: it reads the statistics views and settings, and none of
your tables. Every run resets it to exactly that (`NOSUPERUSER NOCREATEDB NOCREATEROLE
NOREPLICATION NOBYPASSRLS`). The one-shot only adopts a role it created itself, which it marks
with a comment; if a role named `metrics.username` already exists for another purpose, it is
refused and left untouched, because its new password would go to the exporter. The one-shot also
switches statement logging off for its session, so `log_statement`, duration logging or a failed
statement never writes the password to the server log.

You get `pg_up` and the exporter's default collectors — per-database size, transactions and
cache hits (`pg_stat_database_*`), connections by state (`pg_stat_activity_*`), locks, WAL,
replication, the background writer, settings, and per-table statistics for `auth.database` — so
dashboards and alert rules written for postgres_exporter apply as they are.

- **The password** is read from `metrics.secretName` by both the exporter and the one-shot, and
  surrounding whitespace (the newline `openssl` appends) is ignored. A password with whitespace
  *inside* it is refused: postgres_exporter splits its connection string on spaces and could
  never log in with it, so the one-shot keeps failing and says why in
  `docker service logs postgres_postgres-exporter-user`. Use a random one as above.
- **Rotating it**: create a secret under a new name and point `metrics.secretName` at it. The
  changed spec runs the one-shot again; a scrape or two may read `pg_up 0` until it has.
- **The one-shot needs the current superuser password.** It logs in with `auth.secretName`, so if
  you changed that password inside the database without updating the secret (see *Operating
  notes*), it keeps retrying and logs the authentication error.
- **A database rebuilt from empty data** loses the role with everything else — with
  `persistence.enabled: false` that is every restart. Run the one-shot again:
  `docker service update --force <release>_postgres-exporter-user`.
- **What `monitoring` can reach**: the exporter, not the database directly. Anything on that
  overlay can read the metrics, which include role and database names and server settings. It
  can also use the exporter's `/probe?target=` endpoint, which cannot be turned off: the exporter
  connects to whatever target the caller names, with credentials the caller supplies (never its
  own). That reaches the database after all: `pg_up` answering 1 or 0 makes `/probe` a
  password-guessing oracle against `auth.username`, and it can open TCP connections to anything
  on `network.name`. Give the superuser a long random password (`openssl rand -base64 32`), and
  attach only services you trust to `monitoring`.
- `metrics.network`, `metrics.username` and `metrics.secretName` must differ from `network.name`,
  `auth.username` and `auth.secretName`, and the render fails if one does not. `metrics.username`
  must not start with `pg_`, a prefix PostgreSQL reserves.
- **Turning it off** leaves both services in place (swarmcli deploys without `--prune`). Remove
  them yourself: `docker service rm <release>_postgres-exporter <release>_postgres-exporter-user`.
- **With swarmcli-cd**, add the secret to `allow.secrets` and `monitoring` to `allow.networks`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `postgres` | Image repository |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml. Drives the derived `PGDATA` (see Operating notes) |
| `replicas` | `1` | Replica count (must stay 1 — node-local volume) |
| `auth.username` | `postgres` | `POSTGRES_USER` — the **superuser** initdb creates |
| `auth.database` | `postgres` | `POSTGRES_DB` — the database created for it |
| `auth.secretName` | `postgres_password` | External Swarm secret holding that user's password |
| `persistence.enabled` | `true` | Mount a volume at `/var/lib/postgresql` (also controls the node pin) |
| `persistence.volumeName` | `postgres-data` | Named volume (used when `volumePath` is empty) |
| `persistence.volumePath` | `""` | Absolute host path to bind-mount instead; when set it wins over `volumeName` (see Operating notes) |
| `persistence.nodeLabel` | `postgres-data` | Node label the data pin renders from (`node.labels.<nodeLabel> == true`); dropped when persistence is off, `""` skips the pin |
| `persistence.pgdata` | `""` | Overrides the derived data directory. Only needed when `image.tag` carries no major to derive from |
| `placement.constraints` | `[]` | Extra scheduling constraints (the data pin comes from `persistence.nodeLabel`) |
| `network.name` | `postgres-net` | Overlay network |
| `network.external` | `true` | Use a pre-existing/shared overlay vs chart-managed |
| `exposure.enabled` | `false` | Publish a port |
| `exposure.port` / `.protocol` / `.mode` | `5432` / `tcp` / `ingress` | Host port (mapped to the container's 5432), protocol, publish mode |
| `resources.limits.memory` | `""` | Swarm deploy memory limit |
| `healthcheck.*` | see `values.yaml` | `pg_isready -h 127.0.0.1 -U <username> -d <database>` |
| `healthcheck.monitor` | `2m` | Rollout watch window. Must cover `startPeriod + interval x retries` (110s) — see below |
| `extraArgs` | `[]` | Extra server flags, one argv element per entry (`["-c", "max_connections=200"]`) |
| `metrics.enabled` | `false` | A postgres_exporter beside the database, labelled for Prometheus service discovery. See *Metrics* |
| `metrics.image.repository` | `prometheuscommunity/postgres-exporter` | Exporter image |
| `metrics.image.tag` | pinned in `values.yaml` | Exporter image tag (a concrete pin; Renovate maintains it) |
| `metrics.username` | `exporter` | Role the exporter logs in as; the chart creates it. Must differ from `auth.username` |
| `metrics.secretName` | `postgres_exporter_password` | External Swarm secret holding that role's password |
| `metrics.network` | `monitoring` | Overlay the exporter shares with Prometheus (external, auto-created); must differ from `network.name` |
| `labels` | `{}` | Extra deploy labels (the database's only, never the exporter's) |

## Security note

The password is read from the mounted secret file via the image's `POSTGRES_PASSWORD_FILE`
convention, so the resolved value appears only inside the container — never in the compose file
or `docker inspect`, which show only the `/run/secrets/...` path. The healthcheck needs no
password: `pg_isready` reports that the server *responds*, not that it authenticated.

**`auth.username` is a superuser.** PostgreSQL has one bootstrap role — `POSTGRES_USER` *is* the
account initdb creates, so there is no root/app-user split like the [mariadb chart](../mariadb)'s
`auth.appUser`. Anything you hand these credentials to can drop any database in the cluster. That
is fine for a database dedicated to one app; when several apps share an instance, or you want an
app to hold less than superuser rights, create a least-privilege role once after first boot:

```bash
docker exec -it $(docker ps -q -f label=com.docker.swarm.service.name=postgres_postgres) \
  psql -U postgres -c "CREATE ROLE app LOGIN PASSWORD 'app-pw';" \
       -c "CREATE DATABASE app OWNER app;"
```

## Operating notes

- **One mount, a version-namespaced data directory.** The volume (or host path) is mounted at
  `/var/lib/postgresql` — the *parent* — and the data directory itself is
  `/var/lib/postgresql/<major>/docker`, derived from `image.tag` (or `appVersion`) and rendered
  as `PGDATA`. That is the postgres 18+ image's own default layout, and the image's documented
  opt-in for 17 and older, so **one mount contract serves every major**: `image.tag: "15"` needs
  no other change. Keeping `PGDATA` *below* the mountpoint is also what makes host-path
  persistence safe (see below). A tag with no leading digits (`postgres:alpine`, a custom image)
  has no major to derive from — the render fails rather than guess, and `persistence.pgdata`
  is the explicit escape hatch.
- **Major upgrades are not automatic.** Bumping the major against an existing volume — via
  `image.tag`, or by upgrading to a chart whose `appVersion` moved — makes the container
  **refuse to start**: PostgreSQL 18+ images detect the older cluster still sitting under the
  mount and exit with a `pg_upgrade` error rather than initialise an empty database next to it.
  Your data is safe, but the service stays down until you migrate it (`pg_upgrade`, or a
  `pg_dump`/restore into a fresh release). Treat a major bump as a planned maintenance, not a
  redeploy.
- **Password rotation is not automatic.** `POSTGRES_PASSWORD_FILE` is applied only during
  first-boot initialization (an empty data directory). Once the volume holds a cluster, editing
  the Swarm secret and re-deploying does **not** change the stored password — new app tasks then
  fail to authenticate. Rotate inside the database (`ALTER ROLE postgres PASSWORD '…'`), then
  update the secret to match. (Persistence off — an ephemeral database — re-reads the secret on
  every boot, since each boot re-initializes.) `auth.username`/`auth.database` are likewise
  first-boot only: changing them on an existing volume does not rename anything.
- **Host-path persistence.** By default data lives on the node-local named volume
  `postgres-data` (durable across restarts/redeploys, under Docker's own volume storage). To
  store it under a directory you choose instead, set `persistence.volumePath` to an absolute
  path — it takes precedence over `volumeName` and `/var/lib/postgresql` is **bind-mounted**
  from that path on the pinned node. The directory must already exist on that node and be
  writable by the container's `postgres` uid (`999`); the entrypoint creates and chowns `PGDATA`
  beneath it on first init. Because `PGDATA` is a subdirectory of the mount, initdb never has to
  chown or empty the mountpoint itself — the classic "bind mount is not empty / cannot be
  chowned" failure does not arise. A bind mount is direct host-filesystem access, acknowledged by
  this chart's `swarmcli-charts/allow: "host-mount"` annotation. (A host path in `volumeName` is
  rejected at render time — that field is a Docker named-volume name and cannot contain `/`.)
- **Ephemeral mode still gets a volume — an anonymous one.** The image declares
  `VOLUME /var/lib/postgresql`, so with `persistence.enabled: false` Swarm attaches an anonymous
  volume there. It is discarded with the task (a recreated task gets a fresh, empty one), so the
  database is ephemeral as advertised — but the anonymous volumes are not stack-labelled, so
  `uninstall --purge-volumes` cannot see them; `docker volume prune` on the node clears them.
- **Backups / availability.** Data lives only on the pinned node's local volume and the service
  runs a single replica, so there is no built-in HA: if that node is lost the database is
  unavailable until it returns or you restore a backup. Back the volume up out-of-band
  (`pg_dump`/`pg_basebackup`).

## Using it as an application backend

- **[keycloak](../keycloak)** — `database.vendor: postgres`, wiring as shown under
  [Connecting](#connecting). Keycloak 26.5+ supports PostgreSQL 14–18 and tests against 18, so
  the chart default matches.
- **superset** — the chart default (18) works: superset's e2e deploys Superset against it on
  every push. Superset's older docs stopped at PostgreSQL **15**, which was documentation lag
  rather than a ceiling; its 6.x docs publish no numbered ceiling at all and upstream's own
  compose runs 17 — see [PostgreSQL versions](../superset/README.md#postgresql-versions). To stay
  inside the range those older docs published, pin `image.tag: "15"`; the mount contract is
  unchanged, only `PGDATA` moves to `/var/lib/postgresql/15/docker`.

### Why `healthcheck.monitor` exists

Swarm watches a task for `update_config.monitor` **after creating it**, and only a
failure inside that window counts against the rollout. Leave it unset and swarm
applies a 5s default — so a container that takes longer than that to be declared
unhealthy never fails the deploy: the rollout is reported complete and the task
quietly restart-loops. `swarmcli charts lint` warns when `monitor` is shorter
than `start_period + interval x retries`.

**Raise it if you raise the healthcheck values above**, or the lint will tell you.
