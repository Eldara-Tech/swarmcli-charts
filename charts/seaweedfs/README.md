# seaweedfs

[SeaweedFS](https://github.com/seaweedfs/seaweedfs) as an **S3-compatible object
store** for Docker Swarm. One service runs `weed server -s3` — master, volume
server, filer and S3 gateway in a single process — with all of its data on one
node-local volume. It fits a build cache (the GitLab Runner distributed cache),
a backup target or an application's blob store on a small swarm; it is not a
distributed SeaweedFS cluster.

What the chart adds on top of the image:

- **Authentication is always on.** The S3 key pair comes from two external Swarm
  secrets, and the container refuses to start if either is missing or empty —
  SeaweedFS serves every request anonymously when it knows no identity.
- **Only S3 leaves the container.** The master, volume and filer APIs have no
  authentication, so they listen on 127.0.0.1 only.
- **Buckets are created for you** (`buckets`), once the server is up, on every
  start; a bucket that already exists is left alone.

## Prerequisites

```bash
# The S3 credentials, as external Swarm secrets (never chart values). Any key id works;
# make the secret key long and random.
printf '%s' 'cache-access-key' | docker secret create seaweedfs-s3-access-key -
openssl rand -base64 30 | tr -d '\n' | docker secret create seaweedfs-s3-secret-key -

# The node that holds the data. Skip on a single-node swarm and set
# persistence.nodeLabel="" instead.
docker node update --label-add seaweedfs-data=true <node>
```

## Installing

If `swarmcli charts repo list` does not show `swarmcli-charts`, add it first:
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.
swarmcli v2.2.0-rc2 and later add it on a first run, while there is no repository
list yet; v2.1.1, and an existing list, are left as they are.

```bash
swarmcli charts install s3 swarmcli-charts/seaweedfs --set 'buckets={runner-cache}'
```

By default (`exposure.mode: none`) the store is reachable only on the
`seaweedfs-net` overlay, which swarmcli creates if it is missing. Another stack
joins that network as `external: true` and uses the endpoint
`http://<release>_seaweedfs:8333` (`http://s3_seaweedfs:8333` above).

Clients use **path-style** addressing (`http://<endpoint>/<bucket>/<key>`), the
default for every non-AWS S3 client. The region is not checked; send any, e.g.
`us-east-1`.

## Exposure

`network.name` is attached in every mode. `exposure.mode` adds:

| Mode | What it adds |
|------|--------------|
| `none` (default) | nothing — overlay clients only |
| `traefik` | Traefik labels on `exposure.network`, routing `ingress.host` to the S3 port, with an HTTPS router and ACME certificate when `ingress.tls` |
| `published` | `s3.port` published on the Swarm as `publish.port` |

```bash
swarmcli charts install s3 swarmcli-charts/seaweedfs \
  --set exposure.mode=traefik --set ingress.host=s3-cache.example.com \
  --set 'buckets={runner-cache}'
```

The `traefik.*` defaults match the [traefik chart](../traefik) in this repository
(entrypoints `http`/`https`, resolver `le`, constraint label `traefik-public`,
redirect middleware `https-redirect`); override them for your own Traefik. The
whole bucket namespace is served at the root of `ingress.host`, which is what
path-style requires — do not put a path prefix in front of it.

Traefik's entrypoints time out slow requests (v3's default `readTimeout` is 60s).
A multi-gigabyte cache archive over a slow link can exceed that; raise it on the
edge if uploads fail part-way.

### GitLab Runner cache

The runner's job helper containers upload and download the cache archive
themselves, and they run on the node's own Docker engine — not on any overlay. So
the runner needs an endpoint reachable from a plain container on each runner
node: the Traefik host (or a published port), not `<release>_seaweedfs`. With the
[gitlab-runner chart](../gitlab-runner):

```yaml
cache:
  enabled: true
  s3:
    server: s3-cache.example.com     # ingress.host
    bucket: runner-cache             # listed in this chart's buckets
    addressing: path
    accessKeySecret: seaweedfs-s3-access-key
    secretKeySecret: seaweedfs-s3-secret-key
```

## Security

- **Credentials.** The wrapper reads both secrets from `/run/secrets` and exports
  them as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, which SeaweedFS turns into
  its single admin identity; from then on every request must carry a valid SigV4
  signature. Neither value appears in the manifest or in `docker inspect`. To rotate,
  create new secrets under new names, point `s3.accessKeySecret` /
  `s3.secretKeySecret` at them and upgrade.
- **Internal APIs.** The master (9333), volume (8080) and filer (8888) HTTP and
  gRPC APIs bypass S3 authentication entirely, so they are bound to 127.0.0.1.
  `extraArgs` must not rebind `-ip` or `-ip.bind`.
- **The S3 gRPC port** (`s3.port + 10000`, 18333 by default) shares the S3
  gateway's address and accepts identity updates. The chart sets a fresh random
  filer signing key at every start, which makes that port refuse unsigned updates
  — without it, anything on the same overlay could add itself as an admin.
- Everything on `network.name`, and in traefik mode everything on
  `exposure.network`, can reach the S3 port. That is the intent; the key pair is
  what protects the data.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a
background loop in the container, once the gateway answers. `409` (already
exists) counts as done, so restarts and upgrades are harmless; a bucket that
cannot be created after five minutes is logged (`docker service logs`) and the
server keeps running. Removing a name from `buckets` does not delete the bucket.

## Persistence & node pinning

Everything lives under `/data` on the `seaweedfs-data` volume, pinned to the node
labelled `seaweedfs-data=true` while `persistence.enabled`. `persistence.volumePath`
bind-mounts a host directory instead (it must exist on that node; the image fixes
its ownership at start). `persistence.enabled: false` stores everything in the
container — lost when the task is replaced, for tests only. The service is always
one replica and updates stop the old task before starting the new one: two
processes must never share `/data`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `chrislusf/seaweedfs` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `s3.port` | `8333` | S3 listen port (max 55535: the gRPC port is this + 10000) |
| `s3.accessKeySecret` | `seaweedfs-s3-access-key` | External secret holding the access key id |
| `s3.secretKeySecret` | `seaweedfs-s3-secret-key` | External secret holding the secret key |
| `buckets` | `[]` | Buckets created at start if missing |
| `persistence.enabled` | `true` | Persist `/data` |
| `persistence.volumeName` | `seaweedfs-data` | Named volume |
| `persistence.volumePath` | `""` | Host path bind-mounted at `/data` instead (precedence over `volumeName`) |
| `persistence.nodeLabel` | `seaweedfs-data` | Node label the service is pinned to; `""` = no pin |
| `placement.constraints` | `[]` | Extra constraints, always applied |
| `network.name` | `seaweedfs-net` | Overlay S3 clients join (external, auto-created) |
| `exposure.mode` | `none` | `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | Edge overlay (traefik mode) |
| `ingress.host` | `s3.example.com` | Traefik `Host()` rule |
| `ingress.tls` | `true` | HTTPS router + redirect (traefik mode) |
| `traefik.certResolver` | `le` | ACME resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.routerName` | `""` | Router/service name; `""` = release name |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware |
| `publish.port` / `publish.mode` | `8333` / `ingress` | Published port (published mode) |
| `extraArgs` | `[]` | Extra `weed server` flags |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/healthz` on the S3 port |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits |
| `labels` | `{}` | Extra deploy labels |
