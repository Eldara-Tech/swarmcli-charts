# prometheus-stack

Metrics and alerting for Docker Swarm: [Prometheus](https://prometheus.io/),
[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) and
[Grafana](https://grafana.com/oss/grafana/), with
[node-exporter](https://github.com/prometheus/node_exporter) and
[cAdvisor](https://github.com/google/cadvisor) on every node. Prometheus finds what
to scrape through Docker Swarm service discovery: the chart's own exporters, and any
other service that opts in with two deploy labels. Per-node and per-service
dashboards and a small set of alerts work from the first start.

It fills the gap [swarmprom](https://github.com/stefanprodan/swarmprom) left when
it was archived, rebuilt rather than ported: Prometheus 3, secrets from Swarm
secrets instead of environment variables, a maintained cAdvisor, and discovery
through a read-only Docker API proxy instead of a label-join in every query.

## Prerequisites

- A swarm of Linux nodes, and swarmcli **>= 1.13.0** (the chart ships config files).
- Two Swarm secrets for Grafana, created before the first install. The secret key
  encrypts the datasource credentials Grafana stores; Grafana's own default is a
  public constant, and changing it later breaks decryption of what is stored.
- One node labelled to hold the data of the three stateful services.
- For the default Grafana route: the traefik chart (or your own Traefik) on the
  `traefik-public` overlay, and a DNS name for Grafana.

## Installing

```bash
docker secret create grafana_admin_password ./pw
openssl rand -base64 32 | docker secret create grafana_secret_key -
docker node update --label-add prometheus-stack-data=true <node>

swarmcli charts install mon swarmcli-charts/prometheus-stack \
  --set grafana.ingress.host=grafana.example.com
```

Log in to Grafana as `admin` with the password from the first secret. Without
Traefik, add `--set grafana.exposure.mode=published` and point
`grafana.ingress.host` at the name users reach a node by: Grafana builds its links
from it, as `http://<host>:3000/` (see [Exposure](#exposure)).

## What you get

| Service | Image | Mode | Role |
|---|---|---|---|
| `prometheus` | `prom/prometheus` | 1 replica, pinned | Scrapes, stores, evaluates rules |
| `alertmanager` | `prom/alertmanager` | 1 replica, pinned | Routes alerts; sends nothing until configured |
| `grafana` | `grafana/grafana` | 1 replica, pinned | Dashboards; the only routed UI by default |
| `node-exporter` | `prom/node-exporter` | global | Host CPU, memory, disks, filesystems |
| `cadvisor` | `ghcr.io/google/cadvisor` | global | Per-container CPU, memory, network, block I/O |
| `socket-proxy` | `wollomatic/socket-proxy` | 1 replica, managers | Read-only Docker API for discovery |

Service names are fixed: `<release>_<service>`.

**Dashboards**, provisioned read-only into Grafana against a Prometheus datasource
with the fixed uid `prometheus`:

- **Node Exporter Full**, dashboard 1860 by rfmoz, revision 45, vendored verbatim
  under the Apache-2.0 licence of
  [rfmoz/grafana-dashboards](https://github.com/rfmoz/grafana-dashboards).
  Source: `https://grafana.com/api/dashboards/1860/revisions/45/download`,
  sha256 `184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986`
  (`files/grafana/dashboards/node-exporter-full.json`). Pick a node by its
  `<hostname>:9100` instance.
- **Swarm services**, written for this chart: CPU, memory, network and block I/O by
  stack, service, task and node, from cAdvisor. Its panel set follows swarmprom's
  services dashboard (MIT); the queries are new, keyed on the four swarm labels
  cAdvisor keeps and the `node` label discovery adds.

**Alerts** (`files/prometheus/rules/prometheus-stack.yml`), the node ones derived
from the Apache-2.0 [node-mixin](https://github.com/prometheus/node_exporter/tree/master/docs/node-mixin):
`TargetDown`, `NodeFilesystemAlmostOutOfSpace`, `NodeFilesystemFillingUp`,
`NodeMemoryHighUtilization`, `PrometheusRuleFailures`,
`PrometheusNotificationsFailing`, and `Watchdog`, which always fires so you can
prove the pipeline end to end. No CPU alerts: busy is not broken.

Every series from discovery carries a `node` label with the Swarm node's hostname,
and the exporters' `instance` is `<hostname>:<port>`, so it survives a restart.

## Discovering your services

Prometheus scrapes any task whose **service** carries these deploy labels:

| Label | Required | Meaning |
|---|---|---|
| `prometheus.io/scrape` | yes | `true` to opt in |
| `prometheus.io/port` | yes | the port `/metrics` listens on inside the task |
| `prometheus.io/path` | no | metrics path, default `/metrics` |
| `prometheus.io/job` | no | the `job` label, default the service name |

Most charts in this repository render a free-form `labels:` map as deploy labels,
so opting a release in is a values change. Use a values file: `--set` splits its key
on every `.`, so it cannot name a label containing one.

```yaml
# app-values.yaml
labels:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
```

```bash
swarmcli charts upgrade app swarmcli-charts/<chart> --reuse-values -f app-values.yaml
```

Prometheus can only reach a service it shares an overlay with. Put the service on
`monitoring` (the loki chart already is), or list its overlay in
`prometheus.extraNetworks`. Share **exactly one** of those networks with
Prometheus: a service on two of them is scraped twice, once per network.

The filter runs in the Docker daemon, so services that have not opted in never
reach Prometheus at all. Once a service has, **every one of its deploy labels** is
visible to anyone who can query Prometheus's targets API. Never opt in a service
whose labels carry credential material — a Traefik basic-auth hash is the common
case. Put the metrics endpoint on a service of its own instead.

One job, `swarm-tasks`, discovers everything, the chart's exporters included.
Custom targets that do not fit it go in a file of your own:

```bash
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --reuse-values \
  --set-file prometheus.extraScrapeConfigs=./scrape.yml   # a top-level `scrape_configs:` list
```

## Exposure

Nothing is published by default.

- **Grafana** — `grafana.exposure.mode`: `traefik` (default, TLS at the edge),
  `published` (`grafana.publish.port` on the routing mesh, plain HTTP), or `none`.
  Grafana authenticates its own users.
- **Prometheus and Alertmanager** — `none` (default) or `traefik`. Neither has any
  authentication, and Alertmanager can silence alerts, so `traefik` mode needs
  `<component>.basicAuthUsers` and the render fails without it.

```bash
# htpasswd -nbB ops '<password>', then DOUBLE every $ (Compose eats single ones)
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --reuse-values \
  --set prometheus.exposure.mode=traefik \
  --set prometheus.ingress.host=prometheus.example.com \
  --set 'prometheus.basicAuthUsers=ops:$$2y$$05$$…'
```

Routers are named `<traefik.routerName or release>-<component>-http|-https`, so
the three components never collide. The Traefik defaults match the traefik chart
in this repository; override `traefik.*` for your own Traefik.

## Alerting

The default Alertmanager configuration accepts every alert and sends it nowhere.
Give it yours, with credentials in Swarm secrets rather than in the file:

```bash
printf '%s' 'https://hooks.slack.com/services/…' | docker secret create slack_webhook -
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --reuse-values \
  --set-file alertmanager.config=./alertmanager.yml \
  --set 'alertmanager.secrets={slack_webhook}'
```

```yaml
# alertmanager.yml
route:
  receiver: slack
receivers:
  - name: slack
    slack_configs:
      - api_url_file: /run/secrets/slack_webhook
        channel: '#alerts'
```

Each name in `alertmanager.secrets` is mounted at `/run/secrets/<name>`. Your own
rule files work the same way: `--set-file prometheus.extraRules=./rules.yml`.
Both are stored as content-named Swarm configs, so editing one and upgrading
rotates it.

## Loki

With the [loki chart](../loki) on the same swarm:

```bash
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --reuse-values \
  --set grafana.datasources.loki.enabled=true \
  --set grafana.datasources.loki.url=http://<loki-release>_loki:3100
```

Grafana then joins `monitoring`, where Loki listens. The default URL,
`http://loki:3100`, is the loki chart's short alias; it resolves to whichever
`loki` service shares that overlay, so set the full name as above.

## Persistence & node pinning

Prometheus (`/prometheus`), Alertmanager (`/alertmanager`) and Grafana
(`/var/lib/grafana`) each keep their data on a node-local named volume, and
`persistence.nodeLabel` pins all three to the one labelled node. Label exactly one
node. `persistence.nodeLabel: ""` drops the pin on a single-node swarm, and
`persistence.enabled: false` drops volumes and pin together: every series, silence
and dashboard edit is then lost on restart.

To keep the data in a host directory instead, set `<component>.volumePath`. It
takes precedence over the named volume, and the directory must exist on the pinned
node, owned by the user the image runs as: `65534` for Prometheus and
Alertmanager, `472` for Grafana.

Retention is `prometheus.retention` (default `15d`), with no size cap: the volume
grows with the number of series.

The exporters are global and unpinned. They use little memory (cAdvisor measured
17-22 MiB on a small node); on large nodes, a limit of `128M` for node-exporter and
`256M` for cAdvisor (`<component>.resources.limits.memory`) is a sensible start.

## Security

**Trust zones.** Neither Prometheus nor Alertmanager authenticates anyone, so who
can reach them is the whole of their access control:

- the stack's own overlay, `<release>_internal`;
- for Prometheus, `monitoring` and every `prometheus.extraNetworks` overlay: anything
  attached to them can query it, exactly as it can already read and write Loki;
- when routed, `traefik-public`. The basic-auth middleware guards the edge path
  only: every other routed service in the swarm can dial the component directly on
  that overlay, bypassing it — for Alertmanager that includes silencing alerts.
  Never list `traefik-public` in `prometheus.extraNetworks`.

**Docker API holders.** cAdvisor runs as root on every node with the Docker and
containerd sockets and read-only binds of `/sys`, `/proc` and `/var/lib/docker`, which
lets it read every volume and secret on the node: a trust decision, switched off with `cadvisor.enabled: false`.
The socket-proxy runs on managers only, with a read-only root filesystem, alone
with Prometheus on an `internal: true` overlay that has no route out. It answers
`GET` on the task, service, node and network collections and the version ping —
each path its own anchored rule — and admits only Prometheus's own tasks. Logs,
exec and writes are refused. It still hands Prometheus the swarm's topology and
service specs, environment included; a compromised Prometheus can read them.

**Prometheus** runs as `nobody` with no lifecycle, admin or remote-write endpoint.
**Grafana** reads its password and secret key from Swarm secrets (`__FILE`), with
sign-up, anonymous access, analytics, update checks, plugin preinstall and its own
`/metrics` off. **No secret belongs in values**: values are stored in the release
record, which anyone with Docker access can read. Use `alertmanager.secrets` and
`grafana.extraSecrets`.

**What the security scan cannot see.** `scripts/security-scan.sh` flags the Docker
socket (`docker-socket`) and host binds (`host-mount`), and `Chart.yaml`
acknowledges both. Two binds get past its patterns: node-exporter's bind of the
host root, `/:/host` (the pattern needs a character after the leading `/`), and
cAdvisor's containerd socket, which it files as an ordinary host mount rather than
an API socket. Both are named in `Chart.yaml` and asserted by `ci/render-check.sh`.

## Upgrading

- **Shipped files rotate with the chart version.** Swarm configs are immutable, so
  each one is named after the chart version; an edited file reaches a swarm only
  through a chart release. Your own files (`values/`) are named after their
  content and rotate whenever you change them.
- **Disabling a component leaves it running.** An upgrade never removes a service.
  Remove it yourself: `docker service rm <release>_<service>`.
- **Grafana majors are one-way.** Grafana migrates its database on start, and 13
  moved to unified storage. Back up the `grafana-data` volume before an upgrade
  that changes Grafana's major version; the repository holds those updates for
  approval.

## Validating your own config files

Nothing checks the contents of a file you pass with `--set-file`. Before you do:

```bash
docker run --rm --entrypoint promtool -v "$PWD/rules.yml:/r.yml:ro" \
  prom/prometheus:<appVersion> check rules /r.yml
docker run --rm --entrypoint amtool -v "$PWD/alertmanager.yml:/a.yml:ro" \
  prom/alertmanager:<alertmanager.image.tag> check-config /a.yml
```

The chart's `prometheus.yml` is rendered by Swarm inside the task, so check the
result there: `docker exec <prometheus container> promtool check config
/etc/prometheus/prometheus.yml`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `prom/prometheus` | Prometheus image |
| `image.tag` | `""` | Tag — defaults to `appVersion` in Chart.yaml |
| `network` | `monitoring` | Shared overlay Prometheus scrapes on (autoCreate) |
| `persistence.enabled` | `true` | Named volumes (or `volumePath`s) for the stateful services |
| `persistence.nodeLabel` | `prometheus-stack-data` | Node label pinning them (`""` = no pin) |
| `traefik.network` | `traefik-public` | Ingress overlay routed components join |
| `traefik.constraintLabel` | `traefik-public` | Swarm-provider discovery constraint label |
| `traefik.entrypoints.http` / `.https` | `http` / `https` | Traefik entrypoint names |
| `traefik.certResolver` | `le` | Traefik cert resolver |
| `traefik.redirectMiddleware` | `https-redirect` | HTTP→HTTPS middleware (when `ingress.tls`) |
| `traefik.routerName` | `""` | Base of router names (`""` = release name) |
| `labels` | `{}` | Extra deploy labels on the Prometheus service |
| `prometheus.retention` | `15d` | How long samples are kept |
| `prometheus.scrapeInterval` | `30s` | Scrape and rule-evaluation interval |
| `prometheus.volumeName` | `prometheus-data` | Named volume at `/prometheus` |
| `prometheus.volumePath` | `""` | Host path instead (owner 65534) |
| `prometheus.extraNetworks` | `[]` | Existing overlays Prometheus joins to scrape on |
| `prometheus.extraScrapeConfigs` | `""` | Your scrape jobs (`--set-file`) |
| `prometheus.extraRules` | `""` | Your rule file (`--set-file`) |
| `prometheus.extraArgs` | `[]` | Extra Prometheus flags |
| `prometheus.resources.limits.memory` / `.reservations.memory` | `""` | Optional memory limit / reservation |
| `prometheus.exposure.mode` | `none` | `none` \| `traefik` |
| `prometheus.ingress.host` / `.tls` | `prometheus.example.com` / `true` | Routed host and scheme |
| `prometheus.basicAuthUsers` | `""` | htpasswd users; required in `traefik` mode |
| `alertmanager.enabled` | `true` | Deploy Alertmanager |
| `alertmanager.image.repository` | `prom/alertmanager` | Alertmanager image |
| `alertmanager.image.tag` | pinned in values.yaml | Kept fresh by Renovate |
| `alertmanager.config` | `""` | Your configuration (`--set-file`); `""` = the null-receiver default |
| `alertmanager.secrets` | `[]` | Secrets mounted at `/run/secrets/<name>` |
| `alertmanager.volumeName` | `alertmanager-data` | Named volume at `/alertmanager` |
| `alertmanager.volumePath` | `""` | Host path instead (owner 65534) |
| `alertmanager.resources.limits.memory` / `.reservations.memory` | `""` | Optional memory limit / reservation |
| `alertmanager.exposure.mode` | `none` | `none` \| `traefik` |
| `alertmanager.ingress.host` / `.tls` | `alertmanager.example.com` / `true` | Routed host and scheme |
| `alertmanager.basicAuthUsers` | `""` | htpasswd users; required in `traefik` mode |
| `grafana.enabled` | `true` | Deploy Grafana |
| `grafana.image.repository` | `grafana/grafana` | Grafana image |
| `grafana.image.tag` | pinned in values.yaml | Kept fresh by Renovate; majors held for approval |
| `grafana.adminUser` | `admin` | Admin login |
| `grafana.adminPasswordSecret` | `grafana_admin_password` | Secret holding the admin password |
| `grafana.secretKeySecret` | `grafana_secret_key` | Secret holding the encryption key |
| `grafana.exposure.mode` | `traefik` | `traefik` \| `published` \| `none` |
| `grafana.publish.port` / `.mode` | `3000` / `ingress` | Published port and mode |
| `grafana.ingress.host` / `.tls` | `grafana.example.com` / `true` | Public host and scheme (also `GF_SERVER_ROOT_URL`) |
| `grafana.volumeName` | `grafana-data` | Named volume at `/var/lib/grafana` |
| `grafana.volumePath` | `""` | Host path instead (owner 472) |
| `grafana.datasources.loki.enabled` | `false` | Provision a Loki datasource; Grafana joins `network` |
| `grafana.datasources.loki.url` | `http://loki:3100` | Loki URL; prefer `http://<loki-release>_loki:3100` |
| `grafana.extraEnv` | `{}` | Extra Grafana environment (never secrets) |
| `grafana.extraSecrets` | `[]` | `[{name, env}]`: a secret handed over as `<env>__FILE` |
| `grafana.resources.limits.memory` / `.reservations.memory` | `""` | Optional memory limit / reservation |
| `nodeExporter.enabled` | `true` | Deploy node-exporter (needs `discovery.enabled`) |
| `nodeExporter.image.repository` | `prom/node-exporter` | node-exporter image |
| `nodeExporter.image.tag` | pinned in values.yaml | Kept fresh by Renovate |
| `nodeExporter.extraArgs` | `[]` | Extra node-exporter flags |
| `nodeExporter.resources.limits.memory` / `.reservations.memory` | `""` | Optional memory limit / reservation |
| `cadvisor.enabled` | `true` | Deploy cAdvisor (needs `discovery.enabled`) |
| `cadvisor.image.repository` | `ghcr.io/google/cadvisor` | cAdvisor image |
| `cadvisor.image.tag` | pinned in values.yaml | Kept fresh by Renovate |
| `cadvisor.housekeepingInterval` | `30s` | How often cAdvisor collects |
| `cadvisor.containerdSocket` | `/run/containerd/containerd.sock` | Host path of containerd's socket |
| `cadvisor.extraArgs` | `[]` | Extra cAdvisor flags |
| `cadvisor.resources.limits.memory` / `.reservations.memory` | `""` | Optional memory limit / reservation |
| `discovery.enabled` | `true` | Deploy the socket-proxy and the `swarm-tasks` job |
| `discovery.image.repository` | `wollomatic/socket-proxy` | Proxy image |
| `discovery.image.tag` | pinned in values.yaml | Kept fresh by Renovate |
| `discovery.dockerSocket` | `/var/run/docker.sock` | Host path of the Docker socket (proxy and cAdvisor) |

## Notes

**No OOM events or process metrics from cAdvisor.** Swarm cannot run a service
`privileged`, so cAdvisor cannot read `/dev/kmsg`. Per-container filesystem usage
is off too: it reads 0 on Docker's containerd image store.

**Empty host-network panels.** Swarm gives a service no host network namespace, so
node-exporter's `netdev`, `netstat`, `sockstat` and `arp` collectors would describe
the container rather than the node; they are off, and Node Exporter Full's network
traffic panels stay empty. Per-container network traffic from cAdvisor is on the
Swarm services dashboard.

**swarmcli-cd.** Deploying this chart through swarmcli-cd requires the release
carrying swarmcli-cd#152 (Eldara-Tech/swarmcli-cd#304); minimum version: TBD. The
application needs these `allow` entries in the app set:

```yaml
allow:
  # `/` alone already permits every path below; the rest are listed so the grant
  # can be read. Add any <component>.volumePath you set.
  hostPaths: [/, /sys, /proc, /var/lib/docker, /var/run/docker.sock, /run/containerd/containerd.sock]
  networks: [monitoring, traefik-public]   # plus every prometheus.extraNetworks entry
  secrets: [grafana_admin_password, grafana_secret_key]   # plus alertmanager.secrets and grafana.extraSecrets
```

**Disabling a component leaves it running**, as [Upgrading](#upgrading) says:
remove the service by hand.

**One Alertmanager, no clustering.** It runs a single replica with gossip off.
