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
`http://<release>-seaweedfs:8333` (`http://s3-seaweedfs:8333` above), an alias the
chart adds on that network, with `_` and `.` in the release name turned into `-`. The
stack's own service name `<release>_seaweedfs` resolves too, but Java clients (anything
on the AWS SDK for Java, such as Airbyte) reject a host name containing `_`. Releases
whose names differ only in those characters (`my_s3`, `my-s3`) get the same alias, so
keep them off one network.

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
node: the Traefik host (or a published port), not `<release>-seaweedfs`. With the
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
- **No telemetry.** `weed server` reports anonymous cluster statistics to
  telemetry.seaweedfs.com by default; the chart passes `-master.telemetry=false`.
- Everything on `network.name`, and in traefik mode everything on
  `exposure.network`, can reach the S3 port. That is the intent; the key pair is
  what protects the data.

## Buckets

Each entry in `buckets` is created with a signed S3 `CreateBucket` by a
background loop in the container, once the gateway answers. `409` (already
exists) counts as done, so restarts and upgrades are harmless; a bucket that
cannot be created after five minutes is logged (`docker service logs`) and the
server keeps running. Removing a name from `buckets` does not delete the bucket.

## Metrics

SeaweedFS serves its own Prometheus metrics. `metrics.enabled` turns the listener
on — one registry for the master, volume server, filer and S3 gateway in the
process — labels the service `prometheus.io/scrape=true` and
`prometheus.io/port=9327`, and attaches it to the `monitoring` overlay, which is
where the [prometheus-stack chart](../prometheus-stack) scrapes by default. So
Prometheus finds it by itself, with no scrape config; any Prometheus using Docker
Swarm service discovery on those labels works the same way.

```bash
swarmcli charts upgrade s3 swarmcli-charts/seaweedfs -f seaweedfs-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`.
That flag merges over the previous release's stored values *instead of* this chart
version's defaults, so every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

You get the `SeaweedFS_*` series: S3 requests by type, status code and bucket
(`SeaweedFS_s3_request_total`, `SeaweedFS_s3_request_seconds`), volume server and
filer request rates and latencies and disk usage, plus the Go runtime and process
series. Turning it on or off changes the service spec, so weed restarts once.

**What `monitoring` can reach.** The listener binds every interface, and Swarm
overlays do not filter ports, so everything attached to `monitoring` reaches:

- port 9327, unauthenticated: `/metrics`, and on the same listener Go's
  `/debug/pprof/` and `/debug/vars`. weed imports both handlers globally, so they
  cannot be switched off. They hand out the command line, memory statistics and
  goroutine dumps, and CPU profiles and execution traces on request, which cost
  the process CPU while they run. No credentials appear in them: the S3 keys
  are environment variables, and neither endpoint reads the environment. gRPC's
  `/debug/requests` and `/debug/events` sit on the same listener but answer 401
  to anything but loopback;
- the S3 port and its gRPC port, exactly as on `seaweedfs-net`: S3 refuses
  unsigned requests, and the gRPC port refuses identity updates without the
  per-start signing key;
- not the master, volume or filer APIs, which stay on 127.0.0.1.

Every deploy label of the service is also readable through Prometheus's targets
API once it opts in, so `labels` must not carry credentials; the render fails on a
basic-auth label while metrics are on. The metrics port is never published.

To keep the store off a shared overlay, set `metrics.network=seaweedfs-net` (the
service is on it already) and attach Prometheus to that overlay instead, e.g.
prometheus-stack's `prometheus.extraNetworks`. Prometheus should share exactly one
overlay with the service, or it scrapes it once per overlay.

Under [swarmcli-cd](../../docs/gitops.md), the application's `allow` must list the
`monitoring` network as well.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) for your Prometheus and Grafana,
and deploys neither: scraping is automatic, but which rules and dashboards a monitoring
stack loads is its operator's choice. With the prometheus-stack chart they go in
through its own configuration:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/seaweedfs/monitoring
curl -fsSL -O "$base/seaweedfs-rules.yml" -O "$base/seaweedfs-dashboard.json"
v="$(swarmcli charts status mon | sed -n 's/^CHART: prometheus-stack-//p')"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --version "${v:?}" --reuse-values \
  --set-file prometheus.extraRules.seaweedfs=./seaweedfs-rules.yml \
  --set-file grafana.dashboards.seaweedfs=./seaweedfs-dashboard.json
```

`--version` keeps prometheus-stack at the version it runs, the only case in which `--reuse-values`
is safe (Eldara-Tech/swarmcli#687).

A release file and swarmcli-cd take values files only, not `--set-file`, so there both
files go in as values files: each file's content, as it is, indented under its key as a
block string. From the two files downloaded above:

```bash
mkdir -p monitoring/rules monitoring/dashboards
{ printf 'prometheus:\n  extraRules:\n    seaweedfs: |\n'; sed 's/^./      &/' seaweedfs-rules.yml; } > monitoring/rules/seaweedfs.yaml
{ printf 'grafana:\n  dashboards:\n    seaweedfs: |\n'; sed 's/^./      &/' seaweedfs-dashboard.json; } > monitoring/dashboards/seaweedfs.yaml
```

The dashboard stays JSON: converted to YAML it becomes a mapping, which the render
refuses (`got object, want string`). prometheus-stack's README, *Keeping your setup in
git*, shows where to list the two files.

- **Alerts** (`seaweedfs-rules.yml`): SeaweedFS publishes no alert rules, so these are the
  chart's. Critical: `SeaweedFSDiskFull` once free space falls below
  `-volume.minFreeSpace` (1% by default), where every volume turns read-only and S3
  writes fail with 500; `SeaweedFSDiskError` and `SeaweedFSVolumeQuarantined` once weed
  stops serving a disk or a volume after I/O errors; `SeaweedFSNoLeader` while the master
  assigns no volume; and `SeaweedFSS3ServerErrors` while more than 5% of S3 requests answer
  5xx, leaving out 501, which is a client asking for something SeaweedFS does not
  implement. Warnings: `SeaweedFSVolumeSlotsExhausted` once every volume slot the disk
  allows is taken, so a new bucket, or one whose volumes are full, cannot be written to;
  `SeaweedFSReadOnlyVolumes` for volumes marked read-only or found damaged; and
  `SeaweedFSStorageIOErrors`. Each writable volume reserves 1 GiB of free space by
  default, so a small disk runs out of slots after a few buckets. A down target is
  prometheus-stack's `TargetDown`.
- **Dashboard** (`seaweedfs-dashboard.json`, uid `seaweedfs`), trimmed from SeaweedFS's
  [`other/metrics/grafana_seaweedfs.json`](https://github.com/seaweedfs/seaweedfs/blob/master/other/metrics/grafana_seaweedfs.json)
  (Apache-2.0): master leader, uptime, disk available and used, volume slots and
  read-only volumes; S3 requests, non-2xx responses, p99 latency and traffic per bucket;
  bucket size and objects, volumes per bucket and volumes out of service; disk space,
  volume server errors, and the process's memory and CPU. Pick a release by its `stack`.

The dashboard picks a release by the `stack` label prometheus-stack's discovery puts on
every target, and the alerts carry it. Another Prometheus needs the same relabelling of
`__meta_dockerswarm_service_label_com_docker_stack_namespace` to `stack`.

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
| `metrics.enabled` | `false` | Serve Prometheus metrics, labelled for Swarm service discovery. See *Metrics* |
| `metrics.port` | `9327` | Metrics listen port (never published; must differ from the S3 and gRPC ports) |
| `metrics.network` | `monitoring` | Overlay shared with Prometheus (external, auto-created) |
| `healthcheck.*` | enabled, 15s/5s/4, start 30s, monitor 2m | `curl` of `/healthz` on the S3 port |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits |
| `labels` | `{}` | Extra deploy labels |
