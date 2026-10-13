# loki

[Grafana Loki](https://grafana.com/docs/loki/latest/) log aggregation for Docker
Swarm. Deploys the **single-binary** Loki on filesystem storage — one process, one
node-local data volume, no object store to operate — serving the Loki HTTP API on
port **3100**: log shippers `POST` to it, Grafana and LogCLI query it with LogQL.

Because the data lives on a Swarm volume, this is a **single-replica, node-pinned**
service. Retention is on by default, and an opt-in **Grafana Alloy** shipper can
collect every container's logs on every node.

> **Loki has no authentication.** Not "off by default" — none, in any
> configuration. `auth_enabled` selects multi-tenancy, not access control.
> Anything that can reach port 3100 can read every log line you have and write
> forged ones, so how you expose it is a security decision — see
> [Exposure](#exposure).

## Installing

```bash
# Default: no published port and no edge labels. Loki is reachable only as
# loki:3100 on the `monitoring` overlay, which swarmcli creates if it is missing.
swarmcli charts install loki swarmcli-charts/loki
```

Label the node that will hold the data first (see
[Persistence & node pinning](#persistence--node-pinning)):

```bash
docker node update --label-add loki-data=true <node>
```

Point Grafana at it by joining the same overlay and adding a Loki data source with
URL `http://loki:3100`.

## Getting logs in

Loki never collects anything itself — something has to push. Three paths, in the
order most people want them:

### 1. The Alloy shipper this chart ships (`shipper.enabled`)

```bash
swarmcli charts upgrade loki swarmcli-charts/loki --set shipper.enabled=true
```

That adds a **global** [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
service — one task per swarm node — which reads its own node's container logs
through the Docker API and pushes them to Loki over a stack-internal overlay.
Streams are labelled `service` (the Swarm service, e.g. `myapp_web`), `stack` and
`node`; a container started outside Swarm falls back to its container name.

It is **off by default** because it mounts `/var/run/docker.sock`, which is
root-equivalent access to every node it runs on: anything that can talk to that
socket can start a privileged container there. `:ro` protects the socket file, not
the API behind it. Turn it on deliberately, and read `shipper.*` in
[Values](#values) first.

Alloy reads logs through the Docker API, so containers must use a log driver the
API can read back — the default `json-file`, or `local`. A container using the
Loki log-driver plugin below is invisible to it (and does not need it).

### 2. The Docker `loki` log-driver plugin

A daemon-level plugin installed on every node, which ships container logs without
any agent in the swarm:

```bash
# <version> = the Loki release you are running (the appVersion in Chart.yaml)
docker plugin install grafana/loki-docker-driver:<version> --alias loki --grant-all-permissions
```

The plugin runs **on the host, outside every overlay network**, and cannot resolve
a Swarm service name — so `loki-url` must be an address the host itself can reach.
Publish the port (`exposure.mode: published`) and point it at the routing mesh on
the node:

```yaml
logging:
  driver: loki
  options:
    loki-url: "http://127.0.0.1:3100/loki/api/v1/push"
    loki-external-labels: "service={{.Name}}"
```

### 3. Applications pushing themselves

Anything that speaks the Loki push API — a Promtail you already run, an OTel
collector, a language SDK — posts to `http://loki:3100/loki/api/v1/push` from the
`monitoring` overlay.

## Persistence & node pinning

Data lives on the node-local named volume `loki-data` at `/loki` (chunks, index,
compactor state). Because a Swarm volume is node-local, the service is pinned to
the node holding it via a label — label exactly **one** node before installing:

```bash
docker node update --label-add loki-data=true <node>
```

Set `persistence.nodeLabel: ""` to skip the pin (e.g. a single-node swarm), or
`persistence.enabled: false` for an ephemeral instance — useful for a smoke test
and nothing else, since every line is lost on restart.

To store the data under a host directory instead, set an absolute
`persistence.volumePath` (bind mount, acknowledged as `host-mount` in
`Chart.yaml`). The directory must exist on the pinned node **and be writable by
UID 10001**, the unprivileged user the Loki image runs as:

```bash
sudo mkdir -p /srv/loki && sudo chown 10001:10001 /srv/loki
```

## Exposure

`exposure.mode` decides who can reach an API that authenticates nobody:

| Mode | What it renders | Use it when |
|------|-----------------|-------------|
| `none` (default) | No port, no labels. Loki sits on `exposure.network` and is dialled as `loki:3100`. | Grafana and your log producers run in the same swarm. |
| `published` | Publishes `publish.port` on the routing mesh. | The Docker log-driver plugin needs it, or you front Loki with something of your own. Unauthenticated on every node — trusted networks only. |
| `traefik` | Traefik router/service labels on `exposure.network`, TLS at the edge. | Loki must be reachable from outside the swarm. **Set `traefik.basicAuthUsers`.** |

In `traefik` mode the chart renders a basic-auth middleware on the public router
when `traefik.basicAuthUsers` is set — on the HTTPS router with `ingress.tls`,
on the HTTP one without, so the credential is never checked by a router that only
redirects. Generate the entry with `htpasswd -nbB <user> <password>` and **double
every `$`** (Compose eats single ones):

```yaml
traefik:
  basicAuthUsers: "ops:$$2y$$05$$Q3Z…"
```

Leave it empty and a `traefik`-mode release serves the full read *and* write API to
anyone who resolves `ingress.host`.

The `traefik.*` defaults match the [traefik](../traefik) chart in this repository
(entrypoints `http`/`https`, cert resolver `le`, constraint label
`traefik-public`); adjust them if you run your own Traefik, and set
`exposure.network` to the overlay it discovers services on.

## Metrics

Loki always serves Prometheus metrics at `/metrics` on its HTTP port.
`metrics.enabled` makes the service discoverable: it carries the deploy labels
`prometheus.io/scrape=true` and `prometheus.io/port=<service.port>`, which the
prometheus-stack chart's Swarm service discovery scrapes on the `monitoring`
overlay with no scrape config of its own. Any Prometheus using
Docker Swarm service discovery on those labels works the same way.

```bash
swarmcli charts upgrade loki swarmcli-charts/loki -f loki-values.yaml --set metrics.enabled=true
```

Pass the values you installed with (`-f`, or the same `--set`s), not `--reuse-values`.
That flag merges over the previous release's stored values *instead of* this chart
version's defaults, so every `metrics.*` key would render empty
([swarmcli#687](https://github.com/Eldara-Tech/swarmcli/issues/687)).

What it attaches depends on `exposure.mode`:

- **`none`** (default): Loki is already on `exposure.network`. With the defaults,
  both that and `metrics.network` are `monitoring`, so only the labels change and
  nothing new can reach Loki. A different `metrics.network` is joined as well; then
  share only one of the two with Prometheus, or it scrapes Loki once per network.
- **`published`**: Loki joins `metrics.network`. Its HTTP API is already open,
  unauthenticated, on every node's published port; joining also makes its gRPC port
  (9095), which is not published, reachable from that overlay.
- **`traefik`**: refused at render time. Loki's labels carry the basic-auth hash,
  and every deploy label of a discovered service is readable through Prometheus's
  targets API; joining an unauthenticated overlay would also bypass the router's
  auth. Scrape through the routed host instead, with a user of its own in
  `traefik.basicAuthUsers` so it can be revoked alone:

  ```yaml
  # loki-scrape.yml — holds a password
  scrape_configs:
    - job_name: loki
      scheme: https
      basic_auth:
        username: prometheus
        password: <that user's password>
      static_configs:
        - targets: ['loki.example.com']   # ingress.host
  ```

  ```bash
  swarmcli charts upgrade mon swarmcli-charts/prometheus-stack -f mon-values.yaml \
    --set-file prometheus.extraScrapeConfigs.loki=./loki-scrape.yml
  ```

  This relies on the prometheus-stack chart, not yet merged
  ([#221](https://github.com/Eldara-Tech/swarmcli-charts/pull/221)). It deploys each
  `extraScrapeConfigs` entry as a Swarm config, which anyone with Docker access to
  the swarm reads in cleartext with `docker config inspect`, so the password is as
  exposed there as in the file: keep the file out of git and give this user nothing
  but read access to Loki.

Everything on the scrape overlay can reach Loki's whole API on 3100 and its gRPC
port 9095, neither of which authenticates anyone; in the default shape that is the
same `monitoring` overlay Grafana and your log producers already use.

With [swarmcli-cd](https://github.com/Eldara-Tech/swarmcli-cd), an application's
`allow.networks` must name every overlay the release joins: when metrics add
`metrics.network` (in `published` mode, or when it differs from
`exposure.network`), list `monitoring` there too. See
[`allow`](https://github.com/Eldara-Tech/swarmcli-cd/blob/main/docs/configuration.md#allow-optional).

The Alloy shipper (`shipper.enabled`) is not labelled. Its HTTP server, besides
`/metrics`, serves the state of every component, which includes the labels of every
container on its node, plus a support bundle and pprof. Scraping it safely needs
Alloy's HTTP auth configured, which is a follow-up.

## Retention

Loki deletes nothing unless its compactor is told to apply retention, so the
chart turns it on and keeps 31 days:

```yaml
retention:
  enabled: true
  period: 744h   # any Go duration
```

`retention.enabled: false` keeps every line forever — and grows the data volume
forever with it. Deletion is not instant: the compactor marks chunks, then sweeps
them after a delay, so disk use falls some hours after the period passes.

Per-stream retention rules (`retention_stream`) need a configuration this chart
does not model — see below.

## Configuration

The chart ships `files/loki-config.yaml` — schema (`tsdb`, `v13`, 24h index),
filesystem storage under `/loki`, an in-memory ring, the compactor, ingestion
limits, and usage reporting off — and deploys it as a Swarm config. The values you
set do **not** rewrite that file: they render as Loki **command-line flags**, which
take precedence over it, which is why one shipped file serves every release.
`extraArgs` passes anything else (`docker run --rm grafana/loki -help` lists every
flag).

For a shape the chart does not model — S3/GCS object storage, multi-tenancy,
per-stream retention, rulers and alerting — supply the whole configuration
yourself:

```bash
# A config anyone with Docker access to the swarm can read:
docker config create loki-config ./my-loki.yaml
swarmcli charts upgrade loki swarmcli-charts/loki \
  --set config.mode=external-config --set config.externalName=loki-config

# Carrying credentials (S3 keys)? Use a secret instead — same file, mounted from
# tmpfs, invisible to `docker inspect`:
docker secret create loki-config ./my-loki.yaml
swarmcli charts upgrade loki swarmcli-charts/loki \
  --set config.mode=external-secret --set config.externalName=loki-config
```

The chart still renders its flags in both modes, so drop `retention`, `logLevel`
and `analytics` from your own file or expect the flags to win.

## Upgrading

Swarm config data is **immutable**: deploying changed contents under an existing
name is refused with `only updates to Labels are allowed`. The chart therefore
names the config after the chart version — a new chart version rotates it, and
redeploying the same version is idempotent. Nothing to do on your side; it is the
reason an edited `files/loki-config.yaml` only reaches a swarm through a chart
release.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `grafana/loki` | Container image |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml |
| `replicas` | `1` | Pinned to 1 (stateful, node-local volume) |
| `persistence.enabled` | `true` | Persist `/loki` to a named volume |
| `persistence.volumeName` | `loki-data` | Named volume mounted at `/loki` |
| `persistence.volumePath` | `""` | Absolute host path — bind-mount instead of the named volume (must be owned by UID 10001) |
| `persistence.nodeLabel` | `loki-data` | Node label the service is pinned to (`""` = no pin) |
| `exposure.mode` | `none` | `none` \| `published` \| `traefik` |
| `exposure.network` | `monitoring` | External overlay Loki shares with readers and writers (`none` & `traefik` modes) |
| `ingress.host` | `loki.example.com` | Host for the Traefik router (`traefik` mode) |
| `ingress.tls` | `true` | Terminate TLS at the edge (`traefik` mode) |
| `traefik.certResolver` | `le` | Traefik cert resolver |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider discovery constraint label |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware (when `ingress.tls`) |
| `traefik.routerName` | `""` | Router/service object base name (`""` = release name) |
| `traefik.basicAuthUsers` | `""` | htpasswd users for a basic-auth middleware on the public router; empty = no middleware |
| `publish.port` | `3100` | Host port in `published` mode |
| `publish.mode` | `ingress` | `ingress` (routing mesh) or `host` (pinned node) |
| `service.port` | `3100` | Container HTTP port (LB / publish / dial target) |
| `metrics.enabled` | `false` | Prometheus discovery labels on the Loki service; refused in `traefik` mode. See *Metrics*. |
| `metrics.network` | `monitoring` | Overlay Prometheus scrapes on; joined unless Loki is already on it |
| `retention.enabled` | `true` | Apply retention in the compactor |
| `retention.period` | `744h` | How long log lines are kept (Go duration) |
| `analytics.enabled` | `false` | Send anonymous usage statistics to Grafana Labs |
| `logLevel` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `config.mode` | `chart` | `chart` \| `external-config` \| `external-secret` |
| `config.externalName` | `loki-config` | Name of the Swarm config/secret in the external modes |
| `extraArgs` | `[]` | Extra Loki flags, appended verbatim |
| `placement.constraints` | `[]` | Extra scheduling constraints |
| `resources.limits.memory` | `""` | Optional memory limit, e.g. `"2G"` |
| `resources.reservations.memory` | `""` | Optional memory reservation, e.g. `"512M"` |
| `shipper.enabled` | `false` | Deploy the global Alloy log shipper (mounts the Docker socket) |
| `shipper.image.repository` | `grafana/alloy` | Shipper image |
| `shipper.image.tag` | pinned in values.yaml | Shipper image tag. Kept fresh by Renovate. |
| `shipper.logLevel` | `info` | Alloy's own log level |
| `shipper.dockerSocket` | `/var/run/docker.sock` | Host path of the Docker socket (change for a rootless daemon) |
| `shipper.persistence.enabled` | `true` | Persist Alloy's read positions (per node) |
| `shipper.persistence.volumeName` | `loki-alloy-data` | Named volume mounted at `/var/lib/alloy/data` |
| `shipper.extraArgs` | `[]` | Extra `alloy run` flags |
| `shipper.resources.limits.memory` | `""` | Optional memory limit for the shipper |
| `shipper.resources.reservations.memory` | `""` | Optional memory reservation for the shipper |
| `labels` | `{}` | Extra deploy labels on the Loki service |

## Notes

**No container healthcheck.** The `grafana/loki` image contains exactly one file,
`/usr/bin/loki` — no shell, no curl — so there is no command a Docker healthcheck
could run, and Swarm reports the task healthy as soon as the process starts.
Readiness is `GET /ready` on the HTTP port, which something outside the container
has to ask for:

```bash
docker run --rm --network monitoring curlimages/curl -sf http://loki:3100/ready
```

**One replica, always.** Two Loki processes over one filesystem store corrupt each
other's index. Scaling out means object storage and a different topology — a
`config.mode: external-*` configuration, not a higher `replicas`.
