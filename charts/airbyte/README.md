# airbyte

Airbyte Community Platform for Docker Swarm. This chart runs the Airbyte control
plane, worker, cron, Temporal, OAuth2 proxy and its session Redis. PostgreSQL and
S3-compatible storage are external, so the operator controls their durability and
backups: Airbyte's metadata, Temporal's workflow state and the dataplane
credentials all live in PostgreSQL. Only the session Redis keeps a node-local
volume.

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
the six secrets. `requirements.yaml` validates all of them before deployment.

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
user can migrate. Temporal keeps its state in two more databases on the same
server, `temporal` and `temporal_visibility`; it creates them itself when the user
has `CREATEDB`, otherwise create both and set `temporal.createDatabases: false`.
`storage.endpoint` must reach an S3-compatible endpoint and `storage.bucket` must
exist (or be provisioned according to your storage policy).
Set `database.host` to the database's stack-qualified Swarm service name when it
lives in another stack, for example `postgres_postgres`.

Label the one node that carries the session Redis volume before installing:

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
what its previous run left behind.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` / `.tag` | `airbyte/server` / `""` | Airbyte server image; tag defaults to `appVersion` in Chart.yaml |
| `bootloader.image.*`, `worker.image.*`, `connectorBuilderServer.image.*` | `airbyte/*` / `""` | Migration, worker, and connector-builder images; an empty tag follows `image.tag` |
| `workloadApiServer.image.*`, `workloadLauncher.image.*` | `airbyte/*` / `""` | Workload API and launcher images; an empty tag follows `image.tag` |
| `cron.image.*` | `airbyte/cron` / `""` | Cron image; an empty tag follows `image.tag` |
| `oauth2Proxy.image.*` | `quay.io/oauth2-proxy/oauth2-proxy` | OIDC reverse-proxy image and tag |
| `redis.image.*` / `temporal.image.*` | see `values.yaml` | In-stack session Redis and Temporal images |
| `temporal.createDatabases` | `true` | Let Temporal create its `temporal` and `temporal_visibility` databases (needs `CREATEDB`) |
| `fakeK8sConfigVersion` | `""` | Optional local-testing rotation key for the immutable FakeK8s config |
| `persistence.*` | see `values.yaml` | Session Redis volume and the node label that pins it |
| `database.host` / `.port` / `.name` | `postgres` / `5432` / `airbyte` | External PostgreSQL endpoint and database |
| `database.userSecretName` / `.passwordSecretName` | `airbyte_db_user` / `airbyte_db_password` | External secrets for PostgreSQL credentials |
| `database.network` | `airbyte-db-net` | External overlay PostgreSQL is reachable on |
| `storage.endpoint` / `.bucket` | `https://minio.example.com` / `airbyte-storage` | S3-compatible endpoint and bucket |
| `storage.accessKeySecretName` / `.secretKeySecretName` | `airbyte_s3_access_key` / `airbyte_s3_secret_key` | External S3 credential secrets |
| `connectorRegistry.enterpriseSourceStubsUrl` | see `values.yaml` | Connector-registry Enterprise source stubs URL |
| `flyway.configsMinimumMigrationVersion` / `.jobsMinimumMigrationVersion` | `0.35.15.001` / `0.29.15.001` | Minimum required Flyway migration for the configs and jobs databases |
| `exposure.mode` | `traefik` | `traefik`, `published`, or `none` |
| `exposure.network` / `.host` / `.tls` | `traefik-public` / `airbyte.example.com` / `true` | Ingress overlay and public address |
| `exposure.publishedPort` | `8080` | Direct OAuth2-proxy port when mode is `published` |
| `oauth2.issuerUrl` / `.clientId` | see `values.yaml` | OIDC discovery issuer and client ID |
| `oauth2.clientSecretName` / `.cookieSecretName` | see `values.yaml` | External OIDC client and cookie-encryption secrets |
| `oauth2.cookieName`, `.emailDomain`, `.trustedProxyIp`, `.scope` | see `values.yaml` | OAuth2 proxy cookie and OIDC request settings |
| `oauth2.skipJwtBearerTokens`, `.sslInsecureSkipVerify`, `.upstreamTimeout` | `true`, `false`, `300s` | OAuth2 proxy token, TLS-validation, and upstream behavior |
| `oauth2.redisNetwork` | `airbyte-oauth` | Chart-managed OAuth2 proxy/Redis overlay |
| `traefik.*` | see `values.yaml` | Traefik router settings; defaults match this repository's Traefik chart |
| `workloadLauncher.*` | see `values.yaml` | Single launcher replica, memory limits, and connector-only `extraNetworks` |
| `placement.constraints` | `[]` | Extra constraints for the Airbyte services and the session Redis |
| `labels` | `{}` | Extra deploy labels applied to the OAuth2 proxy |
