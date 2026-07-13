# superset

[Apache Superset](https://superset.apache.org/) — the open-source BI and data-visualization
platform — on Docker Swarm.

Superset is **stateless** in this chart: all of its durable state lives in an **external metadata
database** (PostgreSQL or MySQL), so there is no volume and no node pin. Redis is required too —
bring your own (`redis.mode: external`, the default and the production path) or let the chart run
an ephemeral one for you (`redis.mode: embedded`, see [Redis](#redis)). The stack renders up to
five services:

| Service | What it is |
|---|---|
| `init` | one-shot: `superset db upgrade` (migrations) → `superset init` (roles/permissions) → the bootstrap admin. Runs to completion and is not restarted. |
| `app` | the web app (gunicorn). Traefik-routed by default. |
| `worker` | a Celery worker — Alerts & Reports, thumbnails, cache warm-up, async SQL Lab. |
| `beat` | the Celery scheduler. Always exactly one replica. |
| `redis` | only with `redis.mode: embedded` — the Redis the chart runs itself. Ephemeral. |

`app`, `worker` and `beat` wait for `init` to finish migrating before they start (Swarm has no
`depends_on`, and Superset's migrations take no lock).

> **The stock Superset image has no database driver.** `apache/superset:5.0.0` is upstream's
> *lean* build: it installs `requirements/base.txt` only, so `psycopg2`, `mysqlclient` and
> `Authlib` are all absent — it cannot reach *any* metadata database out of the box. This chart
> installs the right driver at start (see [Python packages](#python-packages)); for production,
> bake your own image instead.

## Prerequisites

**1. The four Swarm secrets.** The chart **validates** these and never creates them:

```bash
openssl rand -base64 42 | tr -d '\n' | docker secret create superset_secret_key -
printf 'S3cr3t'  | docker secret create superset_db_password -
printf 'S3cr3t'  | docker secret create superset_redis_password -   # redis.auth.enabled (skip it with redis.mode: embedded + auth.enabled: false)
printf 'S3cr3t'  | docker secret create superset_admin_password -   # init.admin.enabled
printf 'S3cr3t'  | docker secret create superset_oidc_client_secret -  # oidc.enabled only
```

**2. A metadata database**, reachable on `database.network`, with the database and the user
already created (the chart runs the migrations, not the provisioning):

```sql
CREATE DATABASE superset;
CREATE USER superset WITH PASSWORD '…';           -- the superset_db_password secret
GRANT ALL PRIVILEGES ON DATABASE superset TO superset;
```

**3. A Redis** — **only if** you keep the default `redis.mode: external`, in which case it must be
reachable on `redis.network` (see [Redis](#redis)). With `redis.mode: embedded` the chart runs its
own and there is nothing to provision.

Redis itself is required in **every** configuration, including `celery.enabled: false` and
`exposure.mode: none`: Superset uses it for the Celery broker and result backend, for all four
caches, *and* for rate-limit storage — the image bakes `SUPERSET_ENV=production`, which turns rate
limiting on, and its default in-memory store is per-replica. Redis is not part of exposure and no
exposure mode makes it optional. What `redis.mode` chooses is **who runs it**, not whether you need
one.

**4. The overlays.** swarmcli validates but never creates these (`autoCreate: false`):
`traefik-public` (the edge, in `traefik`/`none` modes), `database.network`, and — with
`redis.mode: external` — `redis.network`. The embedded Redis's overlay is the one network this
chart *owns*: the stack creates it, so it does not have to pre-exist.
`swarmcli charts template <release> swarmcli-charts/superset --requirements` prints the resolved
list for your values.

## Installing

```bash
swarmcli charts install superset swarmcli-charts/superset \
  --set ingress.host=superset.example.com \
  --set database.host=postgres_postgres \
  --set redis.host=redis_redis
```

Or, with the chart running its own Redis — no Redis, no `redis-net` to provision first:

```bash
swarmcli charts install superset swarmcli-charts/superset \
  --set ingress.host=superset.example.com \
  --set database.host=postgres_postgres \
  --set redis.mode=embedded
```

First boot takes a few minutes: the image is ~930 MB, the driver is pip-installed, and `init`
then runs the full alembic migration chain. Watch it with
`docker service logs -f superset_init`.

> **Do not use `--wait`.** swarmcli counts a service converged when its *desired* task count is
> met; a one-shot service that has finished sits at `0/1` forever, so `--wait` times out and
> `swarmcli charts status` shows `init 0/1` even on a perfectly healthy stack. That `0/1` is the
> expected steady state for `init`, not a failure.

## Python packages

The lean image ships no driver, and it runs as the non-root `superset` user — so the chart
pip-installs what is missing into `/tmp/pip-packages` at start and prepends `PYTHONPATH`
(upstream's own compose sidesteps this by running the container as **root**; this chart does
not). `python.installDrivers` picks the package from `database.dialect`:

| dialect | SQLAlchemy driver | package |
|---|---|---|
| `postgresql` | `postgresql+psycopg2` | `psycopg2-binary==2.9.6` |
| `mysql` | `mysql+pymysql` | `PyMySQL==1.1.1` |

plus `Authlib==1.6.5` when `oidc.enabled`. `python.extraPackages` adds more — drivers for the
**analytics** databases you connect Superset to, for instance.

PyMySQL rather than Superset's own `mysqlclient` extra because it is pure Python: the lean image
has no compiler, so `mysqlclient` cannot be installed at runtime. If your derived image carries
`mysqlclient`, point `database.sqlalchemyUri` at a `mysql+mysqldb://…` URI instead.

**For production, bake the drivers into an image** — it removes a PyPI round-trip (and a PyPI
outage) from every task start:

```dockerfile
FROM apache/superset:5.0.0
USER root
RUN uv pip install psycopg2-binary==2.9.6 Authlib
USER superset
```

```yaml
image:
  repository: registry.example.com/superset
  tag: 5.0.0-drivers
python:
  installDrivers: false
```

An air-gapped swarm that keeps `installDrivers: true` needs `python.indexUrl` pointed at a
mirror.

## Configuration

Superset 5 has **no environment-variable configuration mechanism** (the `SUPERSET__*` scheme
does not exist in this version) — it is configured by a Python file. The chart renders that
`superset_config.py` from your values, ships it base64-encoded in `SUPERSET_CONFIG_B64`, and each
service decodes it to `SUPERSET_CONFIG_PATH` at start. It wires the metadata database, the four
Redis caches, the Celery broker/result backend, rate-limit storage, cookie hardening, feature
flags and (optionally) OIDC.

Read what your values produce with:

```bash
swarmcli charts template superset swarmcli-charts/superset -f my-values.yaml \
  | yq '.services.app.environment.SUPERSET_CONFIG_B64' | base64 -d
```

`config.extraPy` is appended verbatim, last, so it overrides anything the chart sets — that is
the escape hatch for settings the chart does not model (`CUSTOM_SECURITY_MANAGER`,
`TALISMAN_CONFIG`, SQL Lab limits, …).

## Exposure modes

| `exposure.mode` | What you get |
|---|---|
| `traefik` (default) | Traefik deploy labels on `exposure.network`. TLS at the edge; Superset trusts `X-Forwarded-*`. |
| `published` | The app port published on the swarm directly. Plain HTTP — Superset cannot terminate TLS. |
| `none` | No port, no labels. Superset sits on `exposure.network` for your own reverse proxy, and still trusts `X-Forwarded-*`. |

`none` does **not** mean "on no network". The app still joins `exposure.network`, because that
overlay is exactly how your own proxy reaches it — so the overlay must exist in `traefik` **and**
`none` modes, and only `published` drops it. If you do not want a separate ingress overlay, point
`exposure.network` at one you already have (the database or Redis overlay, say): the chart
deduplicates the attachments rather than emitting the network twice. The one exception is the
**embedded** Redis overlay, which the chart manages and therefore cannot share — see
[Redis](#redis).

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository (entrypoints
`http`/`https`, cert resolver `le`, constraint label `traefik-public`, redirect middleware
`https-redirect`). Running your own Traefik? Override them to match it — see "Routing a service"
in the [traefik chart README](../traefik/README.md).

## Redis

Redis is not optional (see [Prerequisites](#prerequisites)); `redis.mode` only decides **who runs
it**.

| | `external` (default) | `embedded` |
|---|---|---|
| Who runs Redis | you — the [redis chart](../redis) or your own | this chart, as a fifth service |
| Survives a redeploy | **yes** (the redis chart persists to a volume) | **no** — it is ephemeral |
| To provision first | a Redis + its overlay | nothing |
| Shareable with other stacks | yes | no — its overlay is stack-private |
| Use it for | **production** | single-node, evaluation, dev |

### `redis.mode: external` — connecting to the redis chart

Deploy the [redis chart](../redis) with its defaults — it owns and auto-creates the `redis-net`
overlay. On a shared overlay a service is addressed by its **stack-qualified** Swarm name, so
with `swarmcli charts install redis …` the host is `redis_redis`:

```yaml
redis:
  mode: external      # the default
  host: redis_redis   # <redis-release>_redis
  port: 6379
  network: redis-net  # the redis chart's overlay
  auth:
    enabled: true
    secretName: superset_redis_password   # must hold the SAME password as redis_password
```

Both stacks must read the same password. Either create one secret under both names, or point the
redis chart at `superset_redis_password`.

### `redis.mode: embedded` — the chart runs its own

The chart adds a `redis` service to the stack, on an overlay it creates itself. Nothing to
pre-create, no second release, and `redis.host` is ignored (the in-stack service is always
reachable as `redis`):

```yaml
redis:
  mode: embedded
  auth:
    enabled: true                         # the chart mounts superset_redis_password into
    secretName: superset_redis_password   # BOTH Superset and the Redis it starts
```

Because that overlay is stack-private — nothing outside this stack can reach the Redis — you may
also drop the password entirely, which removes `superset_redis_password` from the secrets you
pre-create in [Prerequisites](#prerequisites):

```yaml
redis:
  mode: embedded
  auth:
    enabled: false   # zero-secret; only sane BECAUSE the overlay is stack-private
```

**It is ephemeral, by design.** No volume and no node pin — that is what keeps the whole stack
stateless and schedulable anywhere. Restarting it drops every cache and any queued Celery task;
Superset re-populates the caches on demand and Celery re-queues on the next schedule, so nothing
is *lost* — but an Alert or Report that was mid-flight will not fire. If you want a Redis that
survives, that is exactly what `mode: external` + the [redis chart](../redis) is for.

Two constraints worth knowing:

- `redis.network` must **not** be a name you also use for `database.network`, `exposure.network`
  or `dataNetwork.name`. In embedded mode the chart *manages* that overlay, and sharing the name
  would turn one of your external overlays into a chart-managed one — cutting Superset off from
  its real database. The chart refuses to render instead of letting that happen. (In `external`
  mode sharing is fine, and the chart deduplicates the attachments.)
- `app`, `worker` and `beat` additionally wait for the embedded Redis before they start. `/health`
  never touches Redis, so without that gate a redeploy against an already-migrated database could
  come up "healthy" and then serve 500s out of rate-limit storage.

## Connecting to a database chart

The [postgres chart](../postgres) is the first-party metadata backend, and its **defaults are
what you want** — no version pin needed. Its e2e runs Superset 5.0.0 against `postgres:18` on
every push (see [PostgreSQL versions](#postgresql-versions) if you want the conservative pin
instead):

```yaml
# postgres release (named `postgres` here), installed FIRST. Its image bootstraps the database
# and the user, so this also covers prerequisite 2 — no manual CREATE DATABASE / CREATE USER.
auth:
  username: superset                # the superuser initdb creates — it owns the schema
  database: superset
  secretName: superset_db_password  # the SAME secret Superset reads (below)
```

```yaml
# superset release
database:
  dialect: postgresql
  host: postgres_postgres  # <postgres-release>_postgres — the stack-qualified Swarm name
  database: superset
  username: superset
  passwordSecretName: superset_db_password
  network: postgres-net  # the postgres chart's own overlay
```

Install postgres first: it **owns** `postgres-net` and creates it, while Superset only validates
it (`autoCreate: false`). Both stacks must read the same password, so the snippet points the
postgres chart at `superset_db_password` rather than creating one password under two names.

The [mariadb chart](../mariadb) can back `dialect: mysql` instead (`database.host:
mariadb_mariadb`, `database.network: mariadb-net`) — but see the warning under [Operating
notes](#operating-notes): **MariaDB is not on Superset's supported matrix.**

### PostgreSQL versions

Apache's published matrix for Superset 5.0.0 lists PostgreSQL **10–15**, and its own
`docker-compose.yml` ships `postgres:15` — which is where the "Superset needs an old Postgres"
folklore comes from. It is **documentation lag, not a ceiling**:

- Superset enforces no version check. Its metadata store is plain SQL, so compatibility is
  whatever SQLAlchemy and `psycopg2` support.
- Upstream's matrix on `master` already reads 10–16 (PostgreSQL 16 was added in
  [apache/superset#32597](https://github.com/apache/superset/pull/32597), after the 5.0 branch
  was cut), and upstream's *own* compose now runs `postgres:17` — a major their table still
  does not list.
- This chart's e2e deploys Superset 5.0.0 against `postgres:18` — migrations, login, the lot —
  on every push, which is why the section above does not pin.

If your policy is to stay strictly inside the matrix Apache publishes for 5.0.0, pin the
postgres chart to `image.tag: "15"`. That is the *only* change it needs: the chart mounts the
volume one level above `PGDATA` and derives the data directory from the tag, so the mount
contract is identical across majors. The `no-celery` e2e fixture runs that pin, so it stays
covered too.

`database.sqlalchemyUri` overrides `host`/`port`/`database`/`username` when you need more than
the convenience path — TLS, connection parameters, a different driver. The literal `{password}`
in it is replaced at runtime with the URL-quoted secret:

```yaml
database:
  sqlalchemyUri: "postgresql+psycopg2://superset:{password}@pg:5432/superset?sslmode=require"
```

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `apache/superset` | Image. Point at your derived image to bake in drivers. |
| `image.tag` | `""` | Defaults to `appVersion` (5.0.0). |
| `replicas` | `1` | Web (gunicorn) replicas. Stateless — safe to scale. |
| `python.installDrivers` | `true` | Pip-install the metadata-DB driver (+ Authlib for OIDC) at start. `false` for an image that has them. |
| `python.extraPackages` | `[]` | Extra pip requirements (e.g. analytics DB drivers). |
| `python.indexUrl` | `""` | Alternative PyPI index (private mirror). |
| `database.dialect` | `postgresql` | `postgresql` or `mysql`. |
| `database.host` / `.port` | `postgres` / `5432` | Metadata DB address on `database.network`. |
| `database.database` / `.username` | `superset` / `superset` | Must already exist. |
| `database.passwordSecretName` | `superset_db_password` | EXTERNAL secret with the DB password. |
| `database.sqlalchemyUri` | `""` | Full URI; overrides host/port/database/username. `{password}` is substituted. |
| `database.network` | `superset-db-net` | EXTERNAL overlay the DB is on. |
| `redis.mode` | `external` | `external` = you provide Redis; `embedded` = the chart runs an ephemeral one. See [Redis](#redis). |
| `redis.host` / `.port` | `redis` / `6379` | Redis address on `redis.network`. `host` is ignored when `mode: embedded`. |
| `redis.image.repository` / `.tag` | `redis` / `8.2.7` | The Redis the chart runs when `mode: embedded`. Ignored otherwise. |
| `redis.auth.enabled` | `true` | Authenticate with `redis.auth.secretName`. `false` + `mode: embedded` is the zero-secret path. |
| `redis.auth.secretName` | `superset_redis_password` | EXTERNAL secret with the Redis password. In `embedded` mode it is mounted into the Redis too. |
| `redis.network` | `redis-net` | Overlay Redis is on: EXTERNAL in `external` mode, chart-managed in `embedded` mode. |
| `redis.db.*` | `0/1/2/3` | Logical DBs: broker / results / cache / rate-limit. |
| `secretKey.secretName` | `superset_secret_key` | EXTERNAL secret with `SECRET_KEY`. Mandatory. |
| `init.enabled` | `true` | Render the one-shot migration/init service. |
| `init.loadExamples` | `false` | Load Superset's example dashboards. |
| `init.admin.*` | `admin` / … | Bootstrap admin identity; password from `init.admin.passwordSecretName`. |
| `celery.enabled` | `true` | Render the worker + beat. |
| `celery.worker.replicas` | `1` | Celery worker replicas. |
| `celery.worker.concurrency` | `2` | `CELERYD_CONCURRENCY`. |
| `celery.beat.enabled` | `true` | The scheduler. Always exactly one replica. |
| `server.workers` / `.threads` / `.timeout` / `.logLevel` | `4` / `20` / `60` / `info` | gunicorn tuning. |
| `exposure.mode` | `traefik` | `traefik`, `published` or `none`. |
| `exposure.network` | `traefik-public` | EXTERNAL ingress overlay (traefik & none modes). |
| `ingress.host` / `.tls` | `superset.example.com` / `true` | Public address; drives the Traefik rule and the secure-cookie settings. |
| `traefik.*` | see `values.yaml` | Router names, entrypoints, cert resolver, constraint label, redirect middleware. |
| `publish.port` / `.mode` | `8088` / `ingress` | published mode only. |
| `service.port` | `8088` | Container HTTP port. |
| `dataNetwork.enabled` / `.name` | `false` / `superset-data-net` | Optional EXTERNAL overlay carrying the analytics data sources Superset queries. |
| `oidc.*` | disabled | OAuth/OIDC SSO — see [Single sign-on](#single-sign-on-oidc). |
| `featureFlags` | `{}` | Superset `FEATURE_FLAGS`. |
| `config.extraPy` | `""` | Raw Python appended to `superset_config.py` (last word). |
| `extraEnv` | `{}` | Extra environment variables for every service. |
| `placement.constraints` | `[]` | Extra scheduling constraints. |
| `resources.limits.memory` / `.reservations.memory` | `""` | Per-service Swarm resources. |
| `healthcheck.*` | enabled, 180s start period | Web-app healthcheck (`/health`). |
| `labels` | `{}` | Extra deploy labels on the web app. |

## Single sign-on (OIDC)

`oidc.enabled` wires Flask-AppBuilder's `AUTH_OAUTH` to any OpenID provider — the
[keycloak chart](../keycloak), for instance:

```yaml
oidc:
  enabled: true
  serverMetadataUrl: https://keycloak.example.com/realms/eldara/.well-known/openid-configuration
  clientId: superset-client
  clientSecretSecretName: superset_oidc_client_secret
  registrationRole: Gamma
  rolesMapping:
    superset_admin: [Admin]
    superset_alpha: [Alpha]
```

> **`registrationRole` is `Gamma`, and should stay that way.** It is the role a *brand-new* SSO
> user is created with. Setting it to `Admin` — a pattern you will find in the wild — hands
> Superset Admin to **everyone who can authenticate with your IdP**, which includes reading every
> database connection Superset holds. Map your admins through `rolesMapping` (or grant your own
> account Admin once, by hand) and leave the default alone.

`rolesSyncAtLogin` re-applies `rolesMapping` on every login, so revoking a group in the IdP
revokes the Superset role too.

## Operating notes

- **`init` sits at `0/1` forever, by design.** It is a one-shot job: it runs, completes, and is
  not restarted. See the `--wait` warning under [Installing](#installing).
- **`init` re-runs on upgrade** (its spec changes with the image or the config), which is what
  you want: `superset db upgrade` is how you migrate to a new Superset version. Creating an
  already-existing admin is tolerated.
- **`beat` never scales past 1.** Two schedulers double-fire every scheduled report, so the chart
  hardcodes one replica and rolls it stop-first.
- **MariaDB is not on Superset's supported matrix** (PostgreSQL and MySQL 5.7/8 are). The
  mariadb chart *can* back `dialect: mysql`, and it works today, but you are in community
  territory: newer Superset releases have broken on MariaDB. Prefer PostgreSQL — and note this
  is a different situation from the PostgreSQL *version* numbers in that matrix, which merely
  lag reality (see [PostgreSQL versions](#postgresql-versions)); MariaDB is absent from it on
  the merits.
- **Scaling the web app** needs nothing extra — sessions are cookie-based, so no sticky sessions
  — but every replica must share the same `SECRET_KEY`, which they do by construction.
- **Alerts & Reports / thumbnails** need `celery.enabled` plus the matching entries in
  `featureFlags` (`ALERT_REPORTS`, `THUMBNAILS`).
- **Do not mount a volume over `/app/superset_home`.** Nothing needs to persist there when the
  metadata DB is external, and a bind mount would shadow the headless Chromium that the 5.0.0
  image bakes in — silently breaking Alerts & Reports.

### Rotating `SECRET_KEY`

`SECRET_KEY` signs session cookies **and encrypts the database credentials Superset stores in its
metadata database**. Replacing the secret and redeploying will therefore leave Superset unable to
decrypt its own data source passwords. Rotate properly:

1. Create the new secret and keep the old one.
2. Add both to the config — `PREVIOUS_SECRET_KEY` (the old one) alongside the new `SECRET_KEY` —
   via `config.extraPy`.
3. Run `superset re-encrypt-secrets` in an app container.
4. Drop `PREVIOUS_SECRET_KEY`.

## Security note

Every credential — `SECRET_KEY`, the database password, the Redis password, the admin password,
the OAuth client secret — is an **external Swarm secret** the operator creates. The chart never
creates one, and never takes a secret value through `values.yaml`.

Superset has no `*_FILE` convention, but its config is plain Python: the generated
`superset_config.py` calls `open('/run/secrets/…')` itself, at import time. So the passwords exist
only inside the Superset process — they are **not** in the compose file, **not** in
`docker inspect`, and **not** in the container's environment (`docker exec … env` shows nothing).
The one exception is the bootstrap admin password, which `init` passes to
`superset fab create-admin` on its argv, inside the container, for the lifetime of that one-shot
task.

The rendered stack mounts no host path, needs no Docker socket, and runs unprivileged as the
image's non-root `superset` user — which is why this chart carries no `swarmcli-charts/allow`
annotation.
