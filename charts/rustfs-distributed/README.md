# rustfs-distributed

[RustFS](https://github.com/rustfs/rustfs) in **distributed mode** for Docker Swarm: an
S3-compatible object store whose objects are erasure-coded across several peers, one per
node. With the default 4 peers of one drive each, every object is split into 2 data and 2
parity shards, so reads survive 2 peers down and writes survive 1. It is RustFS's
multi-node, multi-drive (MNMD) deployment, the mode its own Helm chart installs by default.

Each peer is a Swarm service of its own (`rustfs-1` … `rustfs-<peers>`) with exactly one
replica, its own volume and its own node label, because a Swarm volume is node-local. What
the chart adds on top of the image is the same as the [rustfs](../rustfs) chart's, on every
peer — credentials from Swarm secrets with `rustfsadmin` refused, an opt-in web console
with single sign-on, buckets created for you, logs on `docker service logs` — plus:

- **One cluster, wired so that it can start on Swarm.** Every peer starts with the same
  volume list and names itself in it ([How the peers find each other](#how-the-peers-find-each-other)).
- **Upgrades roll one peer at a time.** Each peer carries `com.swarmcli.rollout=sequential`,
  so swarmcli ≥ 2.2.0 updates the next peer only once the one before runs and has outlived
  its monitor window ([Upgrading](#upgrading)).
- **Shapes RustFS would refuse are refused at render**: a peer count and drive count with no
  valid erasure set, more than one drive per peer on named volumes, one host path named
  twice ([Sizing](#sizing)).

It is not a mode of the `rustfs` chart: a single-drive store cannot become a distributed one
in place ([Moving from the rustfs chart](#moving-from-the-rustfs-chart)).

## Prerequisites

```bash
# The root credentials, shared by every peer, as external Swarm secrets (never chart
# values). Make the secret key long and random, on one line with no whitespace inside it.
printf '%s' 'cluster-access-key' | docker secret create rustfs-access-key -
openssl rand -base64 30 | tr -d '\n' | docker secret create rustfs-secret-key -

# One node per peer, each labelled for the peer whose drives live there. The chart pins
# peer N to node.labels.rustfs-<N>.
docker node update --label-add rustfs-1=true <node-a>
docker node update --label-add rustfs-2=true <node-b>
docker node update --label-add rustfs-3=true <node-c>
docker node update --label-add rustfs-4=true <node-d>
```

Peers belong on different nodes: peers sharing a node share its fate, and with the default
parity losing one node that holds two peers stops writes. On a single-node swarm (to
develop against, never for availability), either label that node with every peer's label
or set `persistence.nodeLabelPrefix=""`.

## Installing

If `swarmcli charts repo list` does not show `swarmcli-charts`, add it first:
`swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts`.

```bash
swarmcli charts install s3 swarmcli-charts/rustfs-distributed --set 'buckets={backups}' --wait
```

The chart needs swarmcli 2.2.0 or later, the first to roll services one at a time; among
its release candidates that is v2.2.0-rc4, while rc1 to rc3 pass the floor but update every
peer at once. All peers start together on install, find each other within seconds, and
`--wait` returns once each peer's task runs and is 90 seconds old (its monitor window). The
shape — `cluster.peers` and `cluster.drivesPerPeer` — is fixed from then on: RustFS records
it on every drive.

### Deploying with swarmcli-cd

[swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd) deploys a release only if its
application's `allow` names every `external:` secret and network the release references. A
default install needs:

```yaml
- name: s3                # an application in the swarmcli-cd app set
  source: { ... }
  allow:
    secrets:  [rustfs-access-key, rustfs-secret-key]
    networks: [rustfs-net]
```

Add `traefik-public` to `networks` when the S3 API or the console is traefik-routed,
`monitoring` with `metrics.enabled`, `rustfs-oidc-client-secret` to `secrets` with
`console.oidc.enabled`, and the paths to `hostPaths` when you set
`persistence.volumePaths`. swarmcli-cd rolls the peers one at a time from v1.5.0-rc4 on.

## Connecting

By default (`exposure.mode: none`) the cluster is reachable only on the `rustfs-net`
overlay, which swarmcli creates if it is missing. Another stack joins that network as
`external: true` and uses `http://<release>-rustfs:9000` (`http://s3-rustfs:9000` above),
the same endpoint the `rustfs` chart gives a single-node store. Every peer carries that
alias, so it resolves to every peer, and any peer serves every object. `_` and `.` in the
release name become `-`, because Java clients reject a host name with `_`.

- **The alias is not readiness-aware.** Swarm resolves it to every peer whose healthcheck
  passes, which is liveness: on a first install, or after every peer stopped, the peers pass
  theirs some 10 seconds before the cluster serves and answer 503 meanwhile, and a
  connection already on its way to a peer that stops fails. Clients must retry, as S3
  clients do by default.
- Each peer also answers on `http://<release>-rustfs-<n>:9000`, the name the other peers
  dial it by.
- Clients use **path-style** addressing (`http://<endpoint>/<bucket>/<key>`) and region
  `us-east-1`, as with the `rustfs` chart.

## Exposure

As in the [rustfs chart](../rustfs/README.md#exposure), the S3 API (`exposure.*`,
`ingress.*`, `publish.*`) and the console (`console.exposure.*`, `console.ingress.*`,
`console.publish.*`) are exposed independently, with the same `traefik.*` defaults. On a
cluster:

- **traefik**: every peer declares the same routers and services, Traefik merges them into
  one service and balances requests over every healthy peer.
- **published**: host mode only (`publish.mode` and `console.publish.mode` accept `host`
  alone). Every peer publishes the same port on its own node, which the routing mesh cannot
  give several services, so `<node>:<publish.port>` reaches the peer running there. Put a
  load balancer over the nodes, or use Traefik.

The idle-connection timeout (`traefik.idleTimeoutSeconds`) and the console's host of its
own work as in the rustfs chart.

## Web console

`console.enabled` runs the console on every peer, at `http://<release>-rustfs:9001` on
`rustfs-net`. As in the rustfs chart, the
console listener is the whole server: the console host also serves the full signed S3 and
admin API.

Routed through Traefik, the console carries a **sticky cookie**, so a browser stays on one
peer: each peer keeps a single sign-on login's state in its own memory.

## Single sign-on

Set up the provider exactly as the rustfs chart's
[Single sign-on](../rustfs/README.md#single-sign-on) section describes; the values, the
callback and what `extraEnv` may tune are the same. On a cluster:

- **Every peer is a client of the provider**, with the same client id, secret and callback.
- **Route the console through Traefik**, whose sticky cookie keeps a browser on the peer
  that started its login. RustFS keeps the login's PKCE verifier and nonce in that peer's
  memory, so a callback reaching another peer fails with an invalid-state error. A
  published console keeps a browser on one node's peer by itself; the `rustfs-net` alias
  does not.
- **The provider must be up when the peers start.** Each peer reads the discovery document
  once, at start. A peer that could not reach it has no single sign-on until it restarts
  (`docker service update --force <release>_rustfs-<n>`).

## Sizing

RustFS groups the drives into erasure sets of 2 to 16 drives, and splits every object
across the drives of one set into data and parity shards.

- **The set width** is the largest size from 2 to 16 that divides `peers × drivesPerPeer`
  and also divides the peer count or is a multiple of it. 4 × 1 gives one set of 4, 4 × 2
  one set of 8, 6 × 2 one set of 12. With no such width (17 or 19 peers of one drive, say)
  the render fails, because every peer would refuse to start.
- **Parity** defaults to 2 for a set of 4 or 5 drives, 3 for 6 or 7, and 4 from 8 on.
  Reads need as many drives as there are data shards, writes one more when parity is half
  the set, and parity can be at most half the set. Set another with
  `extraEnv.RUSTFS_STORAGE_CLASS_STANDARD` at install (e.g. `EC:1` on a set of 4, `EC:3` on
  a set of 8).
- **Usable capacity** is the drives' total times data ÷ (data + parity): half of it with
  the default 4 peers.
- **More than one drive per peer** needs `persistence.volumePaths`, one host path per drive,
  each on a disk of its own. RustFS refuses two drives on one physical disk ("local erasure
  endpoints must use distinct physical disks"), and a peer's named volumes all share its
  node's Docker disk. The render refuses `drivesPerPeer > 1` without host paths.
- **The shape is fixed at install.** RustFS records the drive count and set width on every
  drive and refuses to start with others. RustFS grows by adding a server pool, which this
  chart does not support yet. The volume list is written in RustFS's ellipsis form
  (`http://s3-rustfs-{1...4}:9000/data/rustfs0`) so that a later version can append a pool
  without renaming this one.

## How the peers find each other

Swarm puts no name of a task in DNS — not its `tasks.<service>` name, not a network alias,
not the service name — and routes nothing to its VIP until the task's healthcheck passes.
RustFS, for its part, resolves every peer in its volume list, its own entry included, before
it opens a port. Left to itself, no peer would ever pass a healthcheck, and no peer would
ever start. So the chart:

- gives every peer `RUSTFS_LOCAL_ENDPOINT_HOST=<release>-rustfs-<n>`, which RustFS matches
  against the volume list by name, without DNS, and accepts only with
  `RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE=orchestrated`. That mode also waits for the other peers
  without a time limit, where the default outside Kubernetes exits after 180 seconds;
- checks `/health/live`, which a peer answers on its own, not `/health/ready`, which needs
  the other peers' lock quorum. A healthcheck on readiness would keep every peer out of DNS
  for good on a first install and after every peer stopped.

The peers dial each other at their aliases' VIPs, which survive a reschedule. The cost of a
liveness healthcheck is that it says nothing about the cluster: whether the cluster serves is
`/minio/health/cluster` on any peer, which the [upgrade steps](#upgrading) check. Measured
on RustFS's pinned version, a peer restarted into a running cluster answers `/health/ready`
200 before its own healthcheck has passed.

## Upgrading

```bash
swarmcli charts upgrade s3 swarmcli-charts/rustfs-distributed -f s3-values.yaml --wait
```

swarmcli updates the peers one at a time, in lexical name order (`rustfs-10` before
`rustfs-2`): it stops a peer, starts its new
task, waits until that task runs and has outlived `healthcheck.monitor` (90 seconds), and
only then moves to the next. With the default 4 peers the cluster keeps serving reads and
writes throughout, one peer short. An upgrade whose peer fails to start stops there, with
the rest untouched. Pass the values you installed with (`-f`), not `--reuse-values`
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

Check the cluster before and after, from any container on `rustfs-net`:

```bash
docker run --rm --network rustfs-net curlimages/curl -s -o /dev/null -w '%{http_code}\n' \
  http://s3-rustfs:9000/minio/health/cluster     # 200: every erasure set has write quorum
```

Install is never sequential: all peers start together, which is what a first install
needs.

## Moving from the rustfs chart

There is no in-place conversion. RustFS refuses to start a single-drive store with more than
one drive ("an existing single-node single-drive (SNSD) deployment cannot be expanded in
place"), so a distributed cluster always starts empty. Install this chart as a second
release, copy the buckets across through S3 (e.g. `rclone sync` or `mc mirror` from one
endpoint to the other), move clients to the new endpoint, then uninstall the old release.
Both charts default to `rustfs-net` and to `http://<release>-rustfs:9000`, so a client
needs only the new release name.

## Security

As in the [rustfs chart](../rustfs/README.md#security), on every peer: RustFS reads both keys
from `/run/secrets`, anonymous requests and the default `rustfsadmin` pair are refused, and
`extraEnv` refuses the credential variables in both spellings.

- Everything on `network.name`, and while either listener is traefik-routed everything on
  `exposure.network`, reaches every peer's S3 port (and console port when enabled), which
  also carries the peers' internode RPC. That is the intent; the key pair is what protects
  the data, and RustFS signs the internode requests with a secret derived from it.
- `extraEnv` also refuses the cluster wiring the chart sets (`RUSTFS_VOLUMES`,
  `RUSTFS_LOCAL_ENDPOINT_HOST`, `RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE`), an erasure set width
  (`RUSTFS_ERASURE_SET_DRIVE_COUNT`, which would override the one the render checks), the
  internode secret (`RUSTFS_RPC_SECRET`, a credential), and RustFS's test-only switch off its
  one-drive-per-disk check (`RUSTFS_UNSAFE_BYPASS_DISK_CHECK`, `MINIO_CI`).
- **Rotating the key pair takes a full stop.** Every peer derives the internode secret from
  the pair, so peers on the old pair and peers on the new one cannot reach each other: an
  upgrade rolling one peer at a time would split the cluster. Create the new secrets, stop
  every peer, then upgrade; swarmcli holds back only peers that are running, so all of them
  start together on the new pair:

  ```bash
  printf '%s' 'new-access-key' | docker secret create rustfs-access-key-2 -
  openssl rand -base64 30 | tr -d '\n' | docker secret create rustfs-secret-key-2 -
  for n in 1 2 3 4; do docker service scale --detach "s3_rustfs-$n=0"; done
  swarmcli charts upgrade s3 swarmcli-charts/rustfs-distributed -f s3-values.yaml --wait \
    --set s3.accessKeySecret=rustfs-access-key-2 --set s3.secretKeySecret=rustfs-secret-key-2
  ```

  The data and buckets survive; clients need the new pair.
- **No call home.** `RUSTFS_CHECK_UPDATE` is off on every peer.

## Buckets

Peer 1 creates each entry in `buckets` with a signed S3 `CreateBucket` once the cluster
accepts writes, as the rustfs chart's single service does ([Buckets](../rustfs/README.md#buckets));
the other peers see them through the cluster. A restart of peer 1 is harmless, removing a
name does not delete the bucket. The loop gives up five minutes after peer 1 starts, which on
a cluster includes waiting for the others (a missing node label, a slow image pull): a
bucket not created by then is logged on `docker service logs <release>_rustfs-1`, and
`docker service update --force <release>_rustfs-1` runs the loop again.

## Persistence & node pinning

Each peer's drive lives on its own named volume, `<volumePrefix>-<n>` (`rustfs-data-1` …),
mounted at `/data`, with the drive at `/data/rustfs0` inside it, and each peer is pinned to
the node labelled `<nodeLabelPrefix>-<n>=true` while `persistence.enabled`.

`persistence.volumePaths` bind-mounts host directories instead: one entry per peer, in peer
order, each a list of `drivesPerPeer` absolute paths (a single path may be a string), drive
`k` mounted at `/data/rustfs<k>`. Each must exist on its peer's node, on a disk no other
drive of that peer uses, owned by uid/gid 10001, the user RustFS runs as:

```bash
install -d -o 10001 -g 10001 -m 0750 /mnt/disk1/rustfs /mnt/disk2/rustfs   # on every node
```

```yaml
cluster:
  drivesPerPeer: 2
persistence:
  volumePaths:          # the same paths on every node: each peer is on a node of its own
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
    - [/mnt/disk1/rustfs, /mnt/disk2/rustfs]
```

With `persistence.nodeLabelPrefix: ""` nothing keeps the peers on different nodes, so then
the render refuses a path given to two peers.

`persistence.enabled: false` stores every drive in its container: a peer whose task is
replaced starts on an empty drive, which RustFS formats at start and heals from the others,
but losing more peers at once than the parity covers loses data. For tests only. Each peer is always one replica, and its updates
stop the old task before starting the new one.

The chart raises the open-file limit to `nofile` (65536), as the rustfs chart does.

## Metrics

`metrics.enabled` adds one [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/),
`<release>_rustfs-distributed-metrics`, which every peer pushes to over `rustfs-net` and
which Prometheus finds on the `monitoring` overlay through the `prometheus.io/scrape` and
`prometheus.io/port=8889` deploy labels, as with the rustfs chart's
([Metrics](../rustfs/README.md#metrics)): the same series, the same OTLP settings the chart
owns and `extraEnv` refuses, and the same reach of the unauthenticated collector ports. On a
cluster:

- Each peer's own series (process, requests, drives) carry its name in a `server` label,
  `<release>-rustfs-<n>:9000`. The cluster-wide series (capacity, erasure sets, drives
  offline) come from every peer, each with an `observer` label naming the peer that
  reports it.
- A peer that stops keeps its last series in the collector for 5 minutes, showing the
  cluster as it last saw it. Read quorum as the worst view any peer reports, as the rules do.
- **Turning metrics on restarts every peer once, one at a time.** Turning them off leaves the
  collector running (swarmcli deploys without `--prune`), so remove it in the same step:
  `docker service rm <release>_rustfs-distributed-metrics`.
- The collector is named `rustfs-distributed-metrics`, not `rustfs-metrics` as in the rustfs
  chart, and this chart's rules select it by `job`, so they never evaluate a single-node
  release. The rustfs chart's rules do not filter by `job` yet: loaded beside these, its
  `RustFSDriveOffline` also fires, at critical, for a distributed release's offline drive.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) and deploys neither. Load them as the
rustfs chart's [Alerts and a dashboard](../rustfs/README.md#alerts-and-a-dashboard) shows,
with this chart's files and keys:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/rustfs-distributed/monitoring
curl -fsSL -O "$base/rustfs-distributed-rules.yml" -O "$base/rustfs-distributed-dashboard.json"
v="$(swarmcli charts status mon | sed -n 's/^CHART: prometheus-stack-//p')"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --version "${v:?}" --reuse-values \
  --set-file prometheus.extraRules.rustfs-distributed=./rustfs-distributed-rules.yml \
  --set-file grafana.dashboards.rustfs-distributed=./rustfs-distributed-dashboard.json
```

`--version` keeps prometheus-stack at the version it runs, the only case in which
`--reuse-values` is safe (Eldara-Tech/swarmcli#687). For a release file or swarmcli-cd,
transcribe both files into values files as the rustfs chart's README shows.

- **Alerts** (`rustfs-distributed-rules.yml`), each grouped by `stack` and `job`, quorum ones
  also by `pool_id` and `set_id`. Critical: `RustFSClusterNotReporting` once the collector
  has answered with nothing from any peer for about 15 minutes; `RustFSWriteQuorumLost` and
  `RustFSReadQuorumLost` while an erasure set has fewer drives online than its write or read
  quorum, so writes, or reads, to it fail; `RustFSWriteQuorumAtRisk` while a set has exactly
  its write quorum online, one failure from refusing writes — with the default 4 peers, one
  peer down; and `RustFSS3ServerErrors` while more than 5% of what the peers answer is 5xx.
  Warnings: `RustFSDrivesOffline` while any drive or peer is offline within the parity,
  `RustFSCapacityLow` below 10% free, and `RustFSDriveIOErrors` per peer. A single peer that
  stops shows up as `RustFSDrivesOffline` and, at the default size, `RustFSWriteQuorumAtRisk`.
- **Dashboard** (`rustfs-distributed-dashboard.json`, uid `rustfs-distributed`), the rustfs
  chart's with the peers reporting and drives offline at the top, and memory, CPU and open
  files per peer.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `rustfs/rustfs` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `cluster.peers` | `4` | Peers, one service each; at least 4; fixed at install |
| `cluster.drivesPerPeer` | `1` | Drives per peer; more than 1 needs `persistence.volumePaths`; fixed at install |
| `s3.port` | `9000` | S3 listen port, which the peers also dial each other on |
| `s3.accessKeySecret` | `rustfs-access-key` | External secret holding the root access key |
| `s3.secretKeySecret` | `rustfs-secret-key` | External secret holding the root secret key |
| `console.enabled` | `false` | Run the web console listener on every peer |
| `console.port` | `9001` | Console listen port (must differ from `s3.port`) |
| `console.exposure.mode` | `none` | Console: `none`, `traefik` or `published` |
| `console.ingress.host` / `.tls` | `""` / `true` | Console `Host()` rule (required in traefik mode, not `ingress.host`) and HTTPS routers |
| `console.publish.port` / `.mode` | `9001` / `host` | Console published port on each peer's node (`host` only) |
| `console.oidc.*` | off | Console single sign-on, as in the rustfs chart ([Single sign-on](#single-sign-on)) |
| `buckets` | `[]` | Buckets peer 1 creates at start if missing |
| `persistence.enabled` | `true` | Persist each peer's drives |
| `persistence.volumePrefix` | `rustfs-data` | Named volume prefix, one per peer (`-<n>`) |
| `persistence.volumePaths` | `[]` | Host paths instead: one entry per peer, each `drivesPerPeer` paths (owned by 10001) |
| `persistence.nodeLabelPrefix` | `rustfs` | Node label prefix pinning peer N (`-<N>`); `""` = no pins |
| `placement.constraints` | `[]` | Extra constraints, applied to every peer |
| `network.name` | `rustfs-net` | Overlay the peers and S3 clients share (external, auto-created) |
| `exposure.mode` | `none` | S3 API: `none`, `traefik` or `published` |
| `exposure.network` | `traefik-public` | Edge overlay (when either listener is traefik-routed) |
| `ingress.host` / `.tls` | `s3.example.com` / `true` | S3 API `Host()` rule and HTTPS routers |
| `traefik.*` | as in the rustfs chart | Resolver, entrypoints, router name, constraint label, redirect middleware, idle timeout |
| `publish.port` / `publish.mode` | `9000` / `host` | S3 API published port on each peer's node (`host` only) |
| `nofile` | `65536` | Open-file limit; `0` = daemon default |
| `extraEnv` | `{}` | Extra `RUSTFS_*` environment for every peer. Refused as in the rustfs chart, plus the cluster wiring and the disk-check bypass ([Security](#security)) |
| `metrics.enabled` | `false` | One OpenTelemetry Collector every peer pushes to. See *Metrics*. |
| `metrics.image.repository` / `.tag` | `otel/opentelemetry-collector` / pinned in `values.yaml` | Collector image (a concrete pin; Renovate maintains it) |
| `metrics.network` | `monitoring` | External overlay the collector shares with Prometheus (auto-created) |
| `metrics.resources.limits.memory` | `256M` | The collector's memory limit |
| `healthcheck.*` | enabled, 10s/5s/3, start 30s, monitor 90s | `curl` of `/health/live`; `monitor` is also how long swarmcli waits on each peer before rolling the next |
| `stopGracePeriod` | `30s` | SIGTERM → SIGKILL window |
| `resources.limits.memory` / `resources.reservations.memory` | `""` | Optional memory limits per peer |
| `labels` | `{}` | Extra deploy labels for every peer |
