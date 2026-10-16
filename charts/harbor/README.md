# harbor

[Harbor](https://goharbor.io), the container registry with projects, RBAC, replication,
retention and vulnerability scanning, for Docker Swarm. The chart is shaped like Harbor's
own docker-compose installer rather than its Helm chart, with the parts that installer
generates on the host (secrets, config files, ownership) moved to Swarm secrets, configs
and a start-up wrapper:

| Service | Role |
|---------|------|
| `nginx` | The only exposed service: Harbor's own front proxy, routing `/api/`, `/service/`, `/v2/` and `/c/` to core and everything else to portal, with no body limit and no buffering |
| `core` | API, token service, OIDC login, and the `/v2/` proxy in front of the registry |
| `portal` | The web UI |
| `jobservice` | Replication, garbage collection, retention, scans and webhooks |
| `registry`, `registryctl` | The distribution registry and the controller Harbor deletes blobs through |
| `valkey` | Sessions, caches and the job queue, on the stack's own overlay only |
| `trivy` | The vulnerability scanner (`trivy.enabled`, on by default) |
| `exporter` | Project, quota and job-queue metrics (`metrics.enabled` only) |

PostgreSQL is **external**: the [postgres chart](../postgres) or any PostgreSQL that core and jobservice
can reach on `database.network`.

Harbor publishes **linux/amd64 images only**, so every service needs an amd64 node; Swarm
schedules them there by itself, from the images' platform.

## Prerequisites

**A database and its owner.** Harbor creates its tables on first start. With the postgres
chart (installed as `postgres`, overlay `postgres-net`), add a role and a database for it:

```bash
printf '%s' 'S3cr3t-db' | docker secret create harbor-db-password -
docker exec -it "$(docker ps -q -f label=com.docker.swarm.service.name=postgres_postgres)" \
  psql -U postgres -c "CREATE ROLE harbor LOGIN PASSWORD 'S3cr3t-db'" -c "CREATE DATABASE harbor OWNER harbor"
```

**Harbor's secrets**, all external Swarm secrets created once. The two with a fixed length
are checked at start, and core refuses to start if either is wrong:

```bash
printf '%s' 'Ch4nge-me-now' | docker secret create harbor-admin-password -
openssl rand -hex 8  | tr -d '\n' | docker secret create harbor-core-secret -
openssl rand -hex 8  | tr -d '\n' | docker secret create harbor-jobservice-secret -
openssl rand -hex 8  | tr -d '\n' | docker secret create harbor-registry-http-secret -
openssl rand -hex 16 | tr -d '\n' | docker secret create harbor-csrf-key -     # exactly 32 characters
openssl rand -hex 8  | tr -d '\n' | docker secret create harbor-secret-key -   # exactly 16 bytes, never rotate
openssl genrsa -traditional 4096 | docker secret create harbor-token-key -   # LibreSSL (macOS): no -traditional

# How core and jobservice log in to the registry: a password, and its bcrypt htpasswd line.
pw="$(openssl rand -hex 16)"
printf '%s' "$pw" | docker secret create harbor-registry-password -
docker run --rm httpd:2.4-alpine htpasswd -nbB harbor_registry_user "$pw" | sed -n 1p \
  | docker secret create harbor-registry-htpasswd -
unset pw
```

`harbor-secret-key` encrypts the secrets Harbor keeps in the database (OIDC users' CLI
secrets and tokens, replication credentials), so replacing it locks Harbor out of them.
`harbor-token-key` must be PKCS#1 (`BEGIN RSA PRIVATE KEY`): Harbor signs registry tokens
with a library that reads no other format, so OpenSSL 3's default PKCS#8 would fail every
`docker login` with a 500 while every health check stays green. Core refuses to start with
one. The admin password is applied only while `admin` has none: change it in the UI after
the first login, and Harbor ignores the secret from then on (core still needs it to exist).

**The data node.** The registry's layers and Valkey's data live on one node:

```bash
docker node update --label-add harbor-data=true <node>   # or persistence.nodeLabel="" on a single node
```

## Installing

If `swarmcli charts repo list` does not show `swarmcli-charts`, add it first:
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.

```bash
swarmcli charts install harbor swarmcli-charts/harbor --set ingress.host=registry.example.com
```

Log in at `https://registry.example.com` as `admin`, then from a client:
`docker login registry.example.com`.

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret and network the release references.
A default install needs:

```yaml
- name: harbor
  source: { ... }
  allow:
    secrets:  [harbor-db-password, harbor-admin-password, harbor-core-secret,
               harbor-jobservice-secret, harbor-registry-http-secret, harbor-csrf-key,
               harbor-secret-key, harbor-token-key, harbor-registry-password,
               harbor-registry-htpasswd]
    networks: [postgres-net, traefik-public]
```

Add `monitoring` with `metrics.enabled`, `harbor-oidc-client-secret` with `oidc.enabled`,
`harbor-s3-access-key`, `harbor-s3-secret-key` and `storage.s3.network` with
`storage.type: s3`, and the paths to `hostPaths` when you set `persistence.registryPath` or
`persistence.valkeyPath`. Each entry is the name itself, so an override in values needs the
same change here.

## Exposure

nginx is the only service routed or published; core, portal and the rest sit behind it on
the stack's own overlay, and core and jobservice also on `database.network`. The components
reach each other by the stack's full service names (`<release>_core`), never the short
ones, which are aliases on every overlay a service joins.

| Mode | What it does |
|------|--------------|
| `traefik` (default) | Traefik labels on nginx routing `ingress.host`, with an HTTPS router and ACME certificate when `ingress.tls` |
| `published` | nginx's port 8080 published on the Swarm as `publish.port` |
| `none` | nothing exposed; nginx joins `exposure.network`, where your own proxy reaches it as `<release>_nginx:8080` |

**`externalURL` is the address everything is built from**: the token realm `docker login`
follows, the push URLs and the OIDC callback. In `traefik` mode it is derived from
`ingress.host` and `ingress.tls`; `published` and `none` must set it, with the port when it
is not the scheme's default (`http://registry.lan:8080`). A proxy in front must pass the
`Host` header unchanged and set `X-Forwarded-Proto`.

docker clients refuse a registry on plain HTTP unless it is listed in their daemon's
`insecure-registries` (loopback addresses excepted), so run it behind TLS.

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository
(entrypoints `http`/`https`, resolver `le`, constraint label `traefik-public`, redirect
middleware `https-redirect`); override them for your own Traefik. Traefik's entrypoints
time out slow requests (v3's default `readTimeout` is 60s), which a large layer push
over a slow link can exceed; raise it on the edge if pushes fail part-way.

## Storage

`storage.type: filesystem` (default) keeps layers under `/storage` on the
`harbor-registry` volume, shared by the registry and registryctl on the data node.
`storage.type: s3` puts them in a bucket instead: AWS, or an S3-compatible store through
`storage.s3.endpoint`, which also switches to the path-style addressing those stores
expect. With the [rustfs chart](../rustfs) installed as `s3`:

```yaml
storage:
  type: s3
  s3:
    endpoint: http://s3-rustfs:9000
    bucket: harbor             # must exist; create it with the rustfs chart's buckets value
    network: rustfs-net        # joined by the registry and registryctl only
```

with the store's key pair in `harbor-s3-access-key` and `harbor-s3-secret-key`.
`storage.s3.disableRedirect` (true) serves every layer through Harbor; false sends docker
clients to a presigned URL on the endpoint, which they must then be able to reach.

## Single sign-on

With `oidc.enabled`, people log in through an OpenID Connect provider and `docker login`
with their username and the **CLI secret** from their Harbor user profile. `admin` keeps
its local password.

Harbor reads its OIDC settings at start from `CONFIG_OVERWRITE_JSON`, which the chart
builds from `oidc.*` and `config` (the client secret is spliced in inside the container).
Two upstream behaviours come with it:

- **Every system setting becomes read-only in the UI**, not only the OIDC ones, for as long
  as the variable is set. Put further settings in `config`, keyed as in Harbor's
  configuration API, e.g. `config.project_creation_restriction: adminonly`.
- **Harbor switches the auth mode only while no user other than `admin` exists.** Turn OIDC
  on at install, or before anyone else has logged in; otherwise core refuses the setting
  and stops at start (`the auth mode cannot be modified as new users have been inserted
  into database` in `docker service logs <release>_core`). Turning `oidc.enabled` off does
  not switch Harbor back: the last applied settings stay, and become editable in the UI again.

With [Keycloak](../keycloak), in your realm:

1. Create an OpenID Connect client, e.g. `harbor`, with **Client authentication** on and
   **Standard flow** on.
2. Set **Valid redirect URIs** to `https://registry.example.com/c/oidc/callback`
   (`externalURL` followed by `/c/oidc/callback`).
3. Put the client secret (**Credentials** tab) in a Swarm secret:
   `printf '%s' '<client secret>' | docker secret create harbor-oidc-client-secret -`
4. For group-based access, add a **Group Membership** mapper with token claim name
   `groups` and **Full group path** off.

```yaml
oidc:
  enabled: true
  name: Keycloak
  endpoint: https://keycloak.example.com/realms/main
  clientId: harbor
  userClaim: preferred_username   # the username, instead of asking at first login
  autoOnboard: true
  adminGroup: harbor-admins       # members become Harbor admins
```

`offline_access` stays in `oidc.scope` so a CLI secret keeps working after the ID token
expires.

## Vulnerability scanning

Trivy downloads its database from `mirror.gcr.io` / `ghcr.io` on the first scan and keeps
it in the container, so a replaced task downloads it again. Without outbound access, turn
the scanner off with `trivy.enabled: false`. `trivy.offlineScan` stops network lookups
during a scan (Maven Central for Java artifacts) but still downloads the database.

## Persistence & node pinning

While `persistence.enabled`, the registry and registryctl (with filesystem storage) and
Valkey are pinned to the node labelled `harbor-data=true`, on the `harbor-registry` and
`harbor-valkey` volumes. Valkey holds sessions, caches and the job queue, so losing it logs
everyone out and drops queued jobs, but no images. `persistence.registryPath` and
`persistence.valkeyPath` bind-mount host directories instead; they must exist on that node.
The registry takes ownership of its directory at start (its wrapper runs as root,
`chown`s the storage root to uid 10000 and runs the registry as that uid through `su`, which
stays behind as a root parent); the Valkey one must be writable by uid 999:

```bash
install -d -o 999 -g 999 -m 0700 /srv/harbor/valkey
install -d -m 0755 /srv/harbor/registry
```

With `persistence.enabled: false` nothing is kept: every image is lost when the registry
task is replaced, and registryctl, which then has storage of its own, cannot delete blobs
during garbage collection. It is for trying the chart out.

## Metrics

`metrics.enabled: true` turns on Harbor's own Prometheus metrics and adds one service:

| Service | Port | What it serves |
|---------|------|----------------|
| `core` | 8001 | `harbor_core_*`: API requests by operation and status code, latency, in-flight requests |
| `jobservice` | 8001 | `harbor_jobservice_*`: tasks processed by type and outcome |
| `registry` | 8001 | `registry_*`: HTTP requests by handler, storage driver latency, cache |
| `exporter` ([harbor-exporter](https://goharbor.io/docs/main/administration/metrics/)) | 8001 | `harbor_up`/`harbor_health` from Harbor's health API, projects, quotas, the job queue |

Each carries the deploy labels `prometheus.io/scrape=true` and `prometheus.io/port=8001` and joins
the `monitoring` overlay, which is where the prometheus-stack chart scrapes by default — so
Prometheus finds all four by itself, with no scrape config. The exporter also joins
`database.network`: it reads project and quota figures from Harbor's database with Harbor's own
database user, and the job queue from Valkey.

```bash
swarmcli charts upgrade harbor swarmcli-charts/harbor -f harbor-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`. That flag
merges over the previous release's stored values *instead of* this chart version's defaults, so
every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

The metrics are Harbor's own, so turning them on changes the configuration of core, jobservice,
the registry and registryctl (which shares the registry's configuration): all four restart once.

- **What joins `monitoring`, and what else it can reach there.** core, jobservice, the registry
  and the exporter, on every port they listen on, not just 8001:
  - core's API on 8080, reached without nginx, so also `/service/notifications`, which nginx
    answers 404: jobservice's unauthenticated status hooks, which need a job's random id to
    do anything;
  - jobservice's API on 8080, which requires the shared jobservice secret for everything but
    `/api/v1/stats` (its worker pools);
  - the registry on 5000, behind the htpasswd login core uses;
  - the registry's debug listener on 8001, which serves `/debug/pprof/` (profiles, goroutine
    dumps, CPU-costly traces on demand) and `/debug/vars` beside `/metrics`, unauthenticated —
    distribution's documentation warns it can expose sensitive information;
  - the exporter's `/metrics` and an HTML index page.
  Core's and jobservice's 8001 listeners serve `/metrics` only. nginx, portal, registryctl,
  Valkey and Trivy stay off `monitoring`; Valkey, which has no password, never leaves the
  stack's own overlay.
- `metrics.network` must be an overlay of its own: the render fails when it shares a name with
  `database.network`, `exposure.network` or `storage.s3.network`.
- **Turning it off** leaves the exporter service running, because swarmcli deploys without
  `--prune`. Remove it yourself: `docker service rm <release>_exporter`.
- **swarmcli-cd** additionally needs `monitoring` in `allow.networks`.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) for your Prometheus and Grafana,
and deploys neither: scraping is automatic, but which rules and dashboards a monitoring
stack loads is its operator's choice. With the prometheus-stack chart they go in
through its own configuration:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/harbor/monitoring
curl -fsSL -O "$base/harbor-rules.yml" -O "$base/harbor-dashboard.json"
v="$(swarmcli charts status mon | sed -n 's/^CHART: prometheus-stack-//p')"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --version "${v:?}" --reuse-values \
  --set-file prometheus.extraRules.harbor=./harbor-rules.yml \
  --set-file grafana.dashboards.harbor=./harbor-dashboard.json
```

`--version` keeps prometheus-stack at the version it runs, the only case in which `--reuse-values`
is safe (Eldara-Tech/swarmcli#687).

A release file and swarmcli-cd take values files only, not `--set-file`, so there both
files go in as values files: each file's content, as it is, indented under its key as a
block string. From the two files downloaded above:

```bash
mkdir -p monitoring/rules monitoring/dashboards
{ printf 'prometheus:\n  extraRules:\n    harbor: |\n'; sed 's/^./      &/' harbor-rules.yml; } > monitoring/rules/harbor.yaml
{ printf 'grafana:\n  dashboards:\n    harbor: |\n'; sed 's/^./      &/' harbor-dashboard.json; } > monitoring/dashboards/harbor.yaml
```

The dashboard stays JSON: converted to YAML it becomes a mapping, which the render
refuses (`got object, want string`). prometheus-stack's README, *Keeping your setup in
git*, shows where to list the two files.

- **Alerts** (`harbor-rules.yml`): Harbor ships none, so these are this chart's.
  `HarborCoreUnreachable` (the exporter cannot reach core's health API), `HarborComponentDown`
  (core, portal, registry, database or Valkey reported down by Harbor's health API) and
  `HarborCoreServerErrors` / `HarborRegistryServerErrors` (over 5% 5xx for 10 minutes) are
  critical. `HarborComponentDegraded` (jobservice, registryctl or Trivy down: background jobs and
  scans stop, pushes and pulls work), `HarborJobQueueStalled` (a job type's oldest job waiting
  over an hour) and `HarborProjectQuotaNearlyFull` (a project over 90% of its quota; at 100%
  Harbor refuses pushes to it) warn. A component Prometheus cannot scrape at all is
  prometheus-stack's `TargetDown`.
- **Dashboard** (`harbor-dashboard.json`, uid `harbor`), derived from Harbor's
  [contrib/grafana-dashboard](https://github.com/goharbor/harbor/tree/main/contrib/grafana-dashboard)
  (Apache-2.0): overall and per-component health, projects, repositories, storage and quotas;
  core requests, status codes and latency; the job queue, task throughput and concurrency;
  registry requests, latency and storage-driver timings; memory, CPU, goroutines and open files
  per component. Pick a release by its `stack`.

The dashboard picks a release by the `stack` label prometheus-stack's discovery puts on every
target, and the alerts carry it. Another Prometheus needs the same relabelling of
`__meta_dockerswarm_service_label_com_docker_stack_namespace` to `stack`.

## Upgrading

Core migrates the database at every start, with no way back to an older Harbor, so back up
the database before an upgrade that changes `appVersion`. Keep the same values across
upgrades with `-f` rather than `--reuse-values`, which replaces a new chart version's
defaults with the old release's values, so every key it adds renders `<no value>`
(Eldara-Tech/swarmcli#687).

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `goharbor/harbor-core` | Core image; the other components follow its tag |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `portal.image`, `jobservice.image`, `registry.image`, `registryctl.image`, `nginx.image`, `valkey.image`, `trivy.image`, `metrics.exporter.image` | `goharbor/…`, tag `""` | The other components; an empty tag follows `image.tag` |
| `jobservice.workers` | `10` | Concurrent job workers |
| `trivy.enabled` | `true` | Run the vulnerability scanner |
| `trivy.offlineScan` | `false` | No network lookups during a scan |
| `trivy.ignoreUnfixed` | `false` | Report only vulnerabilities with a fix |
| `trivy.timeout` | `5m0s` | Scan timeout |
| `exposure.mode` | `traefik` | `traefik`, `published` or `none` |
| `exposure.network` | `traefik-public` | Edge overlay nginx joins in `traefik` and `none` modes |
| `ingress.host` | `harbor.example.com` | Public host (`traefik` mode) |
| `ingress.tls` | `true` | HTTPS router with an ACME certificate |
| `traefik.*` | in-repo traefik chart | `certResolver`, `entrypoints.http/https`, `routerName`, `constraintLabel`, `redirectMiddleware` |
| `publish.port` / `publish.mode` | `8080` / `ingress` | Published port (`published` mode) |
| `externalURL` | `""` | The URL clients use; required in `published` and `none` modes |
| `database.host` / `port` / `name` / `username` | `postgres_postgres` / `5432` / `harbor` / `harbor` | External PostgreSQL |
| `database.passwordSecret` | `harbor-db-password` | Swarm secret with its password |
| `database.sslmode` | `disable` | `disable`, `require`, `verify-ca` or `verify-full` |
| `database.network` | `postgres-net` | Overlay PostgreSQL is reachable on |
| `database.maxIdleConns` / `maxOpenConns` | `10` / `40` | Connection pool of core and, separately, of jobservice |
| `admin.passwordSecret` | `harbor-admin-password` | Initial admin password |
| `secrets.*` | `harbor-…` | `core`, `jobservice`, `registryHttp`, `csrfKey`, `secretKey`, `tokenKey`, `registryPassword`, `registryHtpasswd` (see Prerequisites) |
| `storage.type` | `filesystem` | `filesystem` or `s3` |
| `storage.s3.endpoint` | `""` | S3 endpoint URL; `""` is AWS |
| `storage.s3.region` / `bucket` / `rootDirectory` | `us-east-1` / `harbor` / `""` | Bucket and key prefix |
| `storage.s3.accessKeySecret` / `secretKeySecret` | `harbor-s3-access-key` / `harbor-s3-secret-key` | Swarm secrets with the key pair |
| `storage.s3.disableRedirect` | `true` | Serve layers through Harbor rather than presigned URLs |
| `storage.s3.network` | `""` | Overlay to join to reach the endpoint |
| `persistence.enabled` | `true` | Volumes for the registry and Valkey, pinned to the data node |
| `persistence.registryVolume` / `valkeyVolume` | `harbor-registry` / `harbor-valkey` | Named volumes |
| `persistence.registryPath` / `valkeyPath` | `""` | Host directories instead (host-mount) |
| `persistence.nodeLabel` | `harbor-data` | Node label of the data node; `""` drops the pin |
| `placement.constraints` | `[]` | Extra constraints for every service |
| `oidc.enabled` | `false` | Single sign-on (makes every setting read-only in the UI) |
| `oidc.name` / `endpoint` / `clientId` | `OIDC` / `""` / `harbor` | Button label, issuer URL, client id |
| `oidc.clientSecretSecret` | `harbor-oidc-client-secret` | Swarm secret with the client secret |
| `oidc.scope` | `openid,profile,email,offline_access` | Requested scopes |
| `oidc.userClaim` / `autoOnboard` | `""` / `false` | Username claim; create users without asking |
| `oidc.groupsClaim` / `adminGroup` / `groupFilter` | `groups` / `""` / `""` | Group claim, admin group, group regex |
| `oidc.verifyCert` / `logout` | `true` / `false` | Verify the provider's certificate; log out of it too |
| `config` | `{}` | Further system settings through `CONFIG_OVERWRITE_JSON` |
| `metrics.enabled` | `false` | Prometheus metrics and the exporter |
| `metrics.network` | `monitoring` | Overlay shared with Prometheus |
| `labels` | `{}` | Extra deploy labels on nginx |
| `healthcheck.*` | on, `30s`/`10s`/`5`, start `300s`, monitor `8m` | Healthchecks and the rollout window |
