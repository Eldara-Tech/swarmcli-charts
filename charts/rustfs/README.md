# rustfs

[RustFS](https://github.com/rustfs/rustfs) as an **S3-compatible object store** for
Docker Swarm: one service, one node, one drive, with all of its data on a node-local
volume. It fits a build cache (the GitLab Runner distributed cache), a backup target
or an application's blob store on a small swarm. A single drive has no erasure-coding
redundancy, and this chart does not run RustFS's distributed mode.

What the chart adds on top of the image:

- **Credentials come from Swarm secrets**, which RustFS reads itself
  (`RUSTFS_ACCESS_KEY_FILE` / `RUSTFS_SECRET_KEY_FILE`). The container refuses to
  start if either is missing, empty, or RustFS's public default `rustfsadmin` — the
  image only warns about that one and starts anyway.
- **The web console is opt-in.** It is a second listener that serves the S3 and
  admin API as well as the UI, so it stays off unless you ask for it.
- **Buckets are created for you** (`buckets`), once the server is up, on every
  start; a bucket that already exists is left alone.
- **Logs go to `docker service logs`.** The image writes them to a file inside the
  container by default.

## Prerequisites

```bash
# The root credentials, as external Swarm secrets (never chart values). Any key id works;
# make the secret key long and random.
printf '%s' 'cache-access-key' | docker secret create rustfs-access-key -
openssl rand -base64 30 | tr -d '\n' | docker secret create rustfs-secret-key -

# The node that holds the data. Skip on a single-node swarm and set
# persistence.nodeLabel="" instead.
docker node update --label-add rustfs-data=true <node>
```

## Installing

swarmcli releases after v2.1.1 come with this repository configured as
`swarmcli-charts`. On v2.1.1 or earlier, add it first with
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.

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

Add `traefik-public` to `networks` in traefik mode, and the path to `hostPaths` when
you set `persistence.volumePath`. Each entry is the name itself, so an override in
values needs the same change here.

## Exposure

`network.name` is attached in every mode. `exposure.mode` adds:

| Mode | What it adds |
|------|--------------|
| `none` (default) | nothing — overlay clients only |
| `traefik` | Traefik labels on `exposure.network`, routing `ingress.host` to the S3 port (and `console.host` to the console), with an HTTPS router and ACME certificate when `ingress.tls` |
| `published` | `s3.port` published on the Swarm as `publish.port` (and the console as `publish.consolePort`) |

```bash
swarmcli charts install s3 swarmcli-charts/rustfs \
  --set exposure.mode=traefik --set ingress.host=s3-cache.example.com \
  --set 'buckets={runner-cache}'
```

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository
(entrypoints `http`/`https`, resolver `le`, constraint label `traefik-public`,
redirect middleware `https-redirect`); override them for your own Traefik. The
whole bucket namespace is served at the root of `ingress.host`, which is what
path-style requires — do not put a path prefix in front of it.

In traefik mode the chart raises RustFS's idle-connection timeout to
`traefik.idleTimeoutSeconds` (120). RustFS closes an idle upstream connection after
75 seconds by default, Traefik keeps them for 90, and a large `PUT` sent on a
connection RustFS has just closed fails with `socket hang up`. If you run your own
proxy, keep its upstream keep-alive below RustFS's timeout. Traefik's entrypoints
also time out slow requests (v3's default `readTimeout` is 60s); raise it on the
edge if multi-gigabyte uploads fail part-way.

## Web console

```bash
swarmcli charts upgrade s3 swarmcli-charts/rustfs --reuse-values \
  --set console.enabled=true --set console.host=rustfs.example.com
```

The console listens on `console.port` (9001) and serves its UI under
`/rustfs/console/`; you log in with the key pair from the secrets. On `rustfs-net` it
is `http://<release>_rustfs:9001`, in traefik mode it is routed on `console.host` (a
host of its own, required there), and in published mode it is published as
`publish.consolePort`.

That listener is the whole server, not just the UI: it answers the same signed S3 and
admin API as the S3 port. Exposing it adds no unauthenticated surface, but it does add
a second public endpoint for your root credentials, and the console keeps them in the
browser's local storage. Leave it off where you do not use it.

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

## Security

- **Credentials.** RustFS reads both keys from `/run/secrets` itself; neither value
  appears in the manifest or in `docker inspect`. Anonymous requests are refused, and
  so is the default `rustfsadmin` pair. To rotate, create new secrets under new names,
  point `s3.accessKeySecret` / `s3.secretKeySecret` at them and upgrade. `extraEnv`
  refuses the credential variables, so a key cannot slip into the manifest that way.
- Everything on `network.name`, and in traefik mode everything on `exposure.network`,
  can reach the S3 port (and the console port when enabled). That is the intent; the
  key pair is what protects the data.
- **No call home.** `RUSTFS_CHECK_UPDATE` is off: the image is pinned, and the pin is
  what moves.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a background
loop in the container, once the server answers. `409` (already exists) counts as
done, so restarts and upgrades are harmless; a bucket that cannot be created after
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
keep the daemon's default.

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
| `console.host` | `""` | Traefik `Host()` for the console (traefik mode, required when enabled) |
| `buckets` | `[]` | Buckets created at start if missing |
| `persistence.enabled` | `true` | Persist `/data` |
| `persistence.volumeName` | `rustfs-data` | Named volume |
| `persistence.volumePath` | `""` | Host path bind-mounted at `/data` instead (precedence over `volumeName`; owned by 10001) |
| `persistence.nodeLabel` | `rustfs-data` | Node label the service is pinned to; `""` = no pin |
| `placement.constraints` | `[]` | Extra constraints, always applied |
| `network.name` | `rustfs-net` | Overlay S3 clients join (external, auto-created) |
| `exposure.mode` | `none` | `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | Edge overlay (traefik mode) |
| `ingress.host` | `s3.example.com` | Traefik `Host()` rule |
| `ingress.tls` | `true` | HTTPS routers + redirects (traefik mode) |
| `traefik.certResolver` | `le` | ACME resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.routerName` | `""` | Router/service name; `""` = release name |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware |
| `traefik.idleTimeoutSeconds` | `120` | RustFS's idle-connection timeout in traefik mode; must outlast Traefik's 90s |
| `publish.port` / `publish.consolePort` / `publish.mode` | `9000` / `9001` / `ingress` | Published ports (published mode) |
| `nofile` | `65536` | Open-file limit; `0` = daemon default |
| `extraEnv` | `{}` | Extra `RUSTFS_*` environment (no credentials) |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/health/ready` on the S3 port |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits |
| `labels` | `{}` | Extra deploy labels |
