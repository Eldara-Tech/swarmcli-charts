# mariadb-galera

A MariaDB **Galera cluster** on Docker Swarm: synchronous multi-primary
replication, so every peer accepts reads *and* writes and a committed transaction
is on every peer before it returns. Losing a peer costs no data and no writes, as
long as a majority survives.

Each peer is its own Swarm service with one replica, its own data volume and its
own node label — a Swarm volume is node-local, which is the same reason the
single-node [`mariadb`](../mariadb) chart pins itself. Peers find each other over
the overlay by service name; Galera's own ports are never published.

Use [`mariadb`](../mariadb) instead if you want one database and can tolerate the
restart. Galera buys availability, not speed: a write costs a cluster-wide
round-trip, and the constraints below are real.

## Prerequisites

```bash
# The root password, shared by every peer, as an external Swarm secret:
printf 'S3cr3t' | docker secret create mariadb_galera_root_password -

# The app user's password (auth.appUser.enabled, on by default):
printf 'S3cr3t' | docker secret create mariadb_galera_password -

# The exporter user's password (metrics.enabled, off by default):
openssl rand -base64 32 | docker secret create mariadb_galera_exporter_password -

# One node per peer, each labelled for the peer whose volume lives there.
# The chart pins peer N to node.labels.mariadb-galera-<N>:
docker node update --label-add mariadb-galera-1=true <node-a>
docker node update --label-add mariadb-galera-2=true <node-b>
docker node update --label-add mariadb-galera-3=true <node-c>
```

Put each peer on a **different** node — three peers on one node share its fate and
give you no availability at all. On a single-node swarm (development) set
`persistence.nodeLabelPrefix: ""` to schedule every peer unpinned instead.

The `mariadb-galera-net` overlay is created for you at install. It carries
replication traffic, so on a multi-node swarm consider encrypting it — either
`network.external: false` with `network.encrypted: true`, or pre-create it
yourself:

```bash
docker network create --driver overlay --attachable --opt encrypted mariadb-galera-net
```

## Installing

```bash
swarmcli charts repo add swarmcli-charts https://eldara-tech.github.io/swarmcli-charts
swarmcli charts install db swarmcli-charts/mariadb-galera
```

The cluster bootstraps itself on the first install — there is no second step and
no flag to unset afterwards. See *How bootstrapping decides* below for what that
means when a peer is later rebuilt.

## Connecting

Apps join the same overlay and connect to **`mariadb`**, a DNS alias every peer
shares, so connections spread across the peers:

```yaml
networks:
  mariadb-galera-net:
    external: true
```

```
mysql://app:<password>@mariadb:3306/app
```

Any peer accepts writes, so nothing needs to find a leader. The alias is also
health-aware, which is worth being precise about because it is easy to assume
otherwise: Swarm stops resolving the alias to a peer once that peer has no healthy
task, and resolves it again once a replacement passes its healthcheck. Since this
chart's healthcheck asserts the peer can actually serve, that covers a peer which
is down, one still receiving a state transfer, and one cut off from the cluster —
none of them keeps receiving client connections. A peer *donating* a transfer
stays in rotation on purpose: it remains writable throughout.

What it does not remove is the **detection lag**. A failing peer stays in the alias
for up to `healthcheck.interval × healthcheck.retries` (60s at the defaults) plus
propagation, so clients still need a pool that retries, and lowering `retries`
trades that window against false positives under load.

### The proxy endpoint (`proxy.enabled`)

Set `proxy.enabled: true` for the production endpoint MariaDB's own Galera guide
recommends: an HAProxy in front of the peers, which takes over the `mariadb` alias.

```bash
swarmcli charts install db swarmcli-charts/mariadb-galera --set proxy.enabled=true
```

It closes the lag — checks run every 2s rather than every 60s — and it routes by
Galera's *state*, not just by reachability. Each peer runs a small responder that
answers 200 only while it is `Synced`, so a peer **donating** a state transfer stops
receiving client traffic without being killed: the container healthcheck
deliberately still calls that peer healthy (see the healthcheck note below), and the
proxy simply declines to route to it. That split is the whole point — one layer
decides *alive*, the other decides *good to serve*.

The responder uses `socat`, `gosu` and the `mariadb` client already in the image, so
it adds no package and no sidecar, and it listens only inside the peer on
`proxy.checkPort` (never published). The proxy itself is stateless and runs
`proxy.replicas: 2` by default, because a single proxy in front of an HA cluster is
a single point of failure.

Connections are spread across all `Synced` peers. Galera is multi-primary so that is
correct, but writing the same rows from several peers at once raises certification
conflicts; an application with heavy write contention on the same keys may prefer to
funnel writes to one peer, which this chart does not currently express.

Individual peers are addressable as `mariadb-galera-1`, `mariadb-galera-2`, … if
you want to pin reads to one.

Peers address *each other* differently, and it is worth knowing why. They find one
another through `tasks.<release>_<peer>`, the name Swarm publishes for a service's
actual tasks, because a load-balanced service VIP is not a usable rendezvous for
group communication. But each peer *advertises* its own plain IP, read from
`/etc/hosts` at start-up — never a name. Galera has to bind its state-transfer
listener to the address a peer advertises, and a `tasks.` name does not resolve
inside the container, so advertising one makes every transfer to that peer fail
with `Host not found (authoritative)`. A peer that cannot establish its own address
refuses to start rather than join with one nothing can dial.

`exposure.enabled` publishes the SQL port in **host** mode only: every peer
publishes the same port, and several services cannot each claim it on the ingress
routing mesh. Port 3306 on a node then reaches the peer running there.

With `proxy.enabled` as well, the port is published on the proxy instead, through
the ingress mesh: port 3306 on any node reaches the proxy, which routes to a
`Synced` peer. The peers then publish nothing, so no external client can bypass
the proxy's health checks, and `exposure.mode` does not apply.

## Metrics

MariaDB serves no Prometheus metrics of its own, so `metrics.enabled` adds one
[mysqld_exporter](https://github.com/prometheus/mysqld_exporter) per peer. Each
carries the deploy labels `prometheus.io/scrape=true` and `prometheus.io/port=9104`
and joins the `monitoring` overlay, which is where the prometheus-stack chart
scrapes by default — so Prometheus finds every peer by itself, with no scrape
config. Any Prometheus using Docker Swarm service discovery on those labels works
the same way.

```bash
openssl rand -base64 32 | docker secret create mariadb_galera_exporter_password -
swarmcli charts upgrade db swarmcli-charts/mariadb-galera --reuse-values --set metrics.enabled=true
```

Turning it on adds services and changes no peer, so it is safe on a running cluster:
nothing restarts. The exporters log in as a database user of their own, `exporter`,
which a one-shot service (`mariadb-galera-exporter-user`) creates as root over the
overlay and then exits; Galera replicates it to every peer. The user holds `PROCESS,
REPLICATION CLIENT, SLAVE MONITOR` — what the default collectors need, and no
`SELECT` on your data.

You get `mysql_up` and every numeric `SHOW GLOBAL STATUS` and `SHOW GLOBAL VARIABLES`
value, Galera's `mysql_global_status_wsrep_*` included (`wsrep_cluster_size`,
`wsrep_local_state`, `wsrep_flow_control_paused`, …), so dashboards and alert rules
written for mysqld_exporter apply as they are. Each exporter is its own service, so
the `job` label names the peer it watches (`<release>_mariadb-galera-exporter-<N>`),
and it shares that peer's node pin, so while the peers are pinned `node` is the
peer's node.

That pin also decides what a lost node looks like. Swarm cannot move the exporter
elsewhere, so its target stays and reads down (`up 0`, not `mysql_up 0`), while the
surviving peers report `mysql_global_status_wsrep_cluster_size` below
`cluster.peers`. That drop is the signal to alert on, and the rules below do:
`GaleraQuorumAtRisk` and `GaleraClusterShrunk`.

- **Rotating the password**: create a secret under a new name and point
  `metrics.secretName` at it. The changed spec runs the one-shot again, which resets
  the password; a scrape or two may read `mysql_up 0` until it has.
- **A cluster rebuilt from empty data** loses the user with everything else. Run the
  one-shot again: `docker service update --force <release>_mariadb-galera-exporter-user`.
- `metrics.network` names a different overlay. It must differ from `network.name`,
  and the render fails if it does not: the peers never join it.
- **Turning it off** leaves the services running, for the same reason as shrinking
  the cluster (swarmcli deploys without `--prune`). Remove them yourself:
  `docker service rm <release>_mariadb-galera-exporter-1 … <release>_mariadb-galera-exporter-user`.

### Alerts and a dashboard

The chart ships both under [`monitoring/`](monitoring) for your Prometheus and Grafana,
and deploys neither: scraping is automatic, but which rules and dashboards a monitoring
stack loads is its operator's choice. With the prometheus-stack chart they go in
through its own configuration:

```bash
base=https://raw.githubusercontent.com/Eldara-Tech/swarmcli-charts/main/charts/mariadb-galera/monitoring
curl -fsSL -O "$base/galera-rules.yml" -O "$base/galera-dashboard.json"
swarmcli charts upgrade mon swarmcli-charts/prometheus-stack --reuse-values \
  --set-file prometheus.extraRules.galera=./galera-rules.yml \
  --set-file grafana.dashboards.galera=./galera-dashboard.json
```

prometheus-stack's README, *Keeping your setup in git*, has the values-file form.

- **Alerts** (`galera-rules.yml`): `MySQLDown`, `MySQLGaleraNotReady`,
  `MySQLGaleraOutOfSync` and `MySQLGaleraDonorFallingBehind`, derived from the
  [mysqld-mixin](https://github.com/prometheus/mysqld_exporter/tree/main/mysqld-mixin)
  (Apache-2.0); OutOfSync leaves out a donor, which keeps serving during a state
  transfer. Then one alert per cluster: `GaleraQuorumAtRisk` while fewer than 3
  members remain, so the next failure loses quorum, and `GaleraClusterShrunk` while a
  cluster has fewer members than it had in the last day.
- **Dashboard** (`galera-dashboard.json`, uid `galera`): members, Synced peers,
  primary component, peer state, flow control, write-set queues and traffic,
  certification conflicts, plus connections, queries and buffer-pool hits. Pick a
  cluster by its `stack`.

Both group by the `stack` label prometheus-stack's discovery puts on every target.
Another Prometheus needs the same relabelling of
`__meta_dockerswarm_service_label_com_docker_stack_namespace` to `stack`.

## Values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `mariadb` | Image repository. |
| `image.tag` | `""` | Image tag — defaults to `appVersion` in Chart.yaml. |
| `cluster.name` | `mariadb-galera` | Galera cluster name; peers only join a cluster whose name matches. |
| `cluster.peers` | `3` | Number of peers. `3` or `5` — Galera needs a majority, so even counts add nothing. |
| `cluster.forceBootstrap` | `""` | Disaster recovery only: the peer that must form a new cluster. See below. |
| `auth.rootSecretName` | `mariadb_galera_root_password` | External secret holding the root password. |
| `auth.appUser.enabled` | `true` | Create a non-root user + database when the cluster first bootstraps. |
| `auth.appUser.username` | `app` | Application user name. |
| `auth.appUser.database` | `app` | Database created for that user. |
| `auth.appUser.secretName` | `mariadb_galera_password` | External secret holding the app user's password. |
| `persistence.enabled` | `true` | Named volume per peer. `false` = ephemeral (no volumes, no pins). |
| `persistence.volumePrefix` | `mariadb-galera-data` | Volume name prefix; peer N gets `<prefix>-<N>`. |
| `persistence.volumePaths` | `[]` | One absolute host path per peer, in peer order; takes precedence over the prefix. |
| `persistence.nodeLabelPrefix` | `mariadb-galera` | Node-label prefix; peer N pins to `node.labels.<prefix>-<N>`. `""` = unpinned. |
| `placement.constraints` | `[]` | Extra constraints applied to every peer, in all modes. |
| `network.name` | `mariadb-galera-net` | Overlay the cluster attaches to. |
| `network.external` | `true` | `false` = chart-managed internal overlay. |
| `network.encrypted` | `false` | IPsec on a chart-managed overlay; requires `external: false`. |
| `network.clientAlias` | `mariadb` | Health-aware DNS alias shared by every peer. `""` = no shared alias. |
| `proxy.enabled` | `false` | HAProxy client endpoint in front of the peers; takes over `network.clientAlias`. |
| `proxy.image.repository` | `haproxy` | Proxy image. |
| `proxy.image.tag` | `3.4` | Proxy image tag (a concrete pin; Renovate maintains it). |
| `proxy.replicas` | `2` | Proxy replicas — stateless, so more than one is safe and recommended. |
| `proxy.checkPort` | `9200` | Port the Synced responder listens on inside each peer; never published. |
| `proxy.resources.limits.memory` | `""` | Proxy memory limit. Rendered only when set. |
| `metrics.enabled` | `false` | One mysqld_exporter per peer, labelled for Prometheus service discovery. See *Metrics*. |
| `metrics.image.repository` | `prom/mysqld-exporter` | Exporter image. |
| `metrics.image.tag` | pinned in `values.yaml` | Exporter image tag (a concrete pin; Renovate maintains it). |
| `metrics.username` | `exporter` | Database user the exporters log in as; the chart creates it. |
| `metrics.secretName` | `mariadb_galera_exporter_password` | External secret holding that user's password. |
| `metrics.network` | `monitoring` | External overlay the exporters share with Prometheus; no peer joins it. |
| `exposure.enabled` | `false` | Publish the SQL port on each peer's own node, or on the proxy when `proxy.enabled`. |
| `exposure.port` | `3306` | Published port. |
| `exposure.protocol` | `tcp` | Published protocol. |
| `exposure.mode` | `host` | Only `host` is valid — see *Connecting*. Unused when `proxy.enabled`. |
| `resources.limits.memory` | `""` | Per-peer memory limit, e.g. `512M`. Rendered only when set. |
| `healthcheck.enabled` | `true` | Container healthcheck — `healthcheck.sh --su-mysql --connect --galera_ready`. |
| `healthcheck.interval` | `10s` | Probe interval. |
| `healthcheck.timeout` | `5s` | Probe timeout. |
| `healthcheck.retries` | `6` | Failures before unhealthy. |
| `healthcheck.startPeriod` | `300s` | Grace period — **must exceed your worst-case state transfer**. |
| `healthcheck.monitor` | `360s` | Rollout failure window; see below. |
| `extraArgs` | `[]` | Extra `mariadbd` flags, appended verbatim. |
| `labels` | `{}` | Extra deploy labels on every peer. |

## Security note

Passwords are read from mounted secret files via the image's `MARIADB_*_FILE`
convention, so the plaintext never lands in the compose file, the environment or
`docker inspect` — only the `/run/secrets/...` path does. Secrets are always
external and operator-created; the chart never creates one.

State transfer between peers needs a database account of its own, and the usual
recipe puts `wsrep_sst_auth=user:password` in the config — where it also ends up in
the error log. This chart instead creates the account authenticating **VIA
`unix_socket`**, matching it against the OS user `mysqld` already runs as, so there
is no third secret and no password to leak.

Replication carries every row written. On a multi-node swarm it crosses the
overlay between nodes, so encrypt that overlay unless the network between nodes is
already trusted — see *Prerequisites*.

With `metrics.enabled`, the exporters are the one thing on both the Galera overlay
and `metrics.network`, so what can reach Prometheus can reach port 9104 and never a
peer. `/metrics` has no authentication, and mysqld_exporter's `/probe?target=`
endpoint will log in to any address it is handed with the exporter's credentials, so
a rogue server on that overlay can capture a login attempt: give the user a long
random password, as above. The one-shot that creates it holds the root password and
stays off `metrics.network`.

## Operating notes

### How bootstrapping decides

Exactly one peer must form the cluster, once, and never again — bootstrapping a
second time beside a live cluster is a split brain. **Peer 1 is the designated
seed**: it is the only peer that can ever form a cluster, and the others only ever
join. Before `mariadbd` starts:

- **Peer 1, data dir empty, no peer answering on port 4567** → form the cluster.
  This is the first install.
- **Peer 1, data dir empty but some peer answers** → join and pull a state
  transfer. This is the seed rebuilt on a new node, and it is why a lost volume
  re-syncs instead of starting a rival cluster.
- **Every other case** → wait until another peer resolves, then join. A restart
  never bootstraps.
- **Waiting, no peer resolves, and this peer's `grastate.dat` says
  `safe_to_bootstrap: 1`** → form the cluster again. Galera sets that flag on the
  last peer to leave a cluster that stopped one peer at a time, so its data is the
  newest and at most one peer has it.

The wait is not optional. Swarm publishes a peer in DNS (`tasks.<release>_<peer>`)
only once its healthcheck passes, and a peer passes it only inside a cluster. With
every peer down nothing resolves, and a `mariadbd` started anyway fails with
`No address to connect` and rewrites `grastate.dat` to `seqno: -1` on every
attempt, so the cluster could never come back by itself.

A single designated seed is what removes the race. Letting every peer bootstrap
when it sees no peers is the tempting version and it is wrong: on a first install
all peers start at once with empty data dirs and none is listening yet, so each
forms its own cluster of one and they never merge — while all of them report
healthy.

The consequence to know: **a first install needs peer 1 to be schedulable.** If
its node is unavailable the other peers wait rather than forming a cluster without
it. Once the cluster exists, peer 1 is no more special than any other peer, and
losing it costs nothing extra.

When `cluster.forceBootstrap` names a peer, that peer becomes the only
unconditional bootstrapper and peer 1 is demoted to joining, so the count never
rises above one, whatever you set.

### Recovering a fully stopped cluster

If the peers stopped **one at a time**, the cluster comes back by itself: the last
peer to leave holds `safe_to_bootstrap: 1` and forms it again, and the others join.

If they stopped **together**, no peer holds the flag. Every peer then waits,
logging `waiting for a peer to come up`, rather than risk losing committed
transactions. That covers an upgrade that changes every peer at once (see
*Upgrading the image*) and a power loss. Swarm replaces a waiting peer every few
minutes as its healthcheck expires; that is harmless, because `mariadbd` never
starts and `grastate.dat` is left as it was. Recover deliberately:

1. Find the furthest-ahead peer. On each peer's node, read its `grastate.dat`:
   `docker run --rm -v <release>_mariadb-galera-data-<N>:/d:ro busybox cat /d/grastate.dat`.
   The highest `seqno` wins. A peer that crashed shows `-1`; with every peer
   stopped, recover its position from the volume itself, using the image the
   cluster runs. The number after the last `:` is its seqno:

   ```bash
   docker run --rm --network none -v <release>_mariadb-galera-data-<N>:/var/lib/mysql mariadb:<tag> \
     mariadbd --user=mysql --wsrep-on=ON --wsrep-provider=/usr/lib/galera/libgalera_smm.so \
     --wsrep-recover 2>&1 | grep 'Recovered position'
   ```
2. Set `cluster.forceBootstrap` to **that peer's number** and
   `swarmcli charts upgrade`. The chart marks that peer `safe_to_bootstrap: 1`,
   which Galera insists on, and it forms a new cluster from the best data.
3. Once the others have rejoined and the cluster is `Synced`, set
   `cluster.forceBootstrap: ""` and upgrade again. That restarts only the forced
   peer and peer 1, and they rejoin the running cluster. Leaving it set means that
   peer would form yet another cluster on its next restart.

Never force-bootstrap more than one peer, never force-bootstrap while the cluster
is still up, and never force one while some peer still shows
`safe_to_bootstrap: 1`: that peer restarts the cluster by itself.

### Upgrading the image

Galera requires every peer on the same server version, and `swarmcli charts
upgrade` updates all peer services at once, so the whole cluster stops together.
That is a full outage, and a stop where no peer holds `safe_to_bootstrap: 1`: it
needs the recovery procedure above.

That can happen without you changing the image. Swarm resolves `mariadb:12.3` to
a digest at every deploy, so once upstream re-tags `12.3` with a patch release,
the next upgrade of any value changes every peer. Upgrade with
`--resolve-image never` to keep the digest the cluster already runs, so that only
a deliberate image change restarts the peers:

```bash
swarmcli charts upgrade db swarmcli-charts/mariadb-galera --reuse-values --resolve-image never …
```
 To roll peers one at a time instead, update each service in place
(`docker service update --image mariadb:<tag> <release>_mariadb-galera-1`), waiting
for `Synced` between peers, then bump the chart to match.

Note also that a MariaDB tag change is a **series** change, not a patch: check the
release notes for on-disk format changes before upgrading a cluster you care about.

### Galera constraints

These are Galera's, not this chart's, and they break applications that assume a
standalone MariaDB:

- **InnoDB only.** MyISAM/Aria tables are not replicated.
- **Every table needs a primary key.** Rows are located by primary key when
  applying a write set; a table without one behaves unpredictably.
- Writes are certified cluster-wide, so a transaction can be rolled back on commit
  as a deadlock even when nothing local conflicted. Applications must retry.
- `LOCK TABLES`, `GET_LOCK()` and other explicit locking are not cluster-aware.

### Scaling the cluster

Change `cluster.peers` between `3` and `5` and upgrade. **Shrinking needs a manual
step**: swarmcli deploys without `--prune`, so the services for the removed peers
keep running and stay cluster members. Remove them yourself afterwards:

```bash
docker service rm <release>_mariadb-galera-4 <release>_mariadb-galera-5
```

### Why `healthcheck.monitor` exists

Swarm watches a task for `update_config.monitor` **after creating it**, and only a
failure inside that window counts against the rollout. Leave it unset and swarm
applies a 5s default — so a container that takes longer than that to be declared
unhealthy never fails the deploy: the rollout is reported complete and the task
quietly restart-loops. Keep `monitor` at or above
`startPeriod + interval × retries`; `swarmcli charts lint` warns when it is
shorter.

The check asserts `--galera_ready` (able to serve), **not** `--galera_online`
(fully `Synced`). The stricter check is a trap: a peer donating a state transfer is
`Donor/Desynced` for the whole transfer while staying writable, so Swarm would kill
it once the transfer outran `interval × retries` — breaking the transfer during
exactly the recovery the cluster exists for. The trade-off is that a donor's apply
queue lags, so it can serve slightly stale reads mid-transfer; a client needing a
causal read sets `wsrep_sync_wait`.

The check runs as the `mysql` unix user (`--su-mysql`) so it authenticates through
the same `unix_socket` account used for state transfers. That is not a stylistic
choice: the default path reads credentials from a file inside the data dir, and a
state transfer replaces the data dir, so a freshly synced peer would fail its own
healthcheck forever — reporting `Access denied for user 'root'@'localhost'` while
being perfectly healthy — until Swarm killed it.

`startPeriod` matters more here than in a single-node chart. A joining peer cannot
serve until its state transfer finishes, so it fails the check for the whole
transfer; if the grace period expires first, Swarm kills it mid-transfer and
restarts it into the same transfer — forever. Raise `startPeriod` (and `monitor`
with it) well past the time a full restore of your dataset takes.

That applies to the peer *receiving* a transfer. The peer sending one is covered by
the choice of `--galera_ready` above, which is why a large donation does not put
the donor on the same clock.
