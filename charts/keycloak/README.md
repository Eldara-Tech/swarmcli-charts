# keycloak

Keycloak 26 (Quarkus distribution) for Docker Swarm: stateless (all state in an
**external, DB-agnostic** database) and authenticated via external Swarm secrets
(database + admin bootstrap). No volume and no node pin — Keycloak holds no local
state. Exposure is **pluggable** — front it with Traefik (default), publish a port
directly (optionally with Keycloak-terminated TLS), or expose nothing and attach your
own reverse proxy.

The chart is database-agnostic: set `database.vendor` (and the connection fields) to
any backend Keycloak supports (`mariadb`, `mysql`, `postgres`, `mssql`, `oracle`,
`tidb`). The [MariaDB chart](../mariadb) is one valid provider, **not** a dependency.

## Prerequisites

The external overlays and secrets are operator-supplied — the chart **validates**
them (`requirements.yaml`, `autoCreate: false`) but never creates them.

1. A reachable **database**: a running service for your chosen vendor on a shared
   overlay, with an empty schema (`database.database`) and a user
   (`database.username`) that owns it. With the [MariaDB chart](../mariadb), that is
   the `mariadb` service on a shared overlay — point `database.network` at it.

2. Networks — the **database overlay** (always), plus the **`exposure.network`**
   overlay in `traefik`/`none` modes. `traefik-public` is provisioned by the
   [traefik chart](../traefik); the database overlay by the DB chart/operator (its
   name must match `database.network`):

   ```bash
   docker network create -d overlay --attachable traefik-public      # traefik / none modes
   docker network create -d overlay --attachable keycloak-db-net
   ```

3. The two password secrets (always), plus the **TLS cert/key** secrets only when
   `exposure.mode=published` and `publish.tls.enabled`:

   ```bash
   printf 'db-pw'    | docker secret create keycloak_db_password -
   printf 'admin-pw' | docker secret create keycloak_admin_password -
   # published + Keycloak-terminated TLS only:
   docker secret create keycloak_tls_cert fullchain.pem
   docker secret create keycloak_tls_key  privkey.pem
   ```

## Installing

```bash
swarmcli charts install keycloak swarmcli-charts/keycloak
```

Set at least `ingress.host` (the public hostname, advertised as `KC_HOSTNAME`) and
the `database` connection fields for your backend.

`mode: start` runs production mode (the default). The first boot performs an implicit
build and logs a hint to run with `--optimized` — harmless. Use `mode: start-dev`
only for local experimentation.

Healthchecks hit Keycloak's management port (`9000`, `KC_HEALTH_ENABLED=true`) at
`/health/ready`; since the image ships no curl, the probe uses a bash `/dev/tcp`
request.

> **Scaling:** `replicas` defaults to `1`. Running more than one replica needs
> Infinispan cache clustering (JGroups discovery) configured for shared sessions,
> which is out of scope for this chart.

## Exposure modes

`exposure.mode` selects how clients reach Keycloak. `KC_HOSTNAME` is derived from
`ingress.host`; its scheme follows `ingress.tls` (traefik/none) or
`publish.tls.enabled` (published).

- **`traefik`** (default) — exposed via Traefik deploy labels on `exposure.network`,
  no published port. TLS is terminated at Traefik; Keycloak serves plain HTTP on
  `service.port` (`KC_HTTP_ENABLED=true`) and trusts `X-Forwarded-*`
  (`KC_PROXY_HEADERS=xforwarded`). `ingress.tls: true` renders an HTTPS router with
  `traefik.certResolver` plus an HTTP→HTTPS redirect; `false` renders an HTTP-only
  router.
- **`published`** — publish a port on the Swarm with no proxy. Plain HTTP on
  `publish.port` by default. With `publish.tls.enabled` Keycloak terminates TLS from
  the mounted `publish.tls.certSecretName`/`keySecretName` (PEM) on `8443`
  (`KC_HTTPS_CERTIFICATE_FILE`/`_KEY_FILE`); the management port stays on plain HTTP
  (`KC_HTTP_MANAGEMENT_SCHEME=http`) so the healthcheck keeps working. **You supply
  and renew the certificate** — there is no ACME here.
- **`none`** — no published port and no Traefik labels. Keycloak sits on
  `exposure.network` (so your own proxy joined to that overlay can reach
  `keycloak:8080`) and trusts `X-Forwarded-*`, like the traefik case.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `quay.io/keycloak/keycloak` | Image repository |
| `image.tag` | `""` | Tag — defaults to appVersion (`26.6.3`) |
| `replicas` | `1` | Replica count (raise only with cache clustering set up) |
| `mode` | `start` | kc.sh mode: `start` (production) or `start-dev` (development) |
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
| `exposure.mode` | `traefik` | `traefik` / `published` / `none` (see above) |
| `exposure.network` | `traefik-public` | Shared external overlay (traefik & none modes) |
| `ingress.host` | `keycloak.example.com` | Public hostname (`KC_HOSTNAME` + Traefik rule) |
| `ingress.tls` | `true` | Public endpoint is HTTPS (traefik & none scheme; traefik router) |
| `traefik.certResolver` | `le` | Traefik cert resolver name (match your Traefik) |
| `traefik.entrypoints.http` / `.https` | `web` / `websecure` | Traefik entrypoint names |
| `publish.port` | `8080` | Published port (set `8443` for `publish.tls.enabled`) |
| `publish.mode` | `ingress` | Swarm port mode: `ingress` (routing mesh) or `host` |
| `publish.tls.enabled` | `false` | Keycloak terminates TLS from the cert/key secrets |
| `publish.tls.certSecretName` | `keycloak_tls_cert` | External Swarm secret — PEM certificate |
| `publish.tls.keySecretName` | `keycloak_tls_key` | External Swarm secret — PEM private key |
| `service.port` | `8080` | Container HTTP port (Traefik LB / own-proxy upstream target) |
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
compose file or `docker inspect`, which show only the `/run/secrets/...` path. (The
TLS cert/key are ordinary file paths Keycloak reads natively, so `KC_HTTPS_*_FILE`
point straight at the mounted secrets.)
