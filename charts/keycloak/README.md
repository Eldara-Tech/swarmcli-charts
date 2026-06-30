# keycloak

Keycloak 26 (Quarkus distribution) for Docker Swarm: stateless (all state in an
**external, DB-agnostic** database), authenticated via external Swarm secrets
(database + admin bootstrap), and exposed over HTTP through **Traefik** on the
`traefik-public` overlay. No volume and no node pin — Keycloak holds no local state.

The chart is database-agnostic: set `database.vendor` (and the connection fields) to
any backend Keycloak supports (`mariadb`, `mysql`, `postgres`, `mssql`, `oracle`,
`tidb`). The [MariaDB chart](../mariadb) is one valid provider, **not** a dependency.

## Prerequisites

Both overlays and both secrets are operator-supplied — the chart **validates** them
(`requirements.yaml`, `autoCreate: false`) but never creates them.

1. A reachable **database**: a running service for your chosen vendor on a shared
   overlay, with an empty schema (`database.database`) and a user
   (`database.username`) that owns it. With the [MariaDB chart](../mariadb), that is
   the `mariadb` service on a shared overlay — point `database.network` at it.

2. The two overlays. `traefik-public` is provisioned by the
   [traefik chart](../traefik); the database overlay is provisioned by the DB
   chart/operator. Its name must match `database.network`:

   ```bash
   docker network create -d overlay --attachable traefik-public      # usually already exists
   docker network create -d overlay --attachable keycloak-db-net
   ```

3. Pre-create the two password secrets (content is operator-supplied):

   ```bash
   printf 'db-pw'    | docker secret create keycloak_db_password -
   printf 'admin-pw' | docker secret create keycloak_admin_password -
   ```

## Installing

```bash
swarmcli charts install keycloak swarmcli-charts/keycloak
```

Set at least `ingress.host` (the public hostname Traefik routes and Keycloak
advertises as `KC_HOSTNAME`) and the `database` connection fields for your backend.

## How it runs behind Traefik

Keycloak is exposed via Traefik deploy labels on `traefik.network`, not a published
port. TLS is terminated at Traefik; Keycloak serves plain HTTP on `service.port`
(`KC_HTTP_ENABLED=true`) and trusts the proxy's `X-Forwarded-*` headers
(`KC_PROXY_HEADERS=xforwarded`). `KC_HOSTNAME` is derived from `ingress.host` (scheme
follows `ingress.tls`). With `ingress.tls: true` the chart renders an HTTPS router
with the cert resolver plus an HTTP→HTTPS redirect; with `tls: false` it renders an
HTTP-only router.

`mode: start` runs production mode (the default). The first boot performs an implicit
build and logs a hint to run with `--optimized` — harmless. Use `mode: start-dev`
only for local experimentation.

Healthchecks hit Keycloak's management port (`9000`, `KC_HEALTH_ENABLED=true`) at
`/health/ready`; since the image ships no curl, the probe uses a bash `/dev/tcp`
request.

> **Scaling:** `replicas` defaults to `1`. Running more than one replica needs
> Infinispan cache clustering (JGroups discovery) configured for shared sessions,
> which is out of scope for this chart.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `quay.io/keycloak/keycloak` | Image repository |
| `image.tag` | `""` | Tag — defaults to appVersion (`26.6.3`) |
| `replicas` | `1` | Replica count (raise only with cache clustering set up) |
| `mode` | `start` | `start` (production) or `start-dev` (development) |
| `database.vendor` | `mariadb` | `KC_DB` — `mariadb`/`mysql`/`postgres`/`mssql`/`oracle`/`tidb` |
| `database.host` | `mariadb` | `KC_DB_URL_HOST` (ignored when `database.url` is set) |
| `database.port` | `3306` | `KC_DB_URL_PORT` (ignored when `database.url` is set) |
| `database.database` | `keycloak` | `KC_DB_URL_DATABASE` (ignored when `database.url` is set) |
| `database.url` | `""` | Optional full `KC_DB_URL`; overrides host/port/database |
| `database.username` | `keycloak` | `KC_DB_USERNAME` |
| `database.passwordSecretName` | `keycloak_db_password` | External Swarm secret holding the DB password |
| `database.network` | `keycloak-db-net` | External overlay the database is reachable on |
| `admin.username` | `admin` | `KC_BOOTSTRAP_ADMIN_USERNAME` (first boot only) |
| `admin.passwordSecretName` | `keycloak_admin_password` | External Swarm secret holding the bootstrap admin password |
| `ingress.enabled` | `true` | Render Traefik router labels |
| `ingress.host` | `keycloak.example.com` | Public hostname (Traefik rule + `KC_HOSTNAME`) |
| `ingress.tls` | `true` | HTTPS router + redirect vs HTTP-only |
| `ingress.certResolver` | `le` | Traefik cert resolver name (match your Traefik) |
| `traefik.network` | `traefik-public` | External ingress overlay Traefik watches |
| `traefik.entrypoints.http` / `.https` | `web` / `websecure` | Traefik entrypoint names |
| `service.port` | `8080` | Container HTTP port Traefik load-balances to |
| `healthcheck.*` | see `values.yaml` | bash `/dev/tcp` probe of `/health/ready` on `:9000` |
| `placement.constraints` | `[]` | Optional scheduling constraints (unpinned by default) |
| `resources.limits.memory` | `""` | Swarm deploy memory limit |
| `labels` | `{}` | Extra deploy labels |

## Security note

Keycloak's `kc.sh` has no native `*_FILE` env support
([keycloak#10816](https://github.com/keycloak/keycloak/issues/10816)), so the chart's
entrypoint reads each password from its mounted secret file (`bash`'s `$(< file)`
builtin), exports `KC_DB_PASSWORD` / `KC_BOOTSTRAP_ADMIN_PASSWORD`, then `exec`s
`kc.sh`. The plaintext appears only inside the container process — never in the
compose file or `docker inspect`, which show only the `/run/secrets/...` path.
