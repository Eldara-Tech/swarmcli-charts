# airbyte

Airbyte Community Platform for Docker Swarm. This chart runs the Airbyte control
plane, worker, cron, Temporal, and by default an OAuth2 proxy with its session
Redis. PostgreSQL and
S3-compatible storage are external, so the operator controls their durability and
backups: Airbyte's metadata and the dataplane credentials live in PostgreSQL.
Temporal's workflow state and the session Redis keep node-local volumes.

The chart-managed `airbyte` overlay is attachable so the workload launcher can
start connector containers through Docker and join them to the Airbyte services.
Those connector containers also join `database.network`, so the configured
`database.host` must resolve on that overlay.

When a source or destination connector must reach another in-swarm service, add
its operator-provisioned, **attachable** overlay to `workloadLauncher.extraNetworks`:

```yaml
workloadLauncher:
  extraNetworks:
    - shared-services
```

The chart validates every listed overlay before deployment and attaches each
connector workload to it through Docker. `database.network` is already included;
do not repeat it in this list.

## Prerequisites

Create the two external overlays used by the default configuration, then create
the six secrets. `requirements.yaml` validates all of them before deployment. The
two `airbyte_oauth_*` secrets are only needed with the default `auth.mode: oauth2`;
`auth.mode: airbyte` needs its own two instead (see
[Airbyte's own login](#airbytes-own-login)).

```bash
docker network create -d overlay --attachable airbyte-db-net
docker network create -d overlay --attachable traefik-public

printf 'airbyte' | docker secret create airbyte_db_user -
printf 'database-password' | docker secret create airbyte_db_password -
printf 'storage-access-key' | docker secret create airbyte_s3_access_key -
printf 'storage-secret-key' | docker secret create airbyte_s3_secret_key -
printf 'oidc-client-secret' | docker secret create airbyte_oauth_client_secret -
head -c 32 /dev/urandom | docker secret create airbyte_oauth_cookie_secret -
```

The database must already contain an empty `airbyte` database which the secret
user can migrate.
`storage.endpoint` must reach an S3-compatible endpoint and `storage.bucket` must
exist (or be provisioned according to your storage policy).
Set `database.host` to the database's stack-qualified Swarm service name when it
lives in another stack, for example `postgres_postgres`.

Label the one node that carries the session Redis and Temporal volumes before installing:

```bash
docker node update --label-add airbyte-data=true <node>
```

## Installing

Create an override for your database, object storage, OIDC issuer, and public
hostname. Secret values always stay in Swarm secrets, never in this file.

```yaml
# airbyte-values.yaml
database:
  host: postgres_postgres
storage:
  endpoint: https://minio.example.com
exposure:
  host: airbyte.example.com
oauth2:
  issuerUrl: https://keycloak.example.com/realms/airbyte
```

```bash
swarmcli charts install airbyte swarmcli-charts/airbyte -f airbyte-values.yaml
```

## Exposure

`exposure.mode: traefik` is the default. It routes the OAuth2 proxy through the
shared `exposure.network` using the labels expected by this repository's Traefik
chart. `published` exposes the proxy on `exposure.publishedPort`; `none` joins
the external network without adding Traefik labels so another proxy can reach it.

The OAuth2 callback is `https://<exposure.host>/oauth2/callback` (`http://` when
`exposure.tls` is false). Register that exact redirect URI with the OIDC
provider, and set `oauth2.clientId` and `oauth2.issuerUrl` to match the
provider. The client and cookie secret names are always real external secret
names. OAuth2 Proxy reads them directly from their mounted files; the cookie
secret must be exactly 16, 24, or 32 raw bytes.

## Airbyte's own login

`auth.mode: airbyte` drops oauth2-proxy and turns on Airbyte's email/password
login, as `global.auth.enabled` does in Airbyte's Helm chart. The first visitor
sees Airbyte's setup screen and chooses the login email there, so open the
instance yourself right after installing. The password comes from a Swarm
secret, and every Airbyte service signs and checks its tokens with a shared
secret of at least 32 random characters:

```bash
printf 'admin-password' | docker secret create airbyte_admin_password -
head -c 32 /dev/urandom | base64 | docker secret create airbyte_jwt_signature_secret -
```

It works in every exposure mode. With `exposure.mode: published` the server
itself owns the port, and the Connector Builder UI then needs a proxy in front
that routes `/api/v1/connector_builder/` to
`<release>_connector-builder-server:8080`, because the UI calls it on the same
origin. The login cookies are `Secure` only when `exposure.tls` is true.

Airbyte keeps the setup endpoint (`/api/v1/instance_configuration/setup`) open to
anonymous callers even after setup, and it replaces the login email. Once you
have completed the setup screen, set `auth.airbyte.setupComplete: true` and
upgrade: in traefik mode the chart then refuses that path with a 403. A
published port cannot be protected this way, so keep it on a trusted network.

## Without OAuth

`auth.mode: none` drops oauth2-proxy and its Redis and routes the server directly,
with a second router for the connector builder's `/api/v1/connector_builder/`
path. Airbyte then logs nobody in, and it runs any connector image it is given
next to your database, so the chart refuses to render unless something else
authenticates:

- `exposure.mode: traefik` requires `traefik.basicAuthUsers`, a basic-auth
  middleware on both routers. Generate the entry with
  `htpasswd -nbB <user> <password>` and **double every `$`**, because Compose
  eats single ones.
- `exposure.mode: none` joins the server and the connector builder to
  `exposure.network` for your own proxy, which must authenticate and route
  `/api/v1/connector_builder/` to `<release>_connector-builder-server:8080` and
  everything else to `<release>_server:8001`.
- `exposure.mode: published` is refused.

```yaml
auth:
  mode: none
traefik:
  basicAuthUsers: "ops:$$2y$$05$$Q3Z…"
```

## Workload Launcher Security

Airbyte launches connector workloads dynamically. The workload launcher
therefore mounts `/var/run/docker.sock`, which grants effective control of the
Docker daemon on its scheduled node, and starts every connector container on that
node. The connector containers get only their own emptyDir volumes, never the
socket. The chart declares this explicitly in `Chart.yaml` for the repository
security scanner. Keep the launcher on a dedicated, trusted node with
`placement.constraints`; do not relax its access controls.

The launcher translates Airbyte's Kubernetes calls into Docker ones with a small
shim, `files/FakeK8s.java`. It keeps the Secret Airbyte's bootloader writes (the
dataplane credentials) in a `fakek8s_secrets` table in the Airbyte database, and
labels every container and volume it creates, so a restarted launcher removes
what its previous run left behind. Connector containers get the memory and CPU
limits Airbyte sets on the pod (without swap, as on Kubernetes).

## Private connector registries

Connector images from a private registry need credentials, and Docker's pull API does
not read the node's `docker login`. Put a Docker `config.json` in a Swarm secret and
name it in `workloadLauncher.registryAuthSecretName`; FakeK8s sends the matching
`auths` entry with each pull. Entries need an inline `auth` (base64 `user:password`),
so write the file by hand or take it from a login without a credential helper:

```bash
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'user:token' | base64)" \
  | docker secret create airbyte_registry_auth -
```

An image already on the launcher's node is used as it is. A pull is abandoned
after 30 minutes, and a pod whose image is still missing then fails. Kubernetes
`imagePullSecrets` in Airbyte's configuration are ignored.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` / `.tag` | `airbyte/server` / `""` | Airbyte server image; tag defaults to `appVersion` in Chart.yaml |
| `bootloader.image.*`, `worker.image.*`, `connectorBuilderServer.image.*` | `airbyte/*` / `""` | Migration, worker, and connector-builder images; an empty tag follows `image.tag` |
| `workloadApiServer.image.*`, `workloadLauncher.image.*` | `airbyte/*` / `""` | Workload API and launcher images; an empty tag follows `image.tag` |
| `cron.image.*` | `airbyte/cron` / `""` | Cron image; an empty tag follows `image.tag` |
| `oauth2Proxy.image.*` | `quay.io/oauth2-proxy/oauth2-proxy` | OIDC reverse-proxy image and tag |
| `redis.image.*` / `temporal.image.*` | see `values.yaml` | In-stack session Redis and Temporal images |
| `fakeK8sConfigVersion` | `""` | Optional local-testing rotation key for the immutable FakeK8s config |
| `persistence.*` | see `values.yaml` | Session Redis and Temporal volumes and the node label that pins them |
| `database.host` / `.port` / `.name` | `postgres` / `5432` / `airbyte` | External PostgreSQL endpoint and database |
| `database.userSecretName` / `.passwordSecretName` | `airbyte_db_user` / `airbyte_db_password` | External secrets for PostgreSQL credentials |
| `database.network` | `airbyte-db-net` | External overlay PostgreSQL is reachable on |
| `storage.endpoint` / `.bucket` | `https://minio.example.com` / `airbyte-storage` | S3-compatible endpoint and bucket |
| `storage.accessKeySecretName` / `.secretKeySecretName` | `airbyte_s3_access_key` / `airbyte_s3_secret_key` | External S3 credential secrets |
| `connectorRegistry.enterpriseSourceStubsUrl` | see `values.yaml` | Connector-registry Enterprise source stubs URL |
| `flyway.configsMinimumMigrationVersion` / `.jobsMinimumMigrationVersion` | `0.35.15.001` / `0.29.15.001` | Minimum required Flyway migration for the configs and jobs databases |
| `auth.mode` | `oauth2` | `oauth2` (oauth2-proxy in front), `airbyte` (see [Airbyte's own login](#airbytes-own-login)) or `none` (see [Without OAuth](#without-oauth)) |
| `auth.airbyte.passwordSecretName` / `.jwtSecretName` | `airbyte_admin_password` / `airbyte_jwt_signature_secret` | External secrets for `auth.mode: airbyte`: the admin password and the JWT signing secret |
| `auth.airbyte.setupComplete` | `false` | After the setup screen is done: refuse Airbyte's anonymous setup endpoint at Traefik |
| `exposure.mode` | `traefik` | `traefik`, `published`, or `none` |
| `exposure.network` / `.host` / `.tls` | `traefik-public` / `airbyte.example.com` / `true` | Ingress overlay and public address |
| `exposure.publishedPort` | `8080` | Direct port of the entry service (OAuth2 proxy or server) when mode is `published` |
| `traefik.basicAuthUsers` | `""` | htpasswd users for a basic-auth middleware on the public routers; required with `auth.mode: none` in traefik mode |
| `oauth2.issuerUrl` / `.clientId` | see `values.yaml` | OIDC discovery issuer and client ID |
| `oauth2.clientSecretName` / `.cookieSecretName` | see `values.yaml` | External OIDC client and cookie-encryption secrets |
| `oauth2.cookieName`, `.emailDomain`, `.trustedProxyIp`, `.scope` | see `values.yaml` | OAuth2 proxy cookie and OIDC request settings |
| `oauth2.skipJwtBearerTokens`, `.sslInsecureSkipVerify`, `.upstreamTimeout` | `true`, `false`, `300s` | OAuth2 proxy token, TLS-validation, and upstream behavior |
| `oauth2.redisNetwork` | `airbyte-oauth` | Chart-managed OAuth2 proxy/Redis overlay |
| `traefik.*` | see `values.yaml` | Traefik router settings; defaults match this repository's Traefik chart |
| `workloadLauncher.*` | see `values.yaml` | Single launcher replica, memory limits, and connector-only `extraNetworks` |
| `workloadLauncher.registryAuthSecretName` | `""` | External secret with a Docker `config.json` for private connector registries |
| `placement.constraints` | `[]` | Extra constraints for the Airbyte services and the session Redis |
| `labels` | `{}` | Extra deploy labels for the entry service: the OAuth2 proxy, or the server when `auth.mode` is not `oauth2` |
