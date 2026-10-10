# rustfs

[RustFS](https://github.com/rustfs/rustfs) as an **S3-compatible object store** for
Docker Swarm: one service, one node, one drive, with all of its data on a node-local
volume. It fits a build cache (the GitLab Runner distributed cache), a backup target
or an application's blob store on a small swarm. A single drive has no erasure-coding
redundancy, and this chart does not run RustFS's distributed mode.

What the chart adds on top of the image:

- **Credentials come from Swarm secrets**, which RustFS reads itself
  (`RUSTFS_ACCESS_KEY_FILE` / `RUSTFS_SECRET_KEY_FILE`). The container refuses to
  start if either is missing, empty, has whitespace inside it, or is RustFS's public
  default `rustfsadmin` — the image only warns about that one and starts anyway.
- **The web console is opt-in.** It is a second listener that serves the S3 and
  admin API as well as the UI, so it stays off unless you ask for it. It can log users
  in through an OpenID Connect provider such as Keycloak.
- **Buckets are created for you** (`buckets`), once the server is up, on every
  start; a bucket that already exists is left alone.
- **Logs go to `docker service logs`.** The image writes them to a file inside the
  container by default.

## Prerequisites

```bash
# The root credentials, as external Swarm secrets (never chart values). Any key id works;
# make the secret key long and random, on one line with no whitespace inside it.
printf '%s' 'cache-access-key' | docker secret create rustfs-access-key -
openssl rand -base64 30 | tr -d '\n' | docker secret create rustfs-secret-key -

# The node that holds the data. Skip on a single-node swarm and set
# persistence.nodeLabel="" instead.
docker node update --label-add rustfs-data=true <node>
```

## Installing

If `swarmcli charts repo list` does not show `swarmcli-charts`, add it first:
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.
swarmcli v2.2.0-rc2 and later add it on a first run, while there is no repository
list yet; v2.1.1, and an existing list, are left as they are.

```bash
swarmcli charts install s3 swarmcli-charts/rustfs --set 'buckets={runner-cache}'
```

By default (`exposure.mode: none`) the store is reachable only on the `rustfs-net`
overlay, which swarmcli creates if it is missing. Another stack joins that network as
`external: true` and uses the endpoint `http://<release>_rustfs:9000`
(`http://s3_rustfs:9000` above).

Clients use **path-style** addressing (`http://<endpoint>/<bucket>/<key>`), the
default for every non-AWS S3 client, and region `us-east-1`. For virtual-hosted-style
addressing, set `RUSTFS_SERVER_DOMAINS` in `extraEnv`.

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret and network the release references.
A default install needs:

```yaml
- name: s3                # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    secrets:  [rustfs-access-key, rustfs-secret-key]
    networks: [rustfs-net]
```

Add `traefik-public` to `networks` when the S3 API or the console is traefik-routed,
`rustfs-oidc-client-secret` to `secrets` with `oidc.enabled`, and the path to
`hostPaths` when you set `persistence.volumePath`. Each entry is the name itself, so
an override in values needs the same change here.

## Exposure

The S3 API and the web console are exposed independently. `network.name` is attached
in every mode. `exposure.mode`, `ingress.*` and `publish.*` describe the **S3 API
only**; the console has the same three under `console.*`, and a disabled console is
exposed nowhere:

| Mode | S3 API (`exposure.mode`) | Console (`console.exposure.mode`) |
|------|--------------------------|-----------------------------------|
| `none` (default) | nothing — overlay clients only | nothing — overlay clients only |
| `traefik` | Traefik labels routing `ingress.host` to `s3.port`, with an HTTPS router and ACME certificate when `ingress.tls` | the same for `console.ingress.host` and `console.port`, TLS per `console.ingress.tls` |
| `published` | `s3.port` published on the Swarm as `publish.port` | `console.port` published as `console.publish.port` |

Either route joins `exposure.network`. The S3 API through Traefik:

```bash
swarmcli charts install s3 swarmcli-charts/rustfs \
  --set exposure.mode=traefik --set ingress.host=s3-cache.example.com \
  --set 'buckets={runner-cache}'
```

The console in a browser through Traefik, with the S3 API (port 9000) left on
`rustfs-net` only:

```yaml
# values.yaml — swarmcli charts install s3 swarmcli-charts/rustfs -f values.yaml
exposure:
  mode: none                    # the S3 API stays internal
console:
  enabled: true
  exposure:
    mode: traefik
  ingress:
    host: rustfs.example.com    # a host of its own, not ingress.host
```

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository
(entrypoints `http`/`https`, resolver `le`, constraint label `traefik-public`,
redirect middleware `https-redirect`); override them for your own Traefik. The
whole bucket namespace is served at the root of `ingress.host`, which is what
path-style requires — do not put a path prefix in front of it.

While either listener is traefik-routed, the chart raises RustFS's idle-connection
timeout to `traefik.idleTimeoutSeconds` (120). RustFS closes an idle upstream
connection after 75 seconds by default, Traefik keeps them for 90, and a large `PUT`
sent on a connection RustFS has just closed fails with `socket hang up`. If you run
your own proxy, keep its upstream keep-alive below RustFS's timeout. Traefik's
entrypoints also time out slow requests (v3's default `readTimeout` is 60s); raise it
on the edge if multi-gigabyte uploads fail part-way.

## Web console

The console listens on `console.port` (9001) and serves its UI under
`/rustfs/console/`; you log in with the key pair from the secrets, or through
[single sign-on](#single-sign-on). On `rustfs-net` it is
`http://<release>_rustfs:9001`; `console.exposure.mode` routes it on
`console.ingress.host` or publishes it as `console.publish.port` (see
[Exposure](#exposure) for the console-only example). A browser that opens `/` is
redirected to `/rustfs/console/`. Routed, the console needs a host of its own, not
`ingress.host`: its UI calls the S3 and admin API at the root of the host it was
loaded from.

That listener is the whole server, not just the UI: **the console host also serves
the full signed S3 and admin API**, exactly as the S3 port does, so routing only the
console still puts that API on a public name. Exposing it adds no unauthenticated
surface, but it does add a public endpoint for your root credentials, and the console
keeps them in the browser's local storage. Leave it off where you do not use it.

### GitLab Runner cache

The runner's job helper containers upload and download the cache archive
themselves, and they run on the node's own Docker engine — not on any overlay. So
the runner needs an endpoint reachable from a plain container on each runner
node: the Traefik host (or a published port), not `<release>_rustfs`. With the
[gitlab-runner chart](../gitlab-runner):

```yaml
cache:
  enabled: true
  s3:
    server: s3-cache.example.com     # ingress.host
    bucket: runner-cache             # listed in this chart's buckets
    addressing: path
    accessKeySecret: rustfs-access-key
    secretKeySecret: rustfs-secret-key
```

## Single sign-on

With `oidc.enabled` the console offers a login through an OpenID Connect provider
beside the key-pair login, and RustFS's STS (`AssumeRoleWithWebIdentity`) accepts that
provider's tokens. RustFS maps each value of the ID token's `groups` claim to the
RustFS policy of the same name (`consoleAdmin`, `readwrite`, `readonly`, or your own)
and gives the session temporary credentials with those policies.

With [Keycloak](../keycloak), in your realm:

1. Create an OpenID Connect client, e.g. `rustfs`, with **Client authentication** on
   (a confidential client) and **Standard flow** on; turn the other flows off. Set
   **PKCE Method** to `S256`.
2. Set **Valid redirect URIs** to exactly the console's public URL followed by the
   callback path, `https://rustfs.example.com/rustfs/admin/v3/oidc/callback/default`,
   and **Web origins** to `https://rustfs.example.com`.
3. Add a **Group Membership** mapper with token claim name `groups`, **Full group
   path off** and **Add to ID token** on, and create groups named after the RustFS
   policies. With the full path on the claim reads `/readwrite`, which matches no
   policy and grants nothing.
4. Put the client secret (**Credentials** tab) in a Swarm secret:
   `printf '%s' '<client secret>' | docker secret create rustfs-oidc-client-secret -`

```yaml
console:
  enabled: true
  exposure:
    mode: traefik
  ingress:
    host: rustfs.example.com
oidc:
  enabled: true
  configUrl: https://keycloak.example.com/realms/<realm>/.well-known/openid-configuration
  clientId: rustfs
```

- **The callback.** RustFS builds it from `oidc.browserUrl`, which the chart derives
  as `https://<console.ingress.host>` while the console is traefik-routed; set it
  yourself for a published console (e.g. `http://node1.example.com:9001`). It is
  passed as `RUSTFS_BROWSER_REDIRECT_URL`, so a request's `Host` header cannot move
  the callback.
- **Use the provider's public URL** for `configUrl`: the browser is sent to the
  authorization endpoint the discovery document names, and RustFS checks the
  document's issuer against `configUrl`. For the keycloak chart that is its
  `ingress.host`.
- **The provider's origin is allow-listed.** RustFS refuses to contact a provider on
  a private address (an overlay, a LAN) unless its origin is in
  `RUSTFS_OUTBOUND_ALLOW_ORIGINS`, and the chart sets that to the origin of
  `configUrl`. It is RustFS's one allow-list for every outbound connection it polices,
  so event and audit webhooks and Object Lambda targets may reach that origin too —
  and no other. If the discovery document names endpoints on another origin, set
  `RUSTFS_OUTBOUND_ALLOW_ORIGINS` in `extraEnv` to the full comma-separated list; it
  replaces the chart's.
- **The provider must be up when RustFS starts.** RustFS reads the discovery
  document once, at start, and does not retry. If the provider is unreachable then,
  the console has no single sign-on and STS refuses the provider's tokens until RustFS
  restarts (`docker service update --force <release>_rustfs`); the key-pair login
  keeps working.
- **The client secret** goes from the Swarm secret into the server's environment at
  start, by the start-up wrapper; it is never in the manifest or `docker inspect`.
  `extraEnv` refuses it in every spelling.
- **What `extraEnv` may tune**, as `RUSTFS_IDENTITY_OPENID_<name>` and only with
  `oidc.enabled`: `SCOPES`, `CLAIM_NAME`, `CLAIM_PREFIX`, `ROLE_POLICY`,
  `DISPLAY_NAME` (the button's label), `GROUPS_CLAIM`, `ROLES_CLAIM`, `EMAIL_CLAIM`,
  `USERNAME_CLAIM` and `HIDE_FROM_UI`. Every other OIDC setting is refused, since the
  provider, client, issuer and callback come from `oidc.*`, and so is a provider
  suffix: a second provider is not supported.

## Security

- **Credentials.** RustFS reads both keys from `/run/secrets` itself; neither value
  appears in the manifest or in `docker inspect`. Anonymous requests are refused, and
  so is the default `rustfsadmin` pair. To rotate, create new secrets under new names,
  point `s3.accessKeySecret` / `s3.secretKeySecret` at them and upgrade. `extraEnv`
  refuses the credential variables in both spellings (`RUSTFS_*` and the `MINIO_*`
  ones RustFS also reads), so a key cannot slip into the manifest that way, and the
  bucket loop hands the key pair to `curl` on stdin, so it never appears in a
  process list.
- Everything on `network.name`, and while either listener is traefik-routed everything
  on `exposure.network`, can reach the S3 port (and the console port when enabled).
  That is the intent; the key pair is what protects the data.
- **No call home.** `RUSTFS_CHECK_UPDATE` is off: the image is pinned, and the pin is
  what moves.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a background
loop in the container, once the server answers. For a bucket that already exists
RustFS answers `200`, as S3 does in us-east-1, and the loop also accepts `409`, so
restarts and upgrades are harmless; a bucket that cannot be created after
five minutes is logged (`docker service logs`) and the server keeps running. Removing
a name from `buckets` does not delete the bucket. If you set `RUSTFS_REGION` in
`extraEnv`, the loop signs for that region.

## Persistence & node pinning

Everything lives under `/data` on the `rustfs-data` volume, pinned to the node
labelled `rustfs-data=true` while `persistence.enabled`. `persistence.volumePath`
bind-mounts a host directory instead. It must exist on that node and be owned by
uid/gid 10001, the user RustFS runs as, which cannot fix ownership itself:

```bash
install -d -o 10001 -g 10001 -m 0750 /srv/rustfs
```

`persistence.enabled: false` stores everything in the container — lost when the
task is replaced, for tests only. The service is always one replica and updates stop
the old task before starting the new one: two processes must never share `/data`.

The chart raises the open-file limit to `nofile` (65536): below 16384 RustFS turns
off its per-disk file-descriptor cache, which costs performance. Set `nofile: 0` to
keep the daemon's default. swarmcli deploys through `docker stack deploy`, which
applies `ulimits` to a Swarm service from Docker 23 on; an older Docker CLI ignores
it with a warning.

## Metrics

RustFS 1.0 has no Prometheus endpoint to scrape, so this chart has no
`metrics.enabled`. It pushes OpenTelemetry metrics, traces and logs instead: set
`RUSTFS_OBS_ENDPOINT` in `extraEnv` to an OTLP/HTTP collector, and scrape the
collector.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `rustfs/rustfs` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `s3.port` | `9000` | S3 listen port |
| `s3.accessKeySecret` | `rustfs-access-key` | External secret holding the root access key |
| `s3.secretKeySecret` | `rustfs-secret-key` | External secret holding the root secret key |
| `console.enabled` | `false` | Run the web console listener |
| `console.port` | `9001` | Console listen port (must differ from `s3.port`) |
| `console.exposure.mode` | `none` | Console: `none`, `traefik` or `published` |
| `console.ingress.host` / `.tls` | `""` / `true` | Console `Host()` rule (required in traefik mode, not `ingress.host`) and HTTPS routers |
| `console.publish.port` / `.mode` | `9001` / `ingress` | Console published port (published mode) |
| `oidc.enabled` | `false` | Console single sign-on through an OpenID Connect provider |
| `oidc.configUrl` | `""` | The provider's discovery document URL (required when enabled) |
| `oidc.clientId` | `rustfs` | Client ID |
| `oidc.clientSecretSecret` | `rustfs-oidc-client-secret` | External secret holding the client secret |
| `oidc.browserUrl` | `""` | Console public base URL for the callback; `""` = from `console.ingress` when routed, required otherwise with the console on |
| `buckets` | `[]` | Buckets created at start if missing |
| `persistence.enabled` | `true` | Persist `/data` |
| `persistence.volumeName` | `rustfs-data` | Named volume |
| `persistence.volumePath` | `""` | Host path bind-mounted at `/data` instead (precedence over `volumeName`; owned by 10001) |
| `persistence.nodeLabel` | `rustfs-data` | Node label the service is pinned to; `""` = no pin |
| `placement.constraints` | `[]` | Extra constraints, always applied |
| `network.name` | `rustfs-net` | Overlay S3 clients join (external, auto-created) |
| `exposure.mode` | `none` | S3 API: `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | Edge overlay (when either listener is traefik-routed) |
| `ingress.host` | `s3.example.com` | S3 API `Host()` rule |
| `ingress.tls` | `true` | S3 API HTTPS routers + redirects |
| `traefik.certResolver` | `le` | ACME resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.routerName` | `""` | Router/service name; `""` = release name |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware |
| `traefik.idleTimeoutSeconds` | `120` | RustFS's idle-connection timeout while either listener is routed; must outlast Traefik's 90s |
| `publish.port` / `publish.mode` | `9000` / `ingress` | S3 API published port (published mode) |
| `nofile` | `65536` | Open-file limit; `0` = daemon default |
| `extraEnv` | `{}` | Extra `RUSTFS_*` environment. Credentials, the listener addresses and every OIDC setting but the tuning ones ([Single sign-on](#single-sign-on)) are refused; `RUSTFS_OBS_LOG_DIRECTORY`, `RUSTFS_CHECK_UPDATE`, `RUSTFS_HTTP1_HEADER_READ_TIMEOUT` and `RUSTFS_OUTBOUND_ALLOW_ORIGINS` override the chart's defaults |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/health/ready` on the S3 port |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits |
| `labels` | `{}` | Extra deploy labels |
